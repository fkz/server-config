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

  githubCredentialSocket = "/run/hermes-github-credential-broker/socket";

  # The GitHub App private key remains on the host. The sandbox gets only these
  # clients, which ask the host-side broker for a short-lived installation token
  # over a Unix socket.
  githubAppGitCredential = pkgs.writeShellScriptBin "github-app-git-credential" ''
    set -eu
    case "''${1:-get}" in
      get) ;;
      *) exit 0 ;;
    esac
    cat >/dev/null
    printf 'get\n' | ${pkgs.socat}/bin/socat - UNIX-CONNECT:${githubCredentialSocket}
  '';
  githubAppGh = pkgs.writeShellScriptBin "github-app-gh" ''
    set -eu
    response=$(printf 'get\n' | ${pkgs.socat}/bin/socat - UNIX-CONNECT:${githubCredentialSocket})
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
                token = subprocess.run(
                    ["/var/lib/hermes/.hermes/scripts/github-app-token"],
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
            except Exception as error:
                print(f"GitHub credential broker: {error}", file=sys.stderr)
                connection.sendall(b"error=credential unavailable\n\n")
  '';

  hermesNixSandboxPackages = [
    pkgs.bash
    pkgs.coreutils
    pkgs.git
    pkgs.gh
    pkgs.nix
    pkgs.socat
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
  # A small /bin symlink tree is the only executable surface supplied by the
  # image.  Its targets are immutable store paths, resolved after /nix/store is
  # mounted read-only from the host.
  hermesNixSandboxRoot = pkgs.buildEnv {
    name = "hermes-nix-sandbox-root";
    paths = hermesNixSandboxPackages;
    pathsToLink = [ "/bin" ];
  };
  hermesNixSandboxImage = pkgs.dockerTools.buildLayeredImage {
    name = "hermes-nix-sandbox";
    tag = "latest";
    contents = [ hermesNixSandboxRoot hermesNixSandboxEtc ];
    config = {
      Env = [
        "HOME=/home/hermes"
        "PATH=/bin"
        "GIT_CONFIG_SYSTEM=/etc/gitconfig"
        "NIX_REMOTE=daemon"
      ];
      WorkingDir = "/workspace";
    };
  };

  # Podman uses a per-user image store in rootless mode.  Load the declarative
  # image into Hermes' store before the service starts, without requiring a
  # privileged Podman API/socket.
  loadHermesNixSandboxImage = pkgs.writeShellScript "load-hermes-nix-sandbox-image" ''
    set -eu
    # Rootless Podman needs the setuid NixOS wrappers (newuidmap/newgidmap),
    # not the unprivileged shadow binaries in the Nix store.
    export PATH="${config.security.wrapperDir}:$PATH"
    image=hermes-nix-sandbox:latest
    if ! ${pkgs.podman}/bin/podman image exists "$image"; then
      ${pkgs.podman}/bin/podman load --quiet --input ${hermesNixSandboxImage}
    fi
  '';
in
{
  # Hermes runs as a dedicated, unprivileged system user and persists its
  # sessions, skills, memory, and gateway state in /var/lib/hermes.
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

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
      # OpenAI Codex OAuth is used instead of an API key. The authenticated
      # credential is stored outside the repository in Hermes' state directory.
      model = {
        default = "gpt-5.6-terra";
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

  systemd.services.hermes-agent.environment.TELEGRAM_HOME_CHANNEL = "479215762";

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

  # The Hermes desktop app connects to this backend, not to `hermes gateway`.
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
    };

    serviceConfig = {
      User = "hermes";
      Group = "hermes";
      WorkingDirectory = "/var/lib/hermes/workspace";
      EnvironmentFile = "/var/lib/hermes/remote-gateway.env";
      ExecStart = "${config.services.hermes-agent.package}/bin/hermes serve --host 0.0.0.0 --port 9119";
      Restart = "always";
      RestartSec = 5;
      UMask = "0007";

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = false;
      ReadWritePaths = [ "/var/lib/hermes" "/var/lib/hermes/workspace" ];
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
