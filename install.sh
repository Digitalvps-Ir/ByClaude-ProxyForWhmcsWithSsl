#!/usr/bin/env bash
#
# install.sh — online bootstrap for the WHMCS SSL proxy stack.
#
# PUBLIC repo — one-liner (run on each server, as root):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Digitalvps-Ir/ByClaude-ProxyForWhmcsWithSsl/claude/whmcs-proxy-ssl-setup-obed47/install.sh)
#
# PRIVATE repo — clone with a read-only token, then run locally (no re-clone):
#
#   git clone -b claude/whmcs-proxy-ssl-setup-obed47 \
#     https://<TOKEN>@github.com/Digitalvps-Ir/ByClaude-ProxyForWhmcsWithSsl.git
#   cd ByClaude-ProxyForWhmcsWithSsl && sudo ./install.sh
#
# You can also pass setup.sh flags straight through for a non-interactive run:
#   sudo ./install.sh --role exit --domain tunnel.example.com --email you@x.com
#
# When it does need to fetch, a token can be supplied via WP_TOKEN / GITHUB_TOKEN.
set -euo pipefail

REPO_URL="${WP_REPO_URL:-https://github.com/Digitalvps-Ir/ByClaude-ProxyForWhmcsWithSsl.git}"
BRANCH="${WP_BRANCH:-claude/whmcs-proxy-ssl-setup-obed47}"
DEST="${WP_DEST:-/opt/whmcs-proxy-src}"
TOKEN="${WP_TOKEN:-${GITHUB_TOKEN:-}}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
yel(){ printf '\033[33m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
info(){ printf '\033[36m›\033[0m %s\n' "$*"; }
die(){ red "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" = "0" ] || die "run as root (sudo)"
have apt-get || die "this installer targets Debian/Ubuntu (apt)"

banner(){
cat <<'B'
  ┌───────────────────────────────────────────────┐
  │   WHMCS SSL Proxy  ·  online installer         │
  │   SOCKS5 + HTTPS  ·  tunnel  ·  dashboard       │
  └───────────────────────────────────────────────┘
B
}
banner

# ------------------------------------------------------------------ deps
info "Installing prerequisites (git, curl)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates >/dev/null
grn "✓ prerequisites ready"

# ------------------------------------------------------------------ fetch project
SLUG="$(echo "$REPO_URL" | sed -E 's#https?://github.com/##; s#\.git$##')"

# Download the project file-by-file from raw.githubusercontent.com. This is the
# most reliable path from restricted networks (Iran): git-over-HTTPS to
# github.com is often throttled, while the raw CDN stays reachable.
fetch_raw(){
  local base="https://raw.githubusercontent.com/$SLUG/$BRANCH"
  local hdr=(); [ -n "$TOKEN" ] && hdr=(-H "Authorization: Bearer $TOKEN")
  local files=(
    setup.sh install.sh uninstall.sh whmcsproxy gostctl.py dashboard.py
    lib/common.sh lib/certbot-arvan-hook.sh
    examples/test-proxy.sh examples/whmcs-proxy-test.php
    README.md docs/FA.md docs/WHMCS.md docs/TROUBLESHOOTING.md
  )
  rm -rf "$DEST"; mkdir -p "$DEST/lib" "$DEST/examples" "$DEST/docs"
  local f
  for f in "${files[@]}"; do
    if ! curl -fsSL --connect-timeout 20 --retry 3 "${hdr[@]}" "$base/$f" -o "$DEST/$f"; then
      red "failed to download $f from raw"; return 1
    fi
  done
  return 0
}

fetch_git(){
  local clone_url="$REPO_URL"
  [ -n "$TOKEN" ] && clone_url="https://${TOKEN}@github.com/${SLUG}.git"
  rm -rf "$DEST"
  local i
  for i in 1 2; do
    info "Cloning $SLUG ($BRANCH) → $DEST  [try $i, 30s timeout]"
    if timeout 30 git clone --depth 1 --branch "$BRANCH" "$clone_url" "$DEST" 2>/tmp/wp-clone.err; then return 0; fi
    grep -qiE '403|denied|authentication|not found|could not read' /tmp/wp-clone.err 2>/dev/null && return 1
  done
  return 1
}

fetch_project(){
  if [ -d "$DEST/.git" ]; then
    info "Updating existing checkout in $DEST…"
    if timeout 30 git -C "$DEST" fetch --depth 1 origin "$BRANCH" \
        && git -C "$DEST" checkout -f "$BRANCH" \
        && git -C "$DEST" reset --hard "origin/$BRANCH"; then return 0; fi
  fi
  # Prefer raw on restricted networks; set WP_PREFER_GIT=1 to try git first.
  if [ "${WP_NO_GIT:-0}" = "1" ]; then
    info "Downloading project files from raw…"; fetch_raw && return 0
  elif [ "${WP_PREFER_GIT:-0}" = "1" ]; then
    fetch_git && return 0
    yel "git failed/slow; downloading files from raw…"; fetch_raw && return 0
  else
    info "Downloading project files from raw (github CDN)…"
    fetch_raw && return 0
    yel "raw download failed; trying git clone…"; fetch_git && return 0
  fi
  red "Could not fetch the project (raw and git both failed)."
  red "If the repo is PRIVATE, pass a token:  WP_TOKEN=<token> bash <(curl -fsSL …/install.sh)"
  exit 1
}

# If we are already inside a checkout (e.g. cloned manually), use it as-is.
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/setup.sh" ]; then
  DEST="$SELF_DIR"
  info "Using local checkout: $DEST"
else
  fetch_project
  grn "✓ project fetched"
fi

cd "$DEST"
chmod +x setup.sh whmcsproxy uninstall.sh gostctl.py dashboard.py install.sh 2>/dev/null || true

# ------------------------------------------------------------------ run installer
if [ $# -gt 0 ]; then
  info "Running: ./setup.sh $*"
  exec ./setup.sh "$@"
fi

# no args: interactive if we have a terminal, else show usage
if [ ! -t 0 ]; then
  cat <<EOF

Project is in: $DEST
Run the installer with your own subdomain, for example:

  # foreign (exit) server:
  $DEST/setup.sh --role exit  --domain tunnel.YOURDOMAIN --email you@mail.com

  # Iran (entry) server:
  $DEST/setup.sh --role entry --domain proxy.YOURDOMAIN  --email you@mail.com \\
     --exit-host tunnel.YOURDOMAIN --tunnel-user <U> --tunnel-pass <P>

EOF
  exit 0
fi

echo
ask(){ local p="$1" d="${2:-}" v; read -rp "$p${d:+ [$d]}: " v; echo "${v:-$d}"; }

echo "Which node is THIS server?"
echo "  1) EXIT  — foreign server (abroad), the tunnel endpoint"
echo "  2) ENTRY — Iran server, the proxy WHMCS connects to"
ROLE_CHOICE="$(ask 'choose 1 or 2' '2')"
if [ "$ROLE_CHOICE" = "1" ]; then ROLE="exit"; else ROLE="entry"; fi

DOMAIN="$(ask "Subdomain for THIS server (A record must point here, e.g. ${ROLE}.yourdomain.com)")"
[ -n "$DOMAIN" ] || die "a subdomain is required"
EMAIL="$(ask "Email for Let's Encrypt (optional)")"

ARGS=(--role "$ROLE" --domain "$DOMAIN")
[ -n "$EMAIL" ] && ARGS+=(--email "$EMAIL")

echo "How should the SSL certificate be issued?"
echo "  • standalone     — quick, needs TCP/80 free & DNS pointing here (CDN OFF)"
echo "  • dns-cloudflare — DNS on Cloudflare (works even with the CDN on)"
echo "  • dns-arvan      — DNS on ArvanCloud / arvancloud.ir (works even with the CDN on)"
CERT_MODE="$(ask 'Cert mode' 'standalone')"
ARGS+=(--cert-mode "$CERT_MODE")
if [ "$CERT_MODE" = "dns-cloudflare" ]; then
  CF="$(ask 'Cloudflare API token (Zone:DNS:Edit)')"
  [ -n "$CF" ] && ARGS+=(--cf-token "$CF")
elif [ "$CERT_MODE" = "dns-arvan" ]; then
  yel "Reminder: set the proxy/tunnel A record to DNS-only (cloud OFF) in ArvanCloud."
  AK="$(ask 'ArvanCloud API key')"
  [ -n "$AK" ] && ARGS+=(--arvan-token "$AK")
fi

if [ "$ROLE" = "entry" ]; then
  echo; yel "Tunnel to the foreign EXIT server (use the values printed by the exit install):"
  EXIT_HOST="$(ask 'Exit host (foreign subdomain)')"
  EXIT_PORT="$(ask 'Exit tunnel port' '8443')"
  TUSER="$(ask 'Tunnel user')"
  TPASS="$(ask 'Tunnel password')"
  [ -n "$EXIT_HOST" ] && ARGS+=(--exit-host "$EXIT_HOST")
  [ -n "$EXIT_PORT" ] && ARGS+=(--exit-port "$EXIT_PORT")
  [ -n "$TUSER" ] && ARGS+=(--tunnel-user "$TUSER")
  [ -n "$TPASS" ] && ARGS+=(--tunnel-pass "$TPASS")
  DASHD="$(ask 'Separate subdomain for the dashboard (optional, Enter to skip)')"
  [ -n "$DASHD" ] && ARGS+=(--dashboard-domain "$DASHD")
fi

echo
info "Running: ./setup.sh ${ARGS[*]}"
exec ./setup.sh "${ARGS[@]}"
