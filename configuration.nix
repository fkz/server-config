# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./updater.nix
      ./wifi.nix
      ./home-assistant.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.sshd.enable = true;

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDEfr34RLh9BEV1h8wRWykGEBIDTLrSKcJBirlupGic8zaOOQHoxKrEI1LxViFiYdWjFdAgmhA7Fjyq6q+HYKILUQqYpJ16AC2D/8Hw6juxQExVVRSjTApu1XK1MUA/vz5JKapK1v0jlC5AmHvv85REvHlxfIdnkmoWAtG4hdIxqG2Aiz9DwJN2D99ZFZr2qJqODXo2mCgraY+GZ+01rBOxvtT4f62YWxaCZx3HtiKpthU51zRduTVHIxB0qnms+HfsLANAauNhJP08vAtzdCdbquucVp1tS0pNJsENaiiNnBl/htJmQPTdoH4y9fSCjBj/vlH1ZVcmOxH2F/a7TVEV fabian@nixos"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDIGo1MuVZL1/FEM7eM8VQoyR5JWM1QwgqZgdFPn7Hi3XF0lihkPUh1Dn7L2DdNXIfXtqM5QhqK1AOl3BCV1xxRQfrHM65EOdA0F/u++8rdz9+2Vfj00oraWMJSo3wQXwmpNW0BzduqFCzG8CQs8lN59Q7tGpYgn78LHTQRuUAet74CFYedZus4yNqgVD1rXtJfNy4uGY5Rd3cpwQ9LjQJf8NfIaaTYwgZ/GndiRei0lPF1i51L5cogsFoqQzc0BSONHMh6fepd1DrbohG558uJasK1t4S2FH8f7bkBWbz1ZkwG80kGvfUFzL4scdx3LAktn7pS1PQRFmCZf2m/NMrJ+jROmowcZRgSxru+LN2+9Shnb4xUn3CBQ5c8yJMdBsugKUxisO+KRaOxcO8R5JdcotwxSQXpOvM6ySZnxroIWk+UJj1TmprHlnGL7UulPaOAFIkv2ms7pMWxBkZnIorWj+Hy4AmN8VnVQI1ZpPnGVCuN4bL4NV5/oM+bv/S0Oyk= claptop"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC6tS3xXtC/d/Cyny9yvNvfC/f2qFCbPUAiPVlxGQdDD2214fqBRaHJ3QiXJtLIlvqtMrBC8sJFw4UqXnToVBWDUWXDXt3PziD4pSnpDQo8O/YO7UuzWDGGyalcn4+bzvuZKI0nKSiYfNvAyjI2KP1uasdHVF7I024dZS9XBlFYWf9IUZ8fxydzcVYQbeV1p0UznIpk75ZofSxwBa0k6m3ioNg8PhGMtGjpea1yZmkpkcIVeUJeh1KdG2gfIdhN/gq03bgS6izItXFLZ5xbMwzqwvoCbdrX/76LUq9XHXFEpykGwP9g49mQkBh3RCJ06zajKjdgwEgjhJRa89canagmAkdt8lPHmuQ741NHtEcZUUcJ1BjJZ+MIqaj5dboUm1nhai6YuAwta7ZN1oNNcv2J3Doy2L7rMfSw609ThcgImp4S2IA14SJKcrclwJ2hAZh8VR2i7FcOHDrJC63cYCrII+dN5iDAY0ntWVkJ74xGuHU/C64UoOGKZa8m3n8da1OEX7gpw6LYN3bOWjNIK7/96VxUOJ6bMxLbnWgzajm7qpbANTvdzFcHhd7Cr+KRLKafCUec3f16ULKkbAH44H4eajLLm8r5a+NSzgKomnyKWImIVtdYjVD5r9YGe3ar/ui7MYwQyMm2yooYP4EP/ycM1z+En2wc91umlnfwLXOU4Q== A"
  ];

  # networking.hostName = "nixos"; # Define your hostname.
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  # time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;


  

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # services.pulseaudio.enable = true;
  # OR
  # services.pipewire = {
  #   enable = true;
  #   pulse.enable = true;
  # };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  # users.users.alice = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
  #   packages = with pkgs; [
  #     tree
  #   ];
  # };

  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
    vim git lm_sensors
  ];


  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Did you read the comment?

}

