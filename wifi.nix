{
  services.hostapd = {
    enable = true;
    radios.wlp2s0.networks.wlp2s0 = {
      ssid = "My New Test Network";
      channel = 6;
      authentication = {
        mode = "none";
#        saePasswords = [ { passwordFile = "/run/secrets/wifi"; } ];
#        enableRecommendedPairwiseCiphers = true;
      };
    };
  };
}