{ config, pkgs, ... }:

{
  # Hermes runs as a dedicated, unprivileged system user and persists its
  # sessions, skills, memory, and gateway state in /var/lib/hermes.
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    # Runtime-only credentials for the messaging gateway. This file is read by
    # the NixOS activation script and merged into /var/lib/hermes/.hermes/.env;
    # it must never be committed or placed in the Nix store. Provision it as a
    # root-owned 0600 file containing TELEGRAM_BOT_TOKEN and
    # TELEGRAM_ALLOWED_USERS (the owner's numeric Telegram user ID).
    environmentFiles = [ "/var/lib/hermes/telegram-gateway.env" ];

    settings = {
      # OpenAI Codex OAuth is used instead of an API key. The authenticated
      # credential is stored outside the repository in Hermes' state directory.
      model = {
        default = "gpt-5.6-terra";
        provider = "openai-codex";
        base_url = "https://chatgpt.com/backend-api/codex";
      };

      terminal = {
        backend = "local";
        timeout = 180;
      };

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
    ];
  };
}
