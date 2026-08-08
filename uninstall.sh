#!/usr/bin/env bash
# Remove the WHMCS SSL proxy stack (keeps Let's Encrypt certs unless --purge-certs).
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "run as root"; exit 1; }

PURGE_CERTS=0
DOMAIN=""
for a in "$@"; do
  case "$a" in
    --purge-certs) PURGE_CERTS=1;;
    --domain=*) DOMAIN="${a#*=}";;
  esac
done

echo "Stopping services…"
systemctl disable --now gost 2>/dev/null || true
systemctl disable --now whmcs-proxy-dashboard 2>/dev/null || true
rm -f /etc/systemd/system/gost.service /etc/systemd/system/whmcs-proxy-dashboard.service
systemctl daemon-reload || true

echo "Removing files…"
rm -rf /opt/whmcs-proxy
rm -f /usr/local/bin/whmcs-proxy /usr/local/bin/gost
rm -f /etc/letsencrypt/renewal-hooks/deploy/10-reload-whmcs-proxy.sh
rm -rf /etc/gost

if [ "$PURGE_CERTS" = "1" ] && [ -n "$DOMAIN" ]; then
  echo "Deleting certificate for $DOMAIN…"
  certbot delete --cert-name "$DOMAIN" -n 2>/dev/null || true
fi

echo "Done. (gost, config, dashboard removed. Certificates kept unless --purge-certs --domain=<d>.)"
