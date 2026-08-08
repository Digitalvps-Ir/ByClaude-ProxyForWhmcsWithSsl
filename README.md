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

Copy this repo to both servers, then:

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

## Manage it

- **Web dashboard** (auto‑installed): `https://<entry-domain>:9443` — add/remove proxy users,
  reset passwords, change ports, edit the tunnel, see cert expiry, one‑click apply. Lock the
  port to your admin IP with `ufw`.
- **CLI:**
  ```bash
  whmcs-proxy status
  whmcs-proxy useradd myuser --apply
  whmcs-proxy passwd whmcs --apply
  whmcs-proxy set-port https 8443 --apply
  ```

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
| `setup.sh` | one‑command installer (`--role entry|exit`) |
| `gostctl.py` | config/user/port manager — single source of truth |
| `dashboard.py` | self‑contained HTTPS admin UI |
| `uninstall.sh` | clean removal |
| `examples/` | `whmcs-proxy-test.php`, `test-proxy.sh` |
| `docs/` | `FA.md` (فارسی), `WHMCS.md`, `TROUBLESHOOTING.md` |

## Notes

- All proxy access is authenticated; the plain SOCKS/HTTP listeners are optional and the
  HTTP‑proxy path is TLS‑only by design.
- If the tunnel hop is disrupted, switch it to WebSocket/CDN transport — see
  [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md#tunnel-resilience).
