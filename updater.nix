{ pkgs, ... }:

let
  updateNixosApp = pkgs.writeShellApplication {
    name = "nixos-update";
    runtimeInputs = [ pkgs.git pkgs.nixos-rebuild ];  # Optional: ensure deps are present
    text = ''
      cd /etc/nixos

      old_commit=$(git rev-parse HEAD)
      git fetch origin
      remote_commit=$(git rev-parse '@{u}')

      if [ "$old_commit" != "$remote_commit" ]; then
          echo "New commit detected. Updating..."
          git pull --ff-only
          nixos-rebuild switch --no-update-lockfile
      else
          echo "No update needed."
      fi
    '';
  };
in {
  environment.systemPackages = [ updateNixosApp ];

  systemd.services.nixos-update = {
    description = "Update NixOS configuration from Git if changed";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [ "${updateNixosApp}/bin/nixos-update" ];
    };
  };

  systemd.timers.nixos-update = {
    description = "Daily NixOS update check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1d";
      Persistent = true;
    };
  };
}