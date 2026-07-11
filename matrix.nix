{ config, ... }:

let
  matrixHost = "home.taila70923.ts.net";
  synapsePort = 8008;
in
{
  # Synapse defaults to PostgreSQL. Provision its local database and role
  # declaratively; without this service Synapse cannot complete startup.
  services.postgresql = {
    enable = true;

    # Synapse requires its database to use C collation and C ctype. UTF-8 is
    # required independently for Matrix data. These apply when the PostgreSQL
    # cluster is initialized.
    initdbArgs = [ "--locale=C" "--encoding=UTF8" ];

    ensureDatabases = [ "matrix-synapse" ];
    ensureUsers = [
      {
        name = "matrix-synapse";
        ensureDBOwnership = true;
      }
    ];
  };

  # Private Matrix homeserver: Synapse is never bound to a public interface.
  # Tailscale Serve terminates TLS on the tailnet address and proxies to this
  # loopback-only listener. No public firewall port or Matrix federation is
  # configured.
  services.matrix-synapse = {
    enable = true;

    settings = {
      server_name = matrixHost;
      public_baseurl = "https://${matrixHost}/";
      report_stats = false;

      # Accounts are created explicitly with register_new_matrix_user; public
      # self-registration is intentionally disabled.
      enable_registration = false;
      registration_shared_secret_path = "/var/lib/matrix-synapse/registration-shared-secret";

      # This is a local-only homeserver. Omitting the federation listener also
      # prevents inbound federation; the whitelist blocks outbound federation.
      federation_domain_whitelist = [ ];
      trusted_key_servers = [ ];
      url_preview_enabled = false;

      listeners = [
        {
          port = synapsePort;
          bind_addresses = [ "127.0.0.1" ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {
              names = [ "client" "media" ];
              compress = true;
            }
          ];
        }
      ];
    };
  };

  # Persist the private Tailnet HTTPS proxy declaratively. This requires
  # HTTPS certificates to be enabled in the Tailscale admin console first.
  # It terminates TLS before forwarding exclusively to Synapse on loopback.
  systemd.services.matrix-tailnet-proxy = {
    description = "Tailscale HTTPS proxy for the private Matrix homeserver";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" "matrix-synapse.service" ];
    after = [ "tailscaled.service" "matrix-synapse.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --https=443 http://127.0.0.1:${toString synapsePort}";
      ExecStop = "${config.services.tailscale.package}/bin/tailscale serve --https=443 off";
    };
  };

  # This file is deliberately created empty and outside Git/Nix store. Before
  # registering the first Matrix account, write a high-entropy secret to it:
  #   umask 077; head -c 32 /dev/urandom | base64 > /var/lib/matrix-synapse/registration-shared-secret
  # then run: systemctl restart matrix-synapse
  systemd.tmpfiles.rules = [
    "f /var/lib/matrix-synapse/registration-shared-secret 0600 matrix-synapse matrix-synapse -"
  ];
}
