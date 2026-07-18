{ config, pkgs, ... }:

let
  hermesApiServerPort = 8642;
  hermesApiTailnetHttpsPort = 8643;
  hermesApiSecretFile = "/var/lib/hermes/api-server.env";
  hermesChatKanbanWorkspaces =
    "/var/lib/hermes/.hermes/kanban/boards/hermes-chat/workspaces";

  # dockerTools builds an OCI image directly from the Nix store (equivalent to
  # `FROM scratch`).  The package closures are intentionally available under
  # their immutable /nix/store paths; Hermes overlays that directory with the
  # host store, where these exact paths are retained by this system closure.
  # `systemd.services.<name>.path` expects package roots and appends `/bin`.
  # Export host setuid wrappers through such a package root, rather than adding
  # `/run/wrappers/bin` directly (which would incorrectly become `.../bin/bin`).
  rootlessPodmanWrapperPath = pkgs.runCommand "hermes-rootless-podman-wrappers" { } ''
    mkdir -p "$out/bin"
    ln -s ${config.security.wrapperDir}/newuidmap "$out/bin/newuidmap"
    ln -s ${config.security.wrapperDir}/newgidmap "$out/bin/newgidmap"
  '';

  # Host-side plugin for the privileged update action and bounded service journal
  # access that must stay outside the terminal sandbox. Updates always need
  # fresh consent; log consent can be cached only for the selected service and
  # current Hermes session before contacting the root broker.
  nixosUpdatePlugin = pkgs.linkFarm "hermes-nixos-update-plugin" [
    {
      name = "plugin.yaml";
      path = ./plugins/nixos-update/plugin.yaml;
    }
    {
      name = "__init__.py";
      path = ./plugins/nixos-update/__init__.py;
    }
  ];

  nixosUpdateBrokerSocket = "/run/hermes-nixos-update-broker/socket";
  # Root-owned broker for one fixed host action and read-only, bounded journal
  # access to validated service units. In addition to Unix-socket permissions,
  # it verifies SO_PEERCRED against the current MainPID of the two
  # managed Hermes services. A separate process running as `hermes` therefore
  # cannot reuse this capability, and the socket is not mounted into Podman.
  nixosUpdateBroker = pkgs.writers.writePython3Bin "hermes-nixos-update-broker" { } ''
    import os
    import pwd
    import re
    import selectors
    import socket
    import struct
    import subprocess
    import sys
    import time

    if int(os.environ.get("LISTEN_FDS", "0")) != 1:
        raise SystemExit("expected exactly one systemd socket")

    systemd_package = (
        "${pkgs.systemd}"
    )
    systemctl = os.path.join(systemd_package, "bin", "systemctl")
    journalctl = os.path.join(systemd_package, "bin", "journalctl")
    hermes_uid = pwd.getpwnam("hermes").pw_uid
    listener = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    service_pattern = re.compile(
        r"[A-Za-z0-9][A-Za-z0-9_.:@-]{0,246}\.service\Z"
    )


    def service_main_pid(unit):
        try:
            result = subprocess.run(
                [systemctl, "show", "--property=MainPID", "--value", unit],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            return 0
        if (
            result.returncode != 0
            or not result.stdout.endswith("\n")
            or result.stdout.count("\n") != 1
        ):
            return 0
        pid_value = result.stdout[:-1]
        if (
            not pid_value.isascii()
            or not pid_value.isdecimal()
            or (len(pid_value) > 1 and pid_value.startswith("0"))
        ):
            return 0
        return int(pid_value)


    def receive_request(connection):
        request = b""
        while len(request) < 300 and not request.endswith(b"\n"):
            chunk = connection.recv(300 - len(request))
            if not chunk:
                break
            request += chunk
        return request


    def requested_log_service(request):
        if not request.startswith(b"logs ") or not request.endswith(b"\n"):
            return None
        try:
            service = request[5:-1].decode("ascii")
        except UnicodeDecodeError:
            return None
        return service if service_pattern.fullmatch(service) else None


    def bounded_process_tail(command, *, timeout, max_bytes):
        """Run a fixed command while retaining only its newest bounded output."""
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        stdout = process.stdout
        selector = None
        try:
            if stdout is None:
                raise RuntimeError("could not capture journal output")

            descriptor = stdout.fileno()
            os.set_blocking(descriptor, False)
            selector = selectors.DefaultSelector()
            selector.register(descriptor, selectors.EVENT_READ)
            deadline = time.monotonic() + timeout
            tail = bytearray()
            total_bytes = 0
            eof = False

            while not eof:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                for key, _events in selector.select(min(0.5, remaining)):
                    try:
                        chunk = os.read(key.fd, 8_192)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(key.fd)
                        eof = True
                        break
                    total_bytes += len(chunk)
                    tail.extend(chunk)
                    if len(tail) > max_bytes:
                        tail = tail[-max_bytes:]
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except BaseException:
            if process.poll() is None:
                process.kill()
            process.wait()
            raise
        finally:
            if selector is not None:
                selector.close()
            if stdout is not None:
                stdout.close()

        truncated = total_bytes > max_bytes
        if truncated:
            # Prefer a complete-line boundary while retaining the newest output.
            newline = tail.find(b"\n")
            if newline >= 0:
                del tail[: newline + 1]
            else:
                # A single journal entry can itself exceed the cap. Keep its
                # newest bytes, but never begin inside a UTF-8 continuation.
                while tail and tail[0] & 0xC0 == 0x80:
                    del tail[0]

        if not tail:
            marker = (
                b"-- Output truncated; newest journal entry exceeds "
                b"byte limit --\n"
                if truncated
                else b"-- No entries --\n"
            )
            tail = bytearray(marker)
        line_count = len(tail.decode("utf-8", errors="replace").splitlines())
        return process.returncode, bytes(tail), truncated, line_count


    while True:
        connection, _ = listener.accept()
        with connection:
            # An authorized but incomplete request must not monopolize this
            # single-purpose broker indefinitely.
            connection.settimeout(5)
            try:
                credentials = connection.getsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_PEERCRED,
                    12,
                )
                pid, uid, _gid = struct.unpack("3i", credentials)
                allowed_pids = {
                    service_main_pid("hermes-agent.service"),
                    service_main_pid("hermes-serve.service"),
                }
                if uid != hermes_uid or pid not in allowed_pids or pid == 0:
                    connection.sendall(b"error: unauthorized peer\n")
                    print(
                        f"rejected update request from uid={uid} pid={pid}",
                        file=sys.stderr,
                    )
                    continue
                request = receive_request(connection)
                service = requested_log_service(request)
                if service is not None:
                    try:
                        returncode, log_bytes, truncated, line_count = (
                            bounded_process_tail(
                                [journalctl, f"--unit={service}",
                                 "--lines=200", "--no-pager",
                                 "--output=short-iso"],
                                timeout=15,
                                max_bytes=60_000,
                            )
                        )
                    except (
                        OSError,
                        RuntimeError,
                        subprocess.TimeoutExpired,
                    ) as error:
                        connection.sendall(f"error: {error}\n".encode())
                        continue
                    if returncode == 0:
                        header = (
                            f"ok truncated={int(truncated)} "
                            f"bytes={len(log_bytes)} "
                            f"lines={line_count}\n"
                        )
                        connection.sendall(header.encode("ascii") + log_bytes)
                    else:
                        detail = log_bytes.decode(
                            "utf-8", errors="replace"
                        ).strip()
                        connection.sendall(f"error: {detail[:1000]}\n".encode())
                    continue

                if request != b"start\n":
                    connection.sendall(b"error: unsupported request\n")
                    continue

                try:
                    result = subprocess.run(
                        [
                            systemctl,
                            "start",
                            "--no-block",
                            "nixos-update.service",
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=15,
                    )
                except (OSError, subprocess.TimeoutExpired) as error:
                    connection.sendall(f"error: {error}\n".encode())
                    continue
                if result.returncode == 0:
                    connection.sendall(b"ok\n")
                else:
                    detail = (
                        result.stderr or result.stdout or "systemctl failed"
                    ).strip()
                    connection.sendall(f"error: {detail[:1000]}\n".encode())
            except (BrokenPipeError, ConnectionError, OSError) as error:
                print(f"update broker client error: {error}", file=sys.stderr)
  '';

  githubCredentialSocket = "/run/hermes-github-credential-broker/socket";

  # The token minter is a Nix package, not a mutable helper in Hermes' state
  # directory. It reads the private key and App ID only at runtime, so neither
  # secret becomes part of the Nix store.
  githubAppToken = pkgs.writeShellApplication {
    name = "github-app-token";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.openssl ];
    text = ''
      key=/var/lib/hermes/.hermes/secrets/github-app-private-key.pem
      app_id=$(tr -d '[:space:]' < /var/lib/hermes/.hermes/secrets/github-app-id)
      account="''${1:-fkz}"

      # The sandbox may select only installations explicitly trusted here.
      # Never expose arbitrary App installations through the broker socket.
      case "$account" in
        fkz|qelg) ;;
        *)
          printf 'unsupported GitHub App account\n' >&2
          exit 2
          ;;
      esac

      b64url() {
        openssl base64 -A | tr '+/' '-_' | tr -d '='
      }

      now=$(date +%s)
      header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
      payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
        "$((now - 60))" "$((now + 540))" "$app_id" | b64url)
      unsigned="$header.$payload"
      signature=$(printf '%s' "$unsigned" \
        | openssl dgst -sha256 -sign "$key" -binary | b64url)
      jwt="$unsigned.$signature"

      installation_id=$(curl --fail --silent --show-error \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $jwt" \
        https://api.github.com/app/installations \
        | jq -r --arg account "$account" \
          '.[] | select(.account.login == $account) | .id' | head -n 1)
      test -n "$installation_id" && test "$installation_id" != null

      curl --fail --silent --show-error -X POST \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $jwt" \
        "https://api.github.com/app/installations/$installation_id/access_tokens" \
        | jq -er .token
    '';
  };

  # The GitHub App private key remains on the host. The sandbox gets only these
  # clients, which ask the host-side broker for a short-lived installation token
  # over a Unix socket.
  # Keep the read half of the socket open after sending the request. `socat`
  # exits when its stdin pipe reaches EOF, which can disconnect before the
  # network-backed token minter has produced a response.
  githubAppCredentialClient = pkgs.writers.writePython3Bin "github-app-credential-client" { } ''
    import os
    import socket
    import sys

    account = os.environ.get("GITHUB_APP_ACCOUNT", "fkz")
    if account not in {"fkz", "qelg"}:
        raise SystemExit("unsupported GitHub App account")

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(70)
        client.connect("${githubCredentialSocket}")
        request = f"get\naccount={account}\n\n".encode("ascii")
        client.sendall(request)
        client.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        sys.stdout.buffer.write(b"".join(chunks))
  '';
  githubAppGitCredential = pkgs.writeShellScriptBin "github-app-git-credential" ''
    set -eu
    case "''${1:-get}" in
      get) ;;
      *) exit 0 ;;
    esac
    # Drain git's credential request, but only up to the blank separator line.
    # git keeps the request pipe open until it reads our reply, so reading to
    # EOF here would deadlock: the helper would block forever waiting for git
    # to close stdin, while git blocks waiting for the helper's reply. Reading
    # just the request headers is sufficient; the broker ignores them anyway.
    while IFS= read -r line; do
      [ -z "$line" ] && break
    done
    exec ${githubAppCredentialClient}/bin/github-app-credential-client
  '';
  githubAppGh = pkgs.writeShellScriptBin "github-app-gh" ''
    set -eu
    response=$(${githubAppCredentialClient}/bin/github-app-credential-client)
    token=
    while IFS= read -r line; do
      case "$line" in
        password=*) token="''${line#password=}" ;;
      esac
    done <<EOF
    $response
    EOF
    test -n "$token"
    GH_TOKEN="$token" exec ${pkgs.gh}/bin/gh "$@"
  '';
  githubAppCredentialBroker = pkgs.writers.writePython3Bin "hermes-github-credential-broker" { } ''
    import os
    import socket
    import subprocess
    import sys
    import threading

    if int(os.environ.get("LISTEN_FDS", "0")) != 1:
        raise SystemExit("expected exactly one systemd socket")

    listener = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    # Serve each connection in its own thread. The broker mints a fresh
    # installation token per request, which can take a few seconds; a
    # single-threaded accept loop would stall concurrent git operations
    # (e.g. a push opens two credential requests in quick succession).
    listener.listen(16)


    def handle(connection):
        with connection:
            request = bytearray()
            while b"\n\n" not in request and len(request) < 128:
                chunk = connection.recv(128 - len(request))
                if not chunk:
                    break
                request.extend(chunk)

            try:
                lines = request.decode("ascii").splitlines()
            except UnicodeDecodeError:
                lines = []
            if not lines or lines[0] != "get":
                connection.sendall(b"error=unsupported request\n\n")
                return
            fields = {}
            for line in lines[1:]:
                if not line or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key in fields:
                    connection.sendall(b"error=unsupported request\n\n")
                    return
                fields[key] = value
            if set(fields) - {"account"}:
                connection.sendall(b"error=unsupported request\n\n")
                return
            account = fields.get("account", "fkz")
            if account not in {"fkz", "qelg"}:
                connection.sendall(b"error=unsupported account\n\n")
                return
            try:
                token_command = (
                    "${githubAppToken}"
                    "/bin/github-app-token"
                )
                token = subprocess.run(
                    [token_command, account],
                    check=True,
                    capture_output=True,
                    text=True,
                    timeout=60,
                ).stdout.strip()
                if not token:
                    raise RuntimeError("empty installation token")
                connection.sendall(
                    f"username=x-access-token\npassword={token}\n\n".encode()
                )
            except BrokenPipeError:
                print(
                    "GitHub credential broker: client disconnected "
                    "before response",
                    file=sys.stderr,
                )
            except Exception as error:
                print(f"GitHub credential broker: {error}", file=sys.stderr)
                try:
                    connection.sendall(b"error=credential unavailable\n\n")
                except BrokenPipeError:
                    print(
                        "GitHub credential broker: client disconnected "
                        "before error response",
                        file=sys.stderr,
                    )


    while True:
        connection, _ = listener.accept()
        threading.Thread(target=handle, args=(connection,), daemon=True).start()
  '';

  # Baseline required by Hermes' remote terminal, file, and code-execution
  # tools. More project-specific dependencies can still be obtained with Nix.
  hermesNixSandboxPackages = [
    pkgs.bash
    pkgs.cacert
    pkgs.coreutils
    pkgs.curl
    pkgs.diffutils
    pkgs.file
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.gh
    pkgs.gnugrep
    pkgs.gnupatch
    pkgs.gnused
    pkgs.gnutar
    pkgs.gzip
    pkgs.iproute2
    pkgs.jq
    pkgs.nix
    pkgs.openssh
    pkgs.procps
    pkgs.python3
    pkgs.ripgrep
    pkgs.socat
    pkgs.util-linux
    pkgs.xz
    githubAppCredentialClient
    githubAppGitCredential
    githubAppGh
  ];
  hermesNixSandboxEtc = pkgs.runCommand "hermes-nix-sandbox-etc" { } ''
    mkdir -p "$out/etc"
    cat > "$out/etc/gitconfig" <<'EOF'
    [credential "https://github.com"]
      helper = /bin/github-app-git-credential
    EOF
  '';
  hermesNixSandboxLinkCommands = builtins.concatStringsSep "\n" (map (package: ''
    if [ -d ${package}/bin ]; then
      for program in ${package}/bin/*; do
      # Route package paths through an image-local alias. This prevents Nix's
      # reference scanner from treating them as image dependencies, while the
      # alias itself resolves to the deliberately mounted host store at runtime.
      target="/.nix-store/''${program#/nix/store/}"
      ln -sfn "$target" "bin/$(basename "$program")"
      done
    fi
  '') hermesNixSandboxPackages);

  # Only a symlink tree is put into the OCI layer. Its target closures are
  # retained by system.extraDependencies and reached via the read-only host
  # /nix/store mount. Do not record the target paths as references of this
  # output: dockerTools otherwise follows those references and copies every
  # package closure into the image.
  hermesNixSandboxRoot = pkgs.runCommand "hermes-nix-sandbox-root" {
    __structuredAttrs = true;
    unsafeDiscardReferences.out = true;
  } ''
    mkdir -p "$out/bin" "$out/etc" "$out/workspace"
    cd "$out"
    ln -s /nix/store "$out/.nix-store"
    ${hermesNixSandboxLinkCommands}
    gitconfig_target="${hermesNixSandboxEtc}"
    ln -s "/.nix-store/''${gitconfig_target#/nix/store/}/etc/gitconfig" "$out/etc/gitconfig"
  '';
  hermesNixSandboxEnv = [
    # Hermes' Docker backend supplies /root as an ephemeral tmpfs. Unlike
    # /home/hermes, it therefore exists on every newly created container.
    "HOME=/root"
    "PATH=/bin"
    "GIT_CONFIG_SYSTEM=/etc/gitconfig"
    "NIX_REMOTE=daemon"
    "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
  ];
  # Hash every declarative input that affects the resulting image. The schema
  # number must be bumped if the archive/config construction itself changes in
  # a way not represented below.
  hermesNixSandboxImageTag = builtins.substring 0 32 (builtins.hashString
    "sha256"
    (builtins.toJSON {
      schema = 1;
      root = toString hermesNixSandboxRoot;
      env = hermesNixSandboxEnv;
      workingDir = "/workspace";
    }));
  hermesNixSandboxImageRef =
    "localhost/hermes-nix-sandbox:${hermesNixSandboxImageTag}";
  # dockerTools.buildImage deliberately adds the whole Nix closure of a layer
  # to a docker archive. That is unsuitable here: the runtime already bind
  # mounts /nix/store. Emit the small Docker-archive format directly, preserving
  # only the symlink tree and not serialising any package closure.
  hermesNixSandboxImage = pkgs.runCommand "hermes-nix-sandbox.tar.gz" {
    __structuredAttrs = true;
    unsafeDiscardReferences.out = true;
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnutar pkgs.gzip ];
  } ''
    mkdir -p archive/layer
    tar -C ${hermesNixSandboxRoot} \
      --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
      -cf archive/layer/layer.tar .
    diff_id="$(sha256sum archive/layer/layer.tar | cut -d ' ' -f 1)"
    cat > archive/config.json <<EOF
    {"architecture":"amd64","config":{"Env":${builtins.toJSON hermesNixSandboxEnv},"WorkingDir":"/workspace"},"created":"1970-01-01T00:00:01Z","os":"linux","rootfs":{"diff_ids":["sha256:$diff_id"],"type":"layers"}}
    EOF
    cat > archive/manifest.json <<'EOF'
    [{"Config":"config.json","RepoTags":["hermes-nix-sandbox:${hermesNixSandboxImageTag}"],"Layers":["layer/layer.tar"]}]
    EOF
    tar -C archive --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
      -cf - . | gzip -n > "$out"
  '';

  # Podman uses a per-user image store in rootless mode. Load the declarative
  # image into Hermes' store before the service starts, without requiring a
  # privileged Podman API/socket.
  loadHermesNixSandboxImage = pkgs.writeShellScript "load-hermes-nix-sandbox-image" ''
    set -eu
    # Rootless Podman needs the setuid NixOS wrappers (newuidmap/newgidmap),
    # not the unprivileged shadow binaries in the Nix store.
    export PATH="${config.security.wrapperDir}:$PATH"

    # The content-addressed tag is unique to this Nix-built root, so loading it
    # never relies on replacing a mutable `latest` reference.
    ${pkgs.podman}/bin/podman load --quiet --input ${hermesNixSandboxImage}

    # Docker image IDs are the SHA-256 digest of config.json. Verify that the
    # immutable runtime tag resolves to the exact config embedded in the
    # declarative archive; fail closed rather than starting Hermes on stale
    # sandbox contents.
    expected_id="$(${pkgs.gzip}/bin/gzip -dc ${hermesNixSandboxImage} \
      | ${pkgs.gnutar}/bin/tar -xOf - ./config.json \
      | ${pkgs.coreutils}/bin/sha256sum \
      | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
    actual_id="$(${pkgs.podman}/bin/podman image inspect \
      ${hermesNixSandboxImageRef} --format '{{.Id}}')"
    # Docker commonly includes the algorithm prefix; Podman 5.8 returns the
    # same digest without it. Normalize both representations before comparing.
    actual_id="''${actual_id#sha256:}"
    if [ "$actual_id" != "$expected_id" ]; then
      printf 'sandbox image verification failed: expected %s, got %s\n' \
        "$expected_id" "$actual_id" >&2
      exit 1
    fi
  '';

  hermesPodmanContainerConf = pkgs.writeText "hermes-podman-containers.conf" ''
    [engine]
    cgroup_manager = "cgroupfs"
    events_logger = "file"
  '';
in
{
  # Hermes runs as a dedicated, unprivileged system user and persists its
  # sessions, skills, memory, and gateway state in /var/lib/hermes.
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    extraPlugins = [ nixosUpdatePlugin ];

    # Runtime-only credentials for the messaging gateways. These files are read
    # by the NixOS activation script and merged into
    # /var/lib/hermes/.hermes/.env; they must never be committed or placed in
    # the Nix store. telegram-gateway.env is root-owned (0600) and contains
    # TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS. matrix-gateway.env is
    # hermes-owned (0600) and contains only MATRIX_PASSWORD for the dedicated
    # @hermes Matrix account.
    environmentFiles = [
      "/var/lib/hermes/telegram-gateway.env"
      "/var/lib/hermes/matrix-gateway.env"
    ];

    environment = {
      # The API server itself stays on loopback. Tailscale Serve terminates
      # Tailnet-only HTTPS on the externally consumed port below.
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = "127.0.0.1";
      API_SERVER_PORT = toString hermesApiServerPort;

      MATRIX_HOMESERVER = "https://home.taila70923.ts.net:8443";
      MATRIX_USER_ID = "@hermes:home.taila70923.ts.net";
      MATRIX_ALLOWED_USERS = "@fabian:home.taila70923.ts.net";
      # Canonical room ID for #hermes-home:home.taila70923.ts.net. Hermes uses
      # it as the default destination for cron results and notifications.
      MATRIX_HOME_ROOM = "!VQsNUaWqHuXRQdXfOz:home.taila70923.ts.net";
      MATRIX_E2EE_MODE = "off";
      MATRIX_SESSION_SCOPE = "room";
      MATRIX_AUTO_THREAD = "true";
      # In DMs, reply to the triggering message in its own Matrix thread.
      # This keeps follow-ups attached to the original request and preserves
      # its context independently from the room timeline.
      MATRIX_DM_AUTO_THREAD = "true";
    };

    settings = {
      plugins.enabled = [ "nixos-update" ];

      # OpenAI Codex OAuth is used instead of an API key. The authenticated
      # credential is stored outside the repository in Hermes' state directory.
      model = {
        # Keep the flagship Codex model for the main agent, where tool use and
        # difficult coding or infrastructure work benefit from its quality.
        default = "gpt-5.6-sol";
        provider = "openai-codex";
        base_url = "https://chatgpt.com/backend-api/codex";
      };

      # Do not spend the ChatGPT/Codex quota on routine side tasks. OpenRouter
      # Flash models are inexpensive and leave Sol available for the main agent.
      auxiliary = {
        title_generation = {
          provider = "openrouter";
          model = "google/gemini-2.5-flash-lite";
          reasoning_effort = "none";
        };
        web_extract = {
          provider = "openrouter";
          model = "google/gemini-2.5-flash-lite";
          reasoning_effort = "none";
        };
        compression = {
          provider = "openrouter";
          model = "google/gemini-2.5-flash";
          reasoning_effort = "low";
        };
        vision = {
          provider = "openrouter";
          model = "google/gemini-2.5-flash";
          reasoning_effort = "none";
        };
        # The skill/memory improvement fork needs reliable tool use, but not
        # the premium interactive model. MiMo receives Hermes' compact review
        # digest when routed separately, limiting cold input-token cost.
        background_review = {
          provider = "openrouter";
          model = "xiaomi/mimo-v2.5";
          reasoning_effort = "low";
        };
      };

      terminal = {
        # The Docker backend also supports Podman: Hermes probes `docker` and
        # then `podman`.  Rootless Podman is the actual OCI runtime here.
        backend = "docker";
        timeout = 180;
        docker_image = hermesNixSandboxImageRef;
        docker_auto_mount_cwd = false;
        # Direct HTTPS is needed for git clone/push and GitHub CLI requests.
        # Authentication is still brokered through a local Unix socket below.
        docker_network = true;
         container_persistent = true;
        # Recreate the execution container after an activation so a refreshed
        # declarative image is actually used rather than a retained `latest`.
        docker_persist_across_processes = false;
        # Container root maps to the unprivileged host `hermes` user under
        # rootless Podman, so it can access the 0600 broker socket without
        # granting host-root privileges.
        docker_volumes = [
          # The Nix client and all of its dynamic-library closures are read
          # from the host store.  This must stay read-only.
          "/nix/store:/nix/store:ro"
          "/nix/var/nix/profiles:/nix/var/nix/profiles:ro"
          "/etc/nix:/etc/nix:ro"

          # Deliberate capability grant: permits `nix build`/`nix run` through
          # the host daemon without granting Hermes' home or secret files.
          "/nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket:rw"

          # The broker gives the container a short-lived installation token on
          # demand. The GitHub App private key and Hermes secrets stay host-only.
          "${githubCredentialSocket}:${githubCredentialSocket}:rw"

          # Kanban scratch tasks use host paths below this directory as their
          # working directory. Mount only the task workspaces, not the board
          # database or the rest of Hermes' state and secrets.
          # "${hermesChatKanbanWorkspaces}:${hermesChatKanbanWorkspaces}:rw"
        ];
      };

      # Use the more accurate local Whisper model for multilingual voice
      # messages. This is slower than the default `base` model but should reduce
      # German transcription errors while retaining English support.
      stt = {
        enabled = true;
        provider = "local";
        local.model = "small";
      };

      # Trust this private Hermes instance to execute commands without requiring
      # interactive approval in the CLI, Desktop app, or messaging gateways.
      approvals.mode = "off";

      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };
    };

    # Bootstrap the OpenAI Codex OAuth login on the server after deployment:
    #   sudo -u hermes HERMES_HOME=/var/lib/hermes/.hermes hermes auth add openai-codex
    # The resulting auth.json stays in /var/lib/hermes/.hermes and is preserved
    # across NixOS rebuilds.
  };

  systemd.sockets.hermes-nixos-update-broker = {
    description = "NixOS update broker socket for managed Hermes services";
    before = [ "hermes-agent.service" "hermes-serve.service" ];
    requiredBy = [ "hermes-agent.service" "hermes-serve.service" ];
    wantedBy = [ "sockets.target" ];
    listenStreams = [ nixosUpdateBrokerSocket ];
    socketConfig = {
      SocketMode = "0600";
      SocketUser = "hermes";
      SocketGroup = "hermes";
    };
  };

  systemd.services.hermes-nixos-update-broker = {
    description = "Broker the fixed NixOS update action and bounded logs for Hermes";
    requires = [ "hermes-nixos-update-broker.socket" ];
    after = [ "hermes-nixos-update-broker.socket" ];
    serviceConfig = {
      User = "root";
      Group = "root";
      ExecStart = "${nixosUpdateBroker}/bin/hermes-nixos-update-broker";
      Restart = "on-failure";
      RestartSec = 2;
      MemoryMax = "128M";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.services.hermes-agent.environment = {
    TELEGRAM_HOME_CHANNEL = "479215762";
    # Rootless Podman keeps locks and transient state here. The directory is
    # created by the required image-loader service below.
    XDG_RUNTIME_DIR = "/run/hermes-podman";
    CONTAINERS_CONF = hermesPodmanContainerConf;
  };
  systemd.services.hermes-agent.serviceConfig.EnvironmentFile = hermesApiSecretFile;
  # ProtectSystem=strict is retained; grant only Podman's dedicated transient
  # runtime directory rather than a broader part of /run.
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ "/run/hermes-podman" ];

  # Generate the API bearer token once on the host. It never enters Git or the
  # Nix store. To copy it into the Android app after deployment:
  #   sudo sed -n 's/^API_SERVER_KEY=//p' /var/lib/hermes/api-server.env
  systemd.services.hermes-api-secret = {
    description = "Provision the Hermes API server bearer token";
    before = [ "hermes-agent.service" ];
    requiredBy = [ "hermes-agent.service" ];

    path = [ pkgs.coreutils pkgs.gnugrep pkgs.openssl ];
    script = ''
      install -d -o root -g root -m 0755 /var/lib/hermes
      if ! test -e ${hermesApiSecretFile}; then
        umask 077
        token=$(openssl rand -hex 32)
        printf 'API_SERVER_KEY=%s\n' "$token" > ${hermesApiSecretFile}.new
        mv ${hermesApiSecretFile}.new ${hermesApiSecretFile}
      fi
      if ! grep -Eq '^API_SERVER_KEY=[0-9a-f]{64}$' ${hermesApiSecretFile}; then
        echo "hermes-api-secret: malformed existing secret file" >&2
        exit 1
      fi
      chown root:root ${hermesApiSecretFile}
      chmod 0600 ${hermesApiSecretFile}
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Android connects only over Tailnet HTTPS. Hermes remains bound to loopback;
  # Tailscale terminates TLS and forwards to the API server on localhost.
  systemd.services.hermes-api-tailnet-proxy = {
    description = "Tailscale HTTPS proxy for the Hermes API server";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" "hermes-agent.service" ];
    after = [ "tailscaled.service" "hermes-agent.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --https=${toString hermesApiTailnetHttpsPort} http://127.0.0.1:${toString hermesApiServerPort}";
      ExecStop = "${config.services.tailscale.package}/bin/tailscale serve --https=${toString hermesApiTailnetHttpsPort} off";
    };
  };

  # The image tarball is opaque to Nix's runtime-reference scanner. Retain the
  # store targets of its /bin symlinks even if no other system path needs one.
  system.extraDependencies = hermesNixSandboxPackages;

  # The socket is owned by `hermes` (0600). In a rootless Podman container,
  # container UID 0 maps to that unprivileged host user, not to host root.
  systemd.sockets.hermes-github-credential-broker = {
    description = "GitHub App credential socket for the Hermes sandbox";
    before = [ "hermes-agent.service" "hermes-serve.service" ];
    requiredBy = [ "hermes-agent.service" "hermes-serve.service" ];
    wantedBy = [ "sockets.target" ];
    listenStreams = [ githubCredentialSocket ];
    socketConfig = {
      SocketMode = "0600";
      SocketUser = "hermes";
      SocketGroup = "hermes";
    };
  };

  systemd.services.hermes-github-credential-broker = {
    description = "Mint short-lived GitHub App tokens for the Hermes sandbox";
    requires = [ "hermes-github-credential-broker.socket" ];
    after = [ "hermes-github-credential-broker.socket" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      User = "hermes";
      Group = "hermes";
      ExecStart = "${githubAppCredentialBroker}/bin/hermes-github-credential-broker";
      Restart = "on-failure";
      RestartSec = 2;
    };
    environment.HOME = "/var/lib/hermes";
  };

  virtualisation.podman.enable = true;

  # Rootless container namespaces require a subordinate-ID range.  The Hermes
  # account remains unprivileged on the host and is deliberately not added to
  # the rootful `podman` group.
  users.users.hermes = {
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
  };

  systemd.services.hermes-nix-sandbox-image = {
    description = "Load the rootless Podman image for Hermes Nix sandboxing";
    before = [ "hermes-agent.service" "hermes-serve.service" ];
    requiredBy = [ "hermes-agent.service" "hermes-serve.service" ];
    after = [ "nix-daemon.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      RemainAfterExit = true;
      RuntimeDirectory = "hermes-podman";
      RuntimeDirectoryMode = "0700";
    };

    environment = {
      HOME = "/var/lib/hermes";
      XDG_RUNTIME_DIR = "/run/hermes-podman";
      CONTAINERS_CONF = hermesPodmanContainerConf;
    };

    path = [ pkgs.podman ];
    script = ''
      exec ${loadHermesNixSandboxImage}
    '';
  };

  # Hermes resolves `podman` from PATH when the Docker terminal backend is
  # selected. Include NixOS' setuid mapping wrappers for rootless Podman; this
  # adds no rootful Podman socket capability.
  systemd.services.hermes-agent.path = [ rootlessPodmanWrapperPath pkgs.podman ];
  # The image loader and Hermes are separate units. Loading a changed image tag
  # does not by itself restart a long-running Hermes process, so it could keep
  # tool containers created from the previous image. Couple the restart to the
  # immutable image derivation; unit ordering runs the loader before Hermes.
  systemd.services.hermes-agent.restartTriggers = [ hermesNixSandboxImage ];

  # Restrict the remote desktop backend to the tailnet. The NixOS firewall
  # still blocks port 9119 on the public network interfaces.
  services.tailscale.enable = true;
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9119 ];

  # Serve the full browser dashboard (including the embedded chat), not the
  # headless `hermes serve` backend used exclusively by native remote clients.
  # It is intentionally separate from the messaging gateway service above.
  # /var/lib/hermes/remote-gateway.env is root-owned (0600) and contains:
  # HERMES_DASHBOARD_BASIC_AUTH_USERNAME, HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  # (or HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH), and a stable
  # HERMES_DASHBOARD_BASIC_AUTH_SECRET.
  systemd.services.hermes-serve = {
    description = "Hermes remote desktop backend";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];

    # Do not start a network listener until its authentication credentials have
    # been provisioned outside the Nix store. Either a password hash or a
    # root-readable plaintext password is accepted for initial bootstrapping.
    unitConfig.ConditionPathExists = "/var/lib/hermes/remote-gateway.env";
    preStart = ''
      test -n "$HERMES_DASHBOARD_BASIC_AUTH_USERNAME"
      test -n "$HERMES_DASHBOARD_BASIC_AUTH_SECRET"
      if ! test -n "$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH" \
        && ! test -n "$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD"; then
        echo "hermes-serve: configure a basic-auth password or password hash" >&2
        exit 1
      fi
    '';

    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
      HERMES_MANAGED = "true";
      MESSAGING_CWD = "/var/lib/hermes/workspace";
      XDG_RUNTIME_DIR = "/run/hermes-podman";
      CONTAINERS_CONF = hermesPodmanContainerConf;
    };

    serviceConfig = {
      User = "hermes";
      Group = "hermes";
      WorkingDirectory = "/var/lib/hermes/workspace";
      EnvironmentFile = "/var/lib/hermes/remote-gateway.env";
      ExecStart = "${config.services.hermes-agent.package}/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open";
      Restart = "always";
      RestartSec = 5;
      UMask = "0007";

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = false;
      ReadWritePaths = [
        "/var/lib/hermes"
        "/var/lib/hermes/workspace"
        "/run/hermes-podman"
      ];
      PrivateTmp = true;
    };

    path = [
      config.services.hermes-agent.package
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.podman
      rootlessPodmanWrapperPath
    ];

    # As with the messaging gateway, never retain tool containers from an older
    # declarative sandbox image after activation.
    restartTriggers = [ hermesNixSandboxImage ];
  };
}
