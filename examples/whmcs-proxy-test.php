<?php
/**
 * whmcs-proxy-test.php
 *
 * Reproduces the exact type of request the WHMCS "CryptoExchangePay" module
 * makes (an HTTPS call to a BSC RPC endpoint) but routed through your proxy,
 * so you can confirm the SSL error is gone before touching WHMCS.
 *
 * Usage (on the WHMCS server, or any PHP host):
 *   php whmcs-proxy-test.php https://PROXYUSER:PROXYPASS@proxy.example.ir:443
 *
 * A successful run prints the JSON-RPC block number from Binance Smart Chain.
 */

$proxy = $argv[1] ?? '';
if (!$proxy) {
    fwrite(STDERR, "usage: php whmcs-proxy-test.php https://USER:PASS@HOST:PORT\n");
    exit(2);
}

// The kind of endpoint that was failing with "cURL error 35: OpenSSL ...".
$target  = 'https://bsc-dataseed4.binance.org/';
$payload = json_encode([
    'jsonrpc' => '2.0',
    'id'      => 1,
    'method'  => 'eth_blockNumber',
    'params'  => [],
]);

$ch = curl_init($target);
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_POST           => true,
    CURLOPT_POSTFIELDS     => $payload,
    CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
    CURLOPT_TIMEOUT        => 25,

    // ---- the proxy configuration you would set inside WHMCS ----
    CURLOPT_PROXY          => $proxy,          // https://user:pass@host:port
    CURLOPT_PROXYTYPE      => CURLPROXY_HTTPS,  // TLS to the proxy (valid cert)
    CURLOPT_HTTPPROXYTUNNEL => true,

    // keep full end-to-end certificate validation ON (this is the point):
    CURLOPT_SSL_VERIFYPEER => true,
    CURLOPT_SSL_VERIFYHOST => 2,
    CURLOPT_PROXY_SSL_VERIFYPEER => true,
    CURLOPT_PROXY_SSL_VERIFYHOST => 2,
]);

$body = curl_exec($ch);
$err  = curl_error($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

echo "libcurl: " . (curl_version()['version']) . " / " . curl_version()['ssl_version'] . "\n";
if ($body === false) {
    echo "❌ FAILED: $err\n";
    echo "   If you see 'OpenSSL SSL_connect' or error 35 here, the proxy TLS/cert is still wrong.\n";
    echo "   If libcurl is older than 7.52, CURLPROXY_HTTPS is unsupported — use the SOCKS5 endpoint instead.\n";
    exit(1);
}
echo "✅ HTTP $code via proxy\n";
echo "   response: " . trim($body) . "\n";
