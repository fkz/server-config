{ config, pkgs, portfolioKompass, ... }:

let
  appPort = 9320;
  tailnetHttpsPort = 9443;
  dataDir = "/var/lib/portfolio-kompass";
  envFile = "${dataDir}/portfolio-kompass.env";
  package = portfolioKompass.packages.${pkgs.system}.default;
in
{
  users.groups.portfolio-kompass = { };
  users.users.portfolio-kompass = {
    isSystemUser = true;
    group = "portfolio-kompass";
    home = dataDir;
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 portfolio-kompass portfolio-kompass -"
  ];

  # Keep API credentials outside Git and the Nix store. A cron secret is
  # generated once; TWELVE_DATA_API_KEY can be added manually to this file.
  systemd.services.portfolio-kompass-secrets = {
    description = "Provision Portfolio Kompass runtime secrets";
    before = [ "portfolio-kompass.service" ];
    requiredBy = [ "portfolio-kompass.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];

    path = [ pkgs.coreutils pkgs.gnugrep pkgs.openssl ];
    script = ''
      if ! test -e ${envFile}; then
        install -m 0600 /dev/null ${envFile}
      fi

      if ! grep -q '^CRON_SECRET=' ${envFile}; then
        secret="$(openssl rand -hex 32)"
        printf '\nCRON_SECRET=%s\n' "$secret" >> ${envFile}
      fi

      chown root:root ${envFile}
      chmod 0600 ${envFile}
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
  };

  systemd.services.portfolio-kompass = {
    description = "Portfolio Kompass";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    environment = {
      NODE_ENV = "production";
      NEXT_TELEMETRY_DISABLED = "1";
      HOSTNAME = "127.0.0.1";
      PORT = toString appPort;
      DATABASE_PATH = "${dataDir}/portfolio.db";
    };

    serviceConfig = {
      User = "portfolio-kompass";
      Group = "portfolio-kompass";
      WorkingDirectory = package;
      EnvironmentFile = envFile;
      ExecStart = "${pkgs.nodejs_24}/bin/node ${package}/server.js";
      Restart = "always";
      RestartSec = 5;
      UMask = "0027";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ dataDir ];
    };
  };

  # The dashboard contains private financial data. Keep the Node process on
  # loopback and expose it only to authenticated devices in the Tailnet.
  systemd.services.portfolio-kompass-tailnet-proxy = {
    description = "Tailscale HTTPS proxy for Portfolio Kompass";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" "portfolio-kompass.service" ];
    after = [ "tailscaled.service" "portfolio-kompass.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --https=${toString tailnetHttpsPort} http://127.0.0.1:${toString appPort}";
      ExecStop = "${config.services.tailscale.package}/bin/tailscale serve --https=${toString tailnetHttpsPort} off";
    };
  };

  systemd.services.portfolio-kompass-sync = {
    description = "Import daily Portfolio Kompass prices";
    wants = [ "network-online.target" "portfolio-kompass.service" ];
    after = [ "network-online.target" "portfolio-kompass.service" ];

    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = envFile;
    };

    path = [ pkgs.curl ];
    script = ''
      if test -z "''${TWELVE_DATA_API_KEY:-}"; then
        echo "TWELVE_DATA_API_KEY is not configured; skipping price import"
        exit 0
      fi

      curl --fail-with-body --silent --show-error \
        --retry 3 --retry-all-errors \
        -X POST \
        -H "Authorization: Bearer $CRON_SECRET" \
        http://127.0.0.1:${toString appPort}/api/sync-prices
    '';
  };

  systemd.timers.portfolio-kompass-sync = {
    description = "Daily Portfolio Kompass price import";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 20:30:00";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };
}
