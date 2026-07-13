{ config, pkgs, ... }:

let
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

  # Host-side plugin for the one privileged action that must stay outside the
  # terminal sandbox. The handler itself forces fresh, non-persisted human
  # consent before it can contact the fixed root-owned update broker.
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
  # Root-owned broker for the one fixed host action. In addition to Unix-socket
  # permissions, it verifies SO_PEERCRED against the current MainPID of the two
  # managed Hermes services. A separate process running as `hermes` therefore
  # cannot reuse this capability, and the socket is not mounted into Podman.
  nixosUpdateBroker = pkgs.writers.writePython3Bin "hermes-nixos-update-broker" { } ''
    import os
    import pwd
    import socket
    import struct
    import subprocess
    import sys

    if int(os.environ.get("LISTEN_FDS", "0")) != 1:
        raise SystemExit("expected exactly one systemd socket")

    systemd_package = (
        "${pkgs.systemd}"
    )
    systemctl = os.path.join(systemd_package, "bin", "systemctl")
    hermes_uid = pwd.getpwnam("hermes").pw_uid
    listener = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)


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
        try:
            return int(result.stdout.strip()) if result.returncode == 0 else 0
        except ValueError:
            return 0


    def receive_request(connection):
        request = b""
        while len(request) < 32 and not request.endswith(b"\n"):
            chunk = connection.recv(32 - len(request))
            if not chunk:
                break
            request += chunk
        return request


    while True:
        connection, _ = listener.accept()
        with connection:
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
                if receive_request(connection) != b"start\n":
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
        | jq -r '.[] | select(.account.login == "fkz") | .id' | head -n 1)
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
    import socket
    import sys

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(70)
        client.connect("${githubCredentialSocket}")
        client.sendall(b"get\n")
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
    cat >/dev/null
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

    if int(os.environ.get("LISTEN_FDS", "0")) != 1:
        raise SystemExit("expected exactly one systemd socket")

    listener = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    while True:
        connection, _ = listener.accept()
        with connection:
            request = connection.recv(16)
            if request != b"get\n":
                connection.sendall(b"error=unsupported request\n\n")
                continue
            try:
                token_command = (
                    "${githubAppToken}"
                    "/bin/github-app-token"
                )
                token = subprocess.run(
                    [token_command],
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
    [{"Config":"config.json","RepoTags":["hermes-nix-sandbox:latest"],"Layers":["layer/layer.tar"]}]
    EOF
    tar -C archive --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
      -cf - . | gzip -n > "$out"
  '';

  # Podman uses a per-user image store in rootless mode.  Load the declarative
  # image into Hermes' store before the service starts, without requiring a
  # privileged Podman API/socket.
  loadHermesNixSandboxImage = pkgs.writeShellScript "load-hermes-nix-sandbox-image" ''
    set -eu
    # Rootless Podman needs the setuid NixOS wrappers (newuidmap/newgidmap),
    # not the unprivileged shadow binaries in the Nix store.
    export PATH="${config.security.wrapperDir}:$PATH"
    # Reload on every activation: the fixed image tag is intentional for
    # declarative configuration, and podman load replaces it with the Nix-built
    # image from this generation.
    ${pkgs.podman}/bin/podman load --quiet --input ${hermesNixSandboxImage}
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
        # GPT-5.6 Sol is the flagship Codex model tier (Sol > Terra > Luna).
        default = "gpt-5.6-sol";
        provider = "openai-codex";
        base_url = "https://chatgpt.com/backend-api/codex";
      };

      terminal = {
        # The Docker backend also supports Podman: Hermes probes `docker` and
        # then `podman`.  Rootless Podman is the actual OCI runtime here.
        backend = "docker";
        timeout = 180;
        docker_image = "hermes-nix-sandbox:latest";
        docker_auto_mount_cwd = false;
        # Direct HTTPS is needed for git clone/push and GitHub CLI requests.
        # Authentication is still brokered through a local Unix socket below.
        docker_network = true;
        docker_persistent_filesystem = false;
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
    description = "Queue the fixed root-owned NixOS update for Hermes";
    requires = [ "hermes-nixos-update-broker.socket" ];
    after = [ "hermes-nixos-update-broker.socket" ];
    serviceConfig = {
      User = "root";
      Group = "root";
      ExecStart = "${nixosUpdateBroker}/bin/hermes-nixos-update-broker";
      Restart = "on-failure";
      RestartSec = 2;
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
  # ProtectSystem=strict is retained; grant only Podman's dedicated transient
  # runtime directory rather than a broader part of /run.
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ "/run/hermes-podman" ];

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
  };
}
