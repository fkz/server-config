{ config, pkgs, ... }:

let
  paseoPort = 6767;
  tailnetHost = "home.taila70923.ts.net";
  passwordFile = "/var/lib/hermes/paseo-password.env";
  legacyPasswordFile = "/var/lib/paseo/password.env";
in
{
  services.paseo = {
    enable = true;

    # Paseo launches Hermes through ACP. Run both processes under the same
    # unprivileged account so the child can use Hermes' managed configuration,
    # OAuth credentials, memories, skills, workspaces, and Podman state.
    user = "hermes";
    group = "hermes";
    dataDir = "/var/lib/hermes/.paseo";
    inheritUserEnvironment = true;

    # Paseo cannot bind to an interface name. Listen on all addresses, but open
    # its port exclusively on tailscale0 below; the public and LAN interfaces
    # remain blocked by the NixOS firewall.
    listenAddress = "0.0.0.0";
    port = paseoPort;
    openFirewall = false;

    # Direct Tailnet access is the only remote path. Do not also register this
    # daemon with Paseo's hosted relay.
    relay.enable = false;
    hostnames = [ "home" tailnetHost ];

    settings = {
      daemon.cors.allowedOrigins = [
        "http://home:${toString paseoPort}"
        "http://${tailnetHost}:${toString paseoPort}"
      ];

      agents.providers.hermes = {
        extends = "acp";
        label = "Hermes";
        description = "Nous Research self-improving AI agent";
        command = [
          "${config.services.hermes-agent.package}/bin/hermes"
          "acp"
        ];
        env = {
          HOME = "/var/lib/hermes";
          HERMES_HOME = "/var/lib/hermes/.hermes";
          HERMES_MANAGED = "true";
        };
      };
    };

    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
      HERMES_MANAGED = "true";
      MESSAGING_CWD = "/var/lib/hermes/workspace";
    };
  };

  # Keep the daemon unreachable from public and LAN interfaces. Tailscale
  # already encrypts the transport; Paseo password authentication additionally
  # restricts which tailnet clients may control coding agents.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ paseoPort ];

  # Generate a stable, host-local password on first start. The secret never
  # enters Git or the Nix store. Retrieve it for the Android app with:
  #   sudo sed -n 's/^PASEO_PASSWORD=//p' /var/lib/hermes/paseo-password.env
  systemd.services.paseo-password = {
    description = "Provision the Paseo daemon password";
    before = [ "paseo.service" ];
    requiredBy = [ "paseo.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };

    script = ''
      if ! test -s ${passwordFile}; then
        if test -s ${legacyPasswordFile}; then
          install -m 0600 ${legacyPasswordFile} ${passwordFile}
        else
          password="$(${pkgs.openssl}/bin/openssl rand -hex 24)"
          printf 'PASEO_PASSWORD=%s\n' "$password" > ${passwordFile}.tmp
          chmod 0600 ${passwordFile}.tmp
          mv ${passwordFile}.tmp ${passwordFile}
        fi
      fi
    '';
  };

  systemd.services.paseo = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig = {
      EnvironmentFile = passwordFile;
      WorkingDirectory = "/var/lib/hermes/workspace";
    };
  };
}
