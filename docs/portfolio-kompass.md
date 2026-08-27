# Portfolio Kompass

Portfolio Kompass runs as an unprivileged NixOS systemd service and is only
available inside the Tailnet:

<http://home/portfolio/>

The application listens on `127.0.0.1:9320`. The existing nginx Tailnet vhost
proxies `/portfolio/` to it and only permits Tailscale source addresses. No
additional firewall port is opened.

## Persistent data

The SQLite database is stored outside the Nix store:

```text
/var/lib/portfolio-kompass/portfolio.db
```

Back up this file together with its `-wal` and `-shm` files, or use SQLite's
online backup command while the service is running.

## Market-data API

The first activation creates this root-only environment file and generates a
random `CRON_SECRET`:

```text
/var/lib/portfolio-kompass/portfolio-kompass.env
```

Add a Twelve Data API key on the server without changing the generated secret:

```bash
sudo sh -c 'printf "TWELVE_DATA_API_KEY=%s\n" "$1" >> /var/lib/portfolio-kompass/portfolio-kompass.env' sh 'YOUR_KEY'
sudo systemctl restart portfolio-kompass
```

Do not commit the key. `portfolio-kompass-sync.timer` imports daily EUR prices
at 20:30 server time. Without an API key, the timer exits successfully without
making a request.

## Operations

```bash
systemctl status portfolio-kompass
journalctl -u portfolio-kompass -f
systemctl start portfolio-kompass-sync
systemctl list-timers portfolio-kompass-sync.timer
```
