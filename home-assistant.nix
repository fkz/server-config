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
      frontend = {
        enabled = true;
        base_url = "/zig2q";
        url = "https://assistant.schmitthenner.eu";
      };
    };
  };

  services.home-assistant = {
    enable = true;
    extraComponents = [ "mobile_app" "mqtt" "radio_browser" "default_config" "met" "esphome" "ollama" "command_line" ];
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
      command_line = [{
        sensor = {
          name = "CPU Temperature";
          command = "cat /sys/class/thermal/thermal_zone2/temp";
          unit_of_measurement = "°C";
          value_template = "{{ (value | int / 1000) | round(1) }}";
        };
      }];
      mqtt = [{
        sensor = {
          name = "Internet Download Speed";
          state_topic = "home-speedtest";
          device_class = "data_rate";
          unique_id = "int_dl_speed";
          value_template = "{{ value_json.servers[0].dl_speed | int / 125000 | round(1) }}";
        };
      } {
        sensor = {
          name = "Internet Upload Speed";
          state_topic = "home-speedtest";
          device_class = "data_rate";
          unique_id = "int_ul_speed";
          value_template = "{{ value_json.servers[0].ul_speed | int / 125000 | round(1) }}";
        };
      }];
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
      locations."/zig2q/" = {
        basicAuthFile = "/var/lib/htpasswd";
        proxyPass = "http://localhost:8080/";
        proxyWebsockets = true;
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

  systemd.services.speedtest = {
    description = "Run speedtest-go and log result";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/bin/sh -c '${pkgs.speedtest-go}/bin/speedtest-go --json | ${pkgs.mosquitto}/bin/mosquitto_pub -h localhost -t home-speedtest -l'";
    };
  };

  systemd.timers.speedtest = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "30min";
      Unit = "speedtest.service";
    };
  };

  systemd.services.inwx-ddns = {
    description = "INWX DDNS updater";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellApplication {
        name = "inwx-ddns";
        runtimeInputs = [pkgs.iproute2 pkgs.gawk pkgs.curl]; 
        text = ''
          USERNAME=home-assistant
          PASSWORD=SrQ3kQN6ygbEcAv4agcpCVWiJ
          HOSTNAME=assistant.schmitthenner.eu

          IPV6=$(ip -6 addr show dev enp0s25 \
            | awk '/inet6/ && /global/ && /dynamic/ && /mngtmpaddr/ && !/temporary/ && !/deprecated/ { print $2 }' \
            | cut -d/ -f1 | head -n1)
          
          UPDATE_URL="https://$USERNAME:$PASSWORD@dyndns.inwx.com/nic/update?hostname=$HOSTNAME"
          [ -n "$IPV6" ] && UPDATE_URL="$UPDATE_URL&myipv6=$IPV6"

          echo "Updating INWX with:"
          echo "  IPv6: $IPV6"

          curl -s "$UPDATE_URL"
        '';
      }}/bin/inwx-ddns";
    };
  };

  systemd.timers.inwx-ddns = {
    description = "Run INWX DDNS updater every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };
}
