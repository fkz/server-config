{
  inputs = {
    # Stable NixOS release channel. Update the lock file with:
    #   nix flake update --flake /etc/nixos
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };
  outputs = inputs@{ self, nixpkgs, ... }: {
    # NOTE: 'nixos' is the default hostname
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [ ./configuration.nix ];
    };
  };
}

