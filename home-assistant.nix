{ pkgs, ... }:

let
  publicHost = "assistant.schmitthenner.eu";
  tailnetHost = "home.taila70923.ts.net";

  homeAssistantLocations = {
    "/" = {
      # Use the explicit IPv4 loopback address. Resolving `localhost` to ::1
      # produces nginx 502 responses when Home Assistant only listens on IPv4.
      proxyPass = "http://127.0.0.1:8123";
      proxyWebsockets = true;
    };
    "/zig2q/" = {
      basicAuthFile = "/var/lib/htpasswd";
      proxyPass = "http://127.0.0.1:8080/";
      proxyWebsockets = true;
    };
  };

  # Expose the deployment receiver only on the tailnet vhost. The trailing
  # slash strips the /webhook/ prefix before forwarding to the loopback-only
  # receiver, which independently requires a valid HMAC-SHA256 signature.
  webhookLocation = {
    "/webhook/" = {
      proxyPass = "http://127.0.0.1:8081/";
      extraConfig = ''
        client_max_body_size 1m;
      '';
    };
  };
in
{
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
        # Zigbee2MQTT 2.x no longer reliably auto-detects this TI coordinator.
        adapter = "zstack";
      };
      # Zigbee2MQTT 2.x represents the Home Assistant integration as an object.
      homeassistant = {
        enabled = true;
      };
      frontend = {
        enabled = true;
        base_url = "/zig2q";
        url = "https://${publicHost}";
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
        external_url = "https://${publicHost}";
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

    virtualHosts.${publicHost} = {
      enableACME = true;
      forceSSL = true;
      locations = homeAssistantLocations;
    };

    # MagicDNS resolves both names to the Tailscale address. Keep this vhost on
    # plain HTTP: the tailnet transport is already encrypted, while a TLS
    # certificate for the short name `home` cannot be valid. This lets enrolled
    # devices open http://home without weakening or replacing the public HTTPS
    # endpoint above.
    virtualHosts.home = {
      serverAliases = [ tailnetHost ];
      locations = homeAssistantLocations // webhookLocation;
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "development@schmitthenner.eu";
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

          # IPv6: the server's global dynamic SLAAC address.
          IPV6=$(ip -6 addr show dev enp0s25 \
            | awk '/inet6/ && /global/ && /dynamic/ && /mngtmpaddr/ && !/temporary/ && !/deprecated/ && $2 ~ /^[23][0-9a-fA-F]*:/ { print $2 }' \
            | cut -d/ -f1 | head -n1)

          # IPv4: the public IPv4 as seen by the internet (the Fritzbox'
          # external address, since the server sits behind NAT). Query an
          # external service so we publish the routable address, not the
          # server's private 192.168.x.x. Falls back to letting INWX use the
          # request source IP when the lookup fails.
          IPV4=$(curl -s --max-time 10 https://api.ipify.org || true)
          if ! echo "$IPV4" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            IPV4=""
          fi

          UPDATE_URL="https://$USERNAME:$PASSWORD@dyndns.inwx.com/nic/update?hostname=$HOSTNAME"
          [ -n "$IPV6" ] && UPDATE_URL="$UPDATE_URL&myipv6=$IPV6"
          [ -n "$IPV4" ] && UPDATE_URL="$UPDATE_URL&myip=$IPV4"

          echo "Updating INWX with:"
          echo "  IPv6: $IPV6"
          echo "  IPv4: $IPV4"

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
