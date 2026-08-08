# ByClaude — Proxy for WHMCS with SSL

A production-ready **SOCKS5 + HTTPS proxy with a valid SSL certificate** for WHMCS, built to
kill errors like:

```
cURL error 35: OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to <proxy>
```

It routes WHMCS payment-module traffic (e.g. CryptoExchangePay → `bsc-dataseed*.binance.org`)
from a restricted network, through an encrypted server‑to‑server tunnel, out to the internet —
while the endpoint WHMCS talks to stays local and carries a **real, auto‑renewing Let's
Encrypt certificate**.

> 📖 راهنمای کامل فارسی: [`docs/FA.md`](docs/FA.md)

## Architecture

```
 WHMCS ──HTTPS/SOCKS (local IP, valid SSL)──▶  ENTRY node ──TLS relay tunnel──▶  EXIT node ──▶ Internet
                                              (Iran, 109)   (gost, muxed)      (abroad, 83)
```

- **ENTRY** (Iran server): the SOCKS5 + HTTPS proxy WHMCS connects to. Local IP, valid cert.
  Its credentials/ports are what you enter in WHMCS. Forwards everything through the tunnel.
- **EXIT** (foreign server): the other end of the encrypted tunnel; reaches the real internet.
- Built on **[gost](https://github.com/go-gost/gost) v3** — one small Go binary, high
  throughput, connection multiplexing, TLS with valid certificates.

### Why gost (vs leproxy)

`leproxy` is a fine, simple Node.js TLS proxy, but for a *fast server‑to‑server tunnel* gost
wins: no Node runtime, lower memory, native muxed relay tunnel, and censorship‑resistant
transports (`tls`/`ws`/`wss`/CDN). This project uses gost for both nodes.

## What you need

- Two Debian/Ubuntu servers with root (one local “entry”, one foreign “exit”).
- Two DNS **A records** (one per server) — a valid SSL cert is issued per *hostname*, not per
  IP, which is why WHMCS must reach the proxy by name. See [`docs/FA.md`](docs/FA.md#۲).

## Install

### One-liner (recommended)

Run on **each** server as root — it clones the project and walks you through setup:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Digitalvps-Ir/ByClaude-ProxyForWhmcsWithSsl/claude/whmcs-proxy-ssl-setup-obed47/install.sh)
```

Do the **foreign (EXIT)** server first, then the **Iran (ENTRY)** server with the tunnel
credentials the exit step prints.

### Manual (flags)

**On the foreign (EXIT) server:**
```bash
sudo ./setup.sh --role exit --domain tunnel.example.com --email you@example.com
```
It prints the tunnel user/password — copy them.

**On the local (ENTRY) server:**
```bash
sudo ./setup.sh --role entry --domain proxy.example.com --email you@example.com \
  --exit-host tunnel.example.com --tunnel-user <U> --tunnel-pass <P>
```
It prints the exact **HTTPS/SOCKS endpoints, credentials, and a dashboard URL** to use in
WHMCS (also saved to `/root/whmcs-proxy-credentials.txt`).

### DNS on a CDN (ArvanCloud / Cloudflare)

Get the certificate via **DNS-01** (no port 80 needed, works even with the CDN enabled):

```bash
# Cloudflare
sudo ./setup.sh --role entry --domain proxy.example.com --cert-mode dns-cloudflare --cf-token <TOKEN> …
# ArvanCloud (arvancloud.ir)
sudo ./setup.sh --role entry --domain proxy.example.ir  --cert-mode dns-arvan --arvan-token <APIKEY> …
```

> ⚠️ A CDN cannot relay a forward-proxy or tunnel. Keep the **A record for the proxy and
> tunnel subdomains DNS-only (cloud OFF)** — the certificate still issues fine via DNS-01.

## Manage it

- **SSH console** — run `whmcsproxy` for an x-ui-style menu: users, ports, change the proxy
  or dashboard **subdomain (auto re-issues + applies SSL)**, tunnel config, benchmark, request
  logs, BBR tuning, services, uninstall. Non-interactive too:
  ```bash
  whmcsproxy status
  whmcsproxy useradd myuser --apply
  whmcsproxy benchmark          # tunnel latency / jitter / packet-loss / throughput
  whmcsproxy logtail --limit 40 # recent requests: source IP → destination
  ```
- **Web dashboard** (auto-installed): `https://<entry-domain>:9443` — users/passwords, ports,
  tunnel, **domain/SSL changes**, cert expiry, and a **📜 Logs** page (source IP → destination,
  auto-refresh). Optionally give it its **own subdomain**. Lock the port to your admin IP with
  `ufw`.

## Tunnel performance

Tuned for high throughput and low latency out of the box: **BBR** + `fq`, large socket
buffers, TCP Fast Open, MTU probing, plus gost **connection multiplexing** and **keepalive**
on the tunnel. Measure it with `whmcsproxy benchmark`. If the tunnel hop is disrupted, switch
transport with `whmcsproxy set-transport --transport wss --apply` (set the same on both nodes).

## SSL auto‑renew

`setup.sh` enables `certbot.timer` and installs a deploy hook that reloads the proxy after
each renewal — fully automatic. Verify with `certbot renew --dry-run`.

## Use in WHMCS

Type **HTTPS**, host = your entry subdomain, port `443`, with the proxy user/pass — or the URL
`https://user:pass@proxy.example.com:443`. Details, the error breakdown, and a PHP test in
[`docs/WHMCS.md`](docs/WHMCS.md).

```bash
# verify before touching WHMCS
php examples/whmcs-proxy-test.php https://whmcs:PASS@proxy.example.com:443
```

## Repository layout

| Path | Purpose |
|------|---------|
| `install.sh` | online bootstrap: clones from GitHub and runs setup |
| `setup.sh` | installer (`--role entry|exit`), certs, systemd, tuning |
| `whmcsproxy` | SSH management console (menu + subcommands) |
| `gostctl.py` | config/user/port/tunnel/log manager — single source of truth |
| `dashboard.py` | self‑contained HTTPS admin UI (with logs page) |
| `lib/common.sh` | shared: cert issuance, domain migration, tuning, benchmark |
| `lib/certbot-arvan-hook.sh` | ArvanCloud DNS-01 hook for Let's Encrypt |
| `uninstall.sh` | clean removal |
| `examples/` | `whmcs-proxy-test.php`, `test-proxy.sh` |
| `docs/` | `FA.md` (فارسی), `WHMCS.md`, `TROUBLESHOOTING.md` |

## Notes

- All proxy access is authenticated; the plain SOCKS/HTTP listeners are optional and the
  HTTP‑proxy path is TLS‑only by design.
- If the tunnel hop is disrupted, switch it to WebSocket/CDN transport — see
  [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md#tunnel-resilience).
