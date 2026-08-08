#!/usr/bin/env bash
#
# certbot-arvan-hook.sh — Let's Encrypt DNS-01 hook for ArvanCloud (arvancloud.ir).
#
# Lets certbot obtain/renew a certificate for a domain whose DNS is hosted on
# ArvanCloud, even when the record is served through the ArvanCloud CDN and
# port 80 is not reachable. It creates and then removes the
# `_acme-challenge` TXT record via the ArvanCloud API.
#
# Used by certbot like:
#   ARVAN_API_KEY=... certbot certonly --manual --preferred-challenges dns \
#     --manual-auth-hook   "/opt/whmcs-proxy/certbot-arvan-hook.sh auth" \
#     --manual-cleanup-hook "/opt/whmcs-proxy/certbot-arvan-hook.sh cleanup" \
#     -d proxy.example.ir
#
# Environment:
#   ARVAN_API_KEY   ArvanCloud API key (from the panel). Required.
#   ARVAN_ZONE      Registered zone if auto-detection is wrong (e.g. example.ir).
#   ARVAN_API_BASE  Override API base (default https://napi.arvancloud.ir/cdn/4.0).
#   ARVAN_PROP_WAIT Seconds to wait for DNS propagation after creating the record (default 30).
#
# certbot provides CERTBOT_DOMAIN and CERTBOT_VALIDATION in the environment.
set -uo pipefail

MODE="${1:-auth}"
API_BASE="${ARVAN_API_BASE:-https://napi.arvancloud.ir/cdn/4.0}"
PROP_WAIT="${ARVAN_PROP_WAIT:-30}"
KEY="${ARVAN_API_KEY:-}"
DOMAIN="${CERTBOT_DOMAIN:-}"
VALIDATION="${CERTBOT_VALIDATION:-}"

err(){ echo "arvan-hook: $*" >&2; }
[ -n "$KEY" ] || { err "ARVAN_API_KEY is not set"; exit 1; }
[ -n "$DOMAIN" ] || { err "CERTBOT_DOMAIN missing (run via certbot)"; exit 1; }

# Authorization header — accept a key with or without the 'Apikey ' prefix.
case "$KEY" in
  [Aa]pikey\ *) AUTH="$KEY" ;;
  *)            AUTH="Apikey $KEY" ;;
esac

# Work out the zone (registered domain) and the record name relative to it.
if [ -n "${ARVAN_ZONE:-}" ]; then
  ZONE="$ARVAN_ZONE"
else
  ZONE="$(echo "$DOMAIN" | awk -F. '{n=NF; if(n>=2) print $(n-1)"."$n; else print $0}')"
fi
if [ "$DOMAIN" = "$ZONE" ]; then
  RNAME="_acme-challenge"
else
  SUB="${DOMAIN%.$ZONE}"
  RNAME="_acme-challenge.$SUB"
fi

api(){ # method path [data]
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -fsS -X "$method" "$API_BASE$path" \
      -H "Authorization: $AUTH" -H "Content-Type: application/json" \
      -H "Accept: application/json" --data "$data"
  else
    curl -fsS -X "$method" "$API_BASE$path" \
      -H "Authorization: $AUTH" -H "Accept: application/json"
  fi
}

case "$MODE" in
  auth)
    err "creating TXT $RNAME in zone $ZONE"
    body="$(printf '{"type":"txt","name":"%s","value":{"text":"%s"},"ttl":120,"cloud":false}' "$RNAME" "$VALIDATION")"
    if ! api POST "/domains/$ZONE/dns-records" "$body" >/dev/null; then
      err "failed to create TXT record (check ARVAN_API_KEY / ARVAN_ZONE=$ZONE)"; exit 1
    fi
    err "waiting ${PROP_WAIT}s for DNS propagation…"
    sleep "$PROP_WAIT"
    ;;
  cleanup)
    err "removing TXT $RNAME from zone $ZONE"
    # find matching record ids and delete them (JSON via env var, not stdin)
    records="$(api GET "/domains/$ZONE/dns-records?search=_acme-challenge" || true)"
    ids="$(WP_RECORDS="$records" WP_RNAME="$RNAME" WP_VAL="$VALIDATION" python3 -c '
import json, os
name = os.environ["WP_RNAME"]; val = os.environ["WP_VAL"]
try:
    data = json.loads(os.environ.get("WP_RECORDS") or "{}")
except Exception:
    raise SystemExit(0)
for r in (data.get("data") or data.get("records") or []):
    rn = (r.get("name") or "").rstrip(".")
    v = r.get("value") or {}
    text = v.get("text") if isinstance(v, dict) else v
    if rn == name and (val == "" or text == val):
        print(r.get("id") or r.get("uuid") or "")
' 2>/dev/null || true)"
    for id in $ids; do
      [ -n "$id" ] && api DELETE "/domains/$ZONE/dns-records/$id" >/dev/null && err "deleted $id"
    done
    ;;
  *) err "unknown mode: $MODE (use auth|cleanup)"; exit 1 ;;
esac
exit 0
