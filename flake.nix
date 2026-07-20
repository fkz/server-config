{
  inputs = {
    # Stable NixOS release channel. Update the lock file with:
    #   nix flake update --flake /etc/nixos
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    paseo.url = "github:getpaseo/paseo";
  };
  outputs = inputs@{ self, nixpkgs, hermes-agent, paseo, ... }: {
    # NOTE: 'nixos' is the default hostname
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        hermes-agent.nixosModules.default
        paseo.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}

