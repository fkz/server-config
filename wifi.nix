{
  services.hostapd = {
    enable = true;
    radios.wlp2s0.networks.ourwifi = {
      ssid = "My New Test Network";
      authentication = {
        mode = "wpa3-sae";
        saePasswords = [ { passwordFile = "/run/secrets/wifi"; } ];
        enableRecommendedPairwiseCiphers = true;
      };
    };
  };
}