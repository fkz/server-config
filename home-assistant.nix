{ pkgs, ... }: {
  services.mosquitto.enable = true;
  
  services.zigbee2mqtt = {
    enable = true;
    settings = {
      permit_join = false;
      mqtt = {
        base_topic = "zigbee2mqtt";
        server = "mqtt://localhost";
      };
      serial = {
        port = "/dev/serial/by-id/usb-Texas_Instruments_TI_CC2531_USB_CDC___0X00124B001DF40090-if00";
      };
      homeassistant = true;
      frontend = true;
    };

    package = pkgs.zigbee2mqtt.overrideAttrs (final: prev: {
      version = "618b318214ca58b94a1068e0320d9a163a1cd22f";
      npmDepsHash = "sha256-06otexq4T8fRnAUq2yTmFRQIp/c13NXKuQ6AdgbwwzI=";

      src = pkgs.fetchFromGitHub {
        owner = "Koenkk";
        repo = "zigbee2mqtt";
        rev = final.version;
        hash = "sha256-UFVK8C/NYEZT4AcHowwvxaohk0mDgb8isYBuOoDkLg8=";
      };

      npmDeps = prev.npmDeps.overrideAttrs {
        outputHash = final.npmDepsHash;
        src = final.src;
      };
    });
  };

  services.home-assistant = {
    enable = true;
    extraComponents = [ "mobile_app" "mqtt" "radio_browser" "default_config" "met" "esphome" "ollama" ];
    config = {
      default_config = {};
      homeassistant = {
        name = "Home";
        unit_system = "metric";
        time_zone = "UTC";
        external_url = "https://assistant.schmitthenner.eu";
      };
      frontend = {
        themes = "!include_dir_merge_named themes";
      };
      http = {
        use_x_forwarded_for = true;
        trusted_proxies = [ "::1" "127.0.0.1" ]; 
      };
    };
  };
}