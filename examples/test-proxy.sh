#!/usr/bin/env bash
# Quick verification of the proxy chain from any client (e.g. the WHMCS/Iran box).
# Usage: ./test-proxy.sh proxy.example.ir 443 whmcs 'PASSWORD'
set -euo pipefail
HOST="${1:?host}"; PORT="${2:-443}"; USER="${3:?user}"; PASS="${4:?pass}"
TARGET="${5:-https://bsc-dataseed4.binance.org/}"

echo "== HTTPS proxy (valid SSL) =="
curl -sS --max-time 25 -o /dev/null -w "  HTTP %{http_code}  (proxy tls: %{ssl_verify_result})\n" \
  -x "https://${USER}:${PASS}@${HOST}:${PORT}" "$TARGET" \
  && echo "  ✅ HTTPS proxy OK" || echo "  ❌ HTTPS proxy failed"

echo "== SOCKS5 proxy =="
curl -sS --max-time 25 -o /dev/null -w "  HTTP %{http_code}\n" \
  -x "socks5h://${USER}:${PASS}@${HOST}:1080" "$TARGET" \
  && echo "  ✅ SOCKS5 OK" || echo "  ⚠️  SOCKS5 failed (or disabled)"

echo "== Show the exit IP the world sees (should be the FOREIGN server) =="
curl -sS --max-time 25 -x "https://${USER}:${PASS}@${HOST}:${PORT}" https://api.ipify.org && echo
