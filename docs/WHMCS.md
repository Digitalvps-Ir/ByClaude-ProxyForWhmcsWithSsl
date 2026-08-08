# WHMCS integration & the `cURL error 35` explained

## What the error actually means

```
CryptoExchangePay: Unable to update balance for USDT-BEP20:
Unable to reach BSC RPC: cURL error 35: OpenSSL SSL_connect:
SSL_ERROR_SYSCALL in connection to 185.118.15.125:2096
```

- **cURL error 35** = failure *during the TLS handshake* with the proxy.
- **`SSL_ERROR_SYSCALL`** = the socket was torn down (RST/FIN) mid‑handshake — the
  other side spoke no valid TLS, or reset the connection.
- **`185.118.15.125:2096`** is the *proxy* WHMCS was told to use, not Binance. So the
  module never even reached Binance — it failed talking to a broken proxy endpoint.

That address is an **Iranian IP**, and TLS to it fails even domestically, which means the
old proxy simply wasn't serving a valid TLS certificate on that port. The fix is a proxy
endpoint that (a) speaks proper TLS and (b) presents a **valid, trusted certificate** — which
is exactly what the ENTRY node in this project does (Let's Encrypt on an Iran subdomain).

## Settings to put in WHMCS / the module

| Field         | Value                                   |
|---------------|-----------------------------------------|
| Proxy type    | **HTTPS** (`CURLPROXY_HTTPS`)           |
| Proxy host    | `proxy.digitalvps.ir` (your ENTRY sub)  |
| Proxy port    | `443`                                   |
| Username      | your proxy user (e.g. `whmcs`)          |
| Password      | your proxy password                     |

Single-URL form some modules accept:
```
https://whmcs:PASSWORD@proxy.digitalvps.ir:443
```

If a module only supports SOCKS:
```
socks5h://whmcs:PASSWORD@proxy.digitalvps.ir:1080
```
(`socks5h` = resolve DNS on the proxy side — important so lookups also go abroad.)

## Setting it globally for all of WHMCS (optional)

WHMCS supports a system-wide cURL proxy in `configuration.php`:
```php
$curloptions = [
    CURLOPT_PROXY     => 'proxy.digitalvps.ir:443',
    CURLOPT_PROXYTYPE => CURLPROXY_HTTPS,
    CURLOPT_PROXYUSERPWD => 'whmcs:PASSWORD',
];
```
Prefer configuring the specific payment module instead, so only the calls that need to go
abroad use the proxy.

## libcurl requirement

`CURLPROXY_HTTPS` (a TLS connection *to the proxy*) needs **libcurl ≥ 7.52** (2016).
Any modern PHP 7.4/8.x host has this. Check with:
```bash
php -r 'echo curl_version()["version"], " / ", curl_version()["ssl_version"], "\n";'
```
If it is older, use the **SOCKS5** endpoint (`socks5h://…:1080`) instead — it does not
require HTTPS-proxy support.

## Verifying end-to-end

```bash
php examples/whmcs-proxy-test.php https://whmcs:PASSWORD@proxy.digitalvps.ir:443
```
A healthy result prints an `eth_blockNumber` JSON response from Binance Smart Chain, proving
the SSL error is gone and traffic reaches BSC through the tunnel.
