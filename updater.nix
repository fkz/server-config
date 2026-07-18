{ pkgs, ... }:

let
  updateNixosApp = pkgs.writeShellApplication {
    name = "nixos-update";
    runtimeInputs = [ pkgs.coreutils pkgs.git pkgs.nixos-rebuild ];
    text = builtins.readFile ./scripts/nixos-update.sh;
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
      TimeoutStartSec = "10min";
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