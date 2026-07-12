{ pkgs, ... }:

let
  environmentFile = "/var/lib/searx/searx.env";
in
{
  # Local-only metasearch backend for Hermes. SearXNG is deliberately bound to
  # loopback and no firewall port is opened; only services on this host can use
  # its JSON search endpoint.
  services.searx = {
    enable = true;
    openFirewall = false;
    environmentFile = environmentFile;

    settings = {
      general.instance_name = "Hermes SearXNG";

      search = {
        # Hermes consumes the JSON API. Keeping HTML disabled avoids exposing a
        # user-facing search frontend that this host does not need.
        formats = [ "json" ];
      };

      server = {
        bind_address = "127.0.0.1";
        port = 8888;
        secret_key = "$SEARX_SECRET_KEY";
        limiter = false;
      };
    };
  };

  # Generate SearXNG's mandatory application secret on the server at first
  # start. The value never enters Git or the world-readable Nix store and is
  # preserved across rebuilds.
  systemd.services.searx-secret = {
    description = "Provision the local SearXNG secret";
    requiredBy = [ "searx-init.service" ];
    before = [ "searx-init.service" ];

    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0750 -o searx -g searx /var/lib/searx

      if ! test -s ${environmentFile}; then
        umask 077
        secret="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        printf 'SEARX_SECRET_KEY=%s\n' "$secret" > ${environmentFile}.tmp
        ${pkgs.coreutils}/bin/chown searx:searx ${environmentFile}.tmp
        ${pkgs.coreutils}/bin/mv ${environmentFile}.tmp ${environmentFile}
      fi
    '';
  };
}
