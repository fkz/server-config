{ pkgs, ... }:

let
  # The receiver script is inlined from the repo so there is a single source of
  # truth. Only the HMAC secret stays host-side (never in the Nix store).
  receiver = pkgs.writers.writePython3Bin "github-webhook-receiver" { } (
    builtins.readFile ./github-webhook/receiver.py
  );

  # Shared secret for HMAC-SHA256 verification of incoming webhook deliveries.
  # Provision this file on the host (root-owned 0400) before enabling the hook:
  #   install -Dm0400 /dev/stdin /var/lib/hermes/.hermes/secrets/github-webhook-secret \
  #     <<< "$(openssl rand -hex 32)"
  secretPath = "/var/lib/hermes/.hermes/secrets/github-webhook-secret";
in {
  environment.systemPackages = [ receiver ];

  systemd.services.github-webhook-receiver = {
    description = "GitHub webhook receiver that triggers NixOS updates on push to main";
    after = [ "network-online.target" "nss-lookup.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      ExecStart = "${receiver}/bin/github-webhook-receiver";
      Restart = "on-failure";
      RestartSec = 2;
      # The receiver is a tiny event loop; bound memory protects the host.
      MemoryMax = "64M";

      # The service binds a localhost TCP socket (AF_INET) and calls
      # systemctl, which talks to systemd over the bus (AF_UNIX). No other
      # address families are needed.
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];

      # Root already holds every capability; drop the bounding set so a
      # compromise cannot re-acquire privileged operations.
      CapabilityBoundingSet = [ "" ];
      AmbientCapabilities = [ "" ];
      NoNewPrivileges = true;

      # Filesystem isolation. The host store and the D-Bus socket are
      # read-only; only the receiver's tmp and the secret path are needed.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectControlGroups = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;

      # The receiver refuses to act when the secret is missing, so it is safe
      # to start regardless. nginx proxies here only after this unit is up.
      RestartPreventExitStatus = [ ];
    };
  };
}
