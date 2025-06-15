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

  networking.firewall = {
    enable = true;
    allowPing = true;

    allowedTCPPorts = [ 443 80 ];
  };

    services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."assistant.schmitthenner.eu" = {
      enableACME = true;
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://localhost:8123";
        proxyWebsockets = true; # Home Assistant uses websockets
      };
    };
  };

  security.acme = {
    acceptTerms = true;
    email = "development@schmitthenner.eu";
    certs."assistant.schmitthenner.eu" = {
      extraDomainNames = [ ];
    };
  };
}
