{
  services.hostapd = {
    enable = true;
    radios.wlp2s0.channel = 6;
    radios.wlp2s0.networks.wlp2s0 = {
      ssid = "My New Test Network";
      authentication = {
        mode = "wpa2-sha256";
        wpaPasswordFile = "/run/secrets/wifi";
        enableRecommendedPairwiseCiphers = true;
      };
    };
  };
}