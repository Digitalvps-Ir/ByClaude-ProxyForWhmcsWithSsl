# Troubleshooting

## Quick health checks

```bash
whmcs-proxy status              # role, gost active?, cert expiry, endpoints
systemctl status gost
journalctl -u gost -n 50 --no-pager
whmcs-proxy show-config         # the exact gost config in use
```

## `certbot` failed to issue the certificate

- **Standalone mode** needs DNS already pointing to this server **and** TCP/80 free/open.
  - Confirm DNS: `dig +short proxy.digitalvps.ir` should return this server's IP.
  - Confirm port 80 is reachable from outside and not used by another web server.
- If port 80 can't be used, issue via DNS instead (works even behind Cloudflare):
  ```bash
  sudo ./setup.sh --role entry --domain proxy.digitalvps.ir \
    --cert-mode dns-cloudflare --cf-token <CF_API_TOKEN> \
    --exit-host tunnel.digitalvps.ir --tunnel-user U --tunnel-pass P
  ```
  The Cloudflare token needs `Zone:DNS:Edit` on the zone.
- Already have a cert? Use it directly:
  ```bash
  --cert-mode existing --cert-file /path/fullchain.pem --key-file /path/privkey.pem
  ```
- DNS on **ArvanCloud**? Use the built-in DNS-01 hook (works with the CDN on, no port 80):
  ```bash
  --cert-mode dns-arvan --arvan-token <ARVANCLOUD_API_KEY>
  # if the zone is misdetected, set it explicitly:
  ARVAN_ZONE=example.ir sudo ./setup.sh … --cert-mode dns-arvan --arvan-token <KEY>
  ```

## CDN (ArvanCloud / Cloudflare): proxy or tunnel “not connecting”

A CDN only relays normal website HTTP(S). It will **not** carry a forward-proxy `CONNECT`,
SOCKS, or the relay tunnel. Set the **A record for the proxy and tunnel subdomains to
DNS-only (cloud/proxy OFF)** so it points straight at the server. The Let's Encrypt cert
still issues fine through DNS-01 (`--cert-mode dns-cloudflare` / `dns-arvan`) regardless.

## WHMCS still shows `cURL error 35`

1. Make sure WHMCS connects by **hostname**, not IP (the cert is for the name).
2. Test the proxy directly from the WHMCS box:
   ```bash
   curl -x https://whmcs:PASS@proxy.digitalvps.ir:443 -I https://bsc-dataseed4.binance.org/
   ```
   - Works here but not in WHMCS → the module isn't using the proxy; re-check its settings.
   - Fails here too → check `journalctl -u gost -f` on the ENTRY node while running it.
3. `curl (35)` *to the proxy itself* means the ENTRY cert/port is wrong — verify:
   ```bash
   openssl s_client -connect proxy.digitalvps.ir:443 -servername proxy.digitalvps.ir </dev/null
   ```
   You should see the Let's Encrypt chain and `Verify return code: 0 (ok)`.

## The proxy authenticates but pages time out

That means the ENTRY→EXIT tunnel is down. On the ENTRY node:
```bash
journalctl -u gost -f     # look for dial/relay errors to the exit host
```
Check that the EXIT node's `gost` is running and its `--tunnel-port` (8443) is open in its
firewall, and that `--tunnel-user/--tunnel-pass` match on both sides.

## Tunnel resilience (if Iran ⇄ abroad gets disrupted)

Default transport is `relay+tls` (looks like normal HTTPS). If it gets throttled/blocked:

1. **WebSocket-over-TLS** (`relay+wss`) — blends in as web traffic and can pass through a
   CDN. On the EXIT node, change the tunnel listener to `wss`, and on the ENTRY node change
   the dialer to `wss` (edit `/etc/gost/config.json`, or ask for the `wss` template). Then
   optionally put the EXIT subdomain behind Cloudflare (orange cloud) so the Iran→edge hop is
   a normal Cloudflare HTTPS connection.
2. **Different port** — some ports are cleaner than others from Iran; try `443` for the
   tunnel too (set `--tunnel-port 443` on EXIT, and a separate IP/subdomain if 443 is taken).
3. **mux tuning** — gost relay multiplexes by default; keep-alives already help latency.

## Ports already in use

If `443` is taken on the ENTRY server (e.g. a web panel), pick another and set it in WHMCS:
```bash
whmcs-proxy set-port https 8443 --apply
```
Do the same for `--tunnel-port` on the EXIT server if needed.

## Reset everything

```bash
sudo ./uninstall.sh
# then re-run setup.sh
```
