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
fetch_project(){
  # build a clone URL, injecting the token for private repos
  local clone_url="$REPO_URL" slug tar
  slug="$(echo "$REPO_URL" | sed -E 's#https?://github.com/##; s#\.git$##')"
  if [ -n "$TOKEN" ]; then
    clone_url="https://${TOKEN}@github.com/${slug}.git"
  fi

  if [ -d "$DEST/.git" ]; then
    info "Updating existing checkout in $DEST…"
    git -C "$DEST" fetch --depth 1 origin "$BRANCH" && git -C "$DEST" checkout -f "$BRANCH" \
      && git -C "$DEST" reset --hard "origin/$BRANCH" && return 0
  fi
  rm -rf "$DEST"
  local i
  for i in 1 2 3 4; do
    info "Cloning $slug ($BRANCH) → $DEST  [try $i]"
    if git clone --depth 1 --branch "$BRANCH" "$clone_url" "$DEST" 2>/tmp/wp-clone.err; then return 0; fi
    grep -qiE '403|denied|authentication|not found|could not read' /tmp/wp-clone.err 2>/dev/null && break
    sleep $((i*2)) || true
  done
  # fallback: tarball via codeload (works when git protocol is throttled)
  yel "git clone failed; trying tarball…"
  tar="https://codeload.github.com/$slug/tar.gz/refs/heads/$BRANCH"
  mkdir -p "$DEST"
  local auth=()
  [ -n "$TOKEN" ] && auth=(-H "Authorization: Bearer $TOKEN")
  if ! curl -fSL "${auth[@]}" "$tar" | tar -xz -C "$DEST" --strip-components=1; then
    red "Could not fetch the project."
    red "If the repository is PRIVATE, raw/clone return 404/403 without credentials."
    red "  • simplest: make the repo public (it contains no secrets), then re-run the one-liner, OR"
    red "  • clone with a read-only token and run locally:"
    red "      git clone -b $BRANCH https://<TOKEN>@github.com/$slug.git"
    red "      cd $(basename "$slug") && sudo ./install.sh"
    exit 1
  fi
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
