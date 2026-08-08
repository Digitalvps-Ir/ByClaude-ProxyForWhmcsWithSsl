#!/usr/bin/env bash
#
# setup.sh — one-command installer for the WHMCS SSL proxy stack.
#
#   Architecture:
#     WHMCS ──HTTPS/SOCKS (valid SSL, Iran IP)──▶ ENTRY node (Iran)
#                                                    │  encrypted TLS relay tunnel
#                                                    ▼
#                                                 EXIT node (abroad) ──▶ Internet / Binance
#
#   Run on the FOREIGN server first:
#     sudo ./setup.sh --role exit  --domain tunnel.example.ir --email you@mail.com
#
#   Then on the IRAN server (use the tunnel user/pass printed by the exit step):
#     sudo ./setup.sh --role entry --domain proxy.example.ir  --email you@mail.com \
#          --exit-host tunnel.example.ir --tunnel-user <U> --tunnel-pass <P>
#
# Idempotent: safe to re-run. Requires Ubuntu/Debian (apt) and root.
set -euo pipefail

# ------------------------------------------------------------------ defaults
ROLE=""
DOMAIN=""
EMAIL=""
CERT_MODE="standalone"          # standalone | webroot | dns-cloudflare | existing
WEBROOT="/var/www/html"
CF_TOKEN=""                     # for dns-cloudflare (file path or literal token)
CERT_FILE=""; KEY_FILE=""       # for --cert-mode existing

HTTPS_PORT=443
SOCKS_PORT=1080
HTTP_PORT=8080                  # plain proxy (0 to disable)
TUNNEL_PORT=8443
DASH_PORT=9443

PROXY_USER=""; PROXY_PASS=""    # entry: what WHMCS uses (auto if empty)
TUNNEL_USER=""; TUNNEL_PASS=""  # shared secret between entry and exit
EXIT_HOST=""; EXIT_PORT=8443    # entry: where the tunnel goes
TUNNEL_INSECURE=0               # entry: skip verifying exit cert (not recommended)

ADMIN_USER="admin"; ADMIN_PASS=""
GOST_VERSION="3.0.0"
GOST_URL=""
OPEN_FIREWALL=1
NO_DASHBOARD=0

INSTALL_DIR="/opt/whmcs-proxy"
STATE_DIR="/etc/gost"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------ helpers
c_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_yel(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
info(){ printf '\033[36m›\033[0m %s\n' "$*"; }
die(){ c_red "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
rand(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-18}"; }

usage(){ sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ------------------------------------------------------------------ args
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --cert-mode) CERT_MODE="$2"; shift 2;;
    --webroot) WEBROOT="$2"; shift 2;;
    --cf-token) CF_TOKEN="$2"; shift 2;;
    --cert-file) CERT_FILE="$2"; shift 2;;
    --key-file) KEY_FILE="$2"; shift 2;;
    --https-port) HTTPS_PORT="$2"; shift 2;;
    --socks-port) SOCKS_PORT="$2"; shift 2;;
    --http-port) HTTP_PORT="$2"; shift 2;;
    --tunnel-port) TUNNEL_PORT="$2"; shift 2;;
    --dashboard-port) DASH_PORT="$2"; shift 2;;
    --proxy-user) PROXY_USER="$2"; shift 2;;
    --proxy-pass) PROXY_PASS="$2"; shift 2;;
    --tunnel-user) TUNNEL_USER="$2"; shift 2;;
    --tunnel-pass) TUNNEL_PASS="$2"; shift 2;;
    --exit-host) EXIT_HOST="$2"; shift 2;;
    --exit-port) EXIT_PORT="$2"; shift 2;;
    --tunnel-insecure) TUNNEL_INSECURE=1; shift;;
    --admin-user) ADMIN_USER="$2"; shift 2;;
    --admin-pass) ADMIN_PASS="$2"; shift 2;;
    --gost-version) GOST_VERSION="$2"; shift 2;;
    --gost-url) GOST_URL="$2"; shift 2;;
    --no-firewall) OPEN_FIREWALL=0; shift;;
    --no-dashboard) NO_DASHBOARD=1; shift;;
    -h|--help) usage;;
    *) die "unknown option: $1 (use --help)";;
  esac
done

[ "$(id -u)" = "0" ] || die "run as root (sudo)"
[ "$ROLE" = "entry" ] || [ "$ROLE" = "exit" ] || die "--role must be 'entry' or 'exit'"
[ -n "$DOMAIN" ] || die "--domain is required (the FQDN that points to THIS server)"
have apt-get || die "this installer targets Debian/Ubuntu (apt)"

if [ "$ROLE" = "entry" ]; then
  [ -n "$EXIT_HOST" ] || die "entry role needs --exit-host (the foreign server FQDN)"
  [ -n "$TUNNEL_USER" ] && [ -n "$TUNNEL_PASS" ] || \
    die "entry role needs --tunnel-user/--tunnel-pass (the values printed by the exit install)"
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
  amd64|x86_64) GARCH="amd64";;
  arm64|aarch64) GARCH="arm64";;
  armhf|armv7l) GARCH="armv7";;
  *) GARCH="amd64"; c_yel "unknown arch $ARCH, defaulting to amd64";;
esac

# ------------------------------------------------------------------ 1. packages
info "Updating apt and installing dependencies…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
PKGS="curl ca-certificates openssl tar python3"
[ "$CERT_MODE" = "existing" ] || PKGS="$PKGS certbot"
[ "$CERT_MODE" = "dns-cloudflare" ] && PKGS="$PKGS python3-certbot-dns-cloudflare"
apt-get install -y -qq $PKGS >/dev/null
c_grn "✓ dependencies installed"

# ------------------------------------------------------------------ 2. gost binary
install_gost(){
  if have gost && gost -V 2>/dev/null | grep -q "gost v3"; then
    info "gost already installed: $(gost -V 2>&1 | head -1)"; return
  fi
  local url="$GOST_URL"
  [ -n "$url" ] || url="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${GARCH}.tar.gz"
  info "Downloading gost from $url"
  local tmp; tmp="$(mktemp -d)"
  local ok=0 i
  for i in 1 2 3 4; do
    if curl -fSL --connect-timeout 20 -o "$tmp/gost.tgz" "$url"; then ok=1; break; fi
    c_yel "download attempt $i failed, retrying…"; sleep $((i*2)) || true
  done
  [ "$ok" = "1" ] || die "could not download gost. On a filtered network, pass --gost-url with a reachable mirror, or copy the binary to /usr/local/bin/gost manually."
  tar -xzf "$tmp/gost.tgz" -C "$tmp"
  install -m 0755 "$tmp/gost" /usr/local/bin/gost
  rm -rf "$tmp"
  c_grn "✓ gost installed: $(gost -V 2>&1 | head -1)"
}
install_gost

# ------------------------------------------------------------------ 3. app files
info "Installing control tool and dashboard to $INSTALL_DIR…"
mkdir -p "$INSTALL_DIR" "$STATE_DIR"
for f in gostctl.py dashboard.py; do
  [ -f "$SRC_DIR/$f" ] || die "missing $SRC_DIR/$f (run setup.sh from inside the repo)"
  install -m 0755 "$SRC_DIR/$f" "$INSTALL_DIR/$f"
done
# convenience CLI
cat > /usr/local/bin/whmcs-proxy <<EOF
#!/usr/bin/env bash
exec python3 $INSTALL_DIR/gostctl.py "\$@"
EOF
chmod 0755 /usr/local/bin/whmcs-proxy
c_grn "✓ 'whmcs-proxy' CLI installed (try: whmcs-proxy status)"

# ------------------------------------------------------------------ 4. certificate
obtain_cert(){
  if [ "$CERT_MODE" = "existing" ]; then
    [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] || die "--cert-file/--key-file not found"
    c_grn "✓ using existing certificate"
    return
  fi
  local live="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  if [ -f "$live" ]; then
    info "certificate for $DOMAIN already present; skipping issuance"
  else
    local ca_args="--non-interactive --agree-tos"
    if [ -n "$EMAIL" ]; then ca_args="$ca_args -m $EMAIL"; else ca_args="$ca_args --register-unsafely-without-email"; fi
    case "$CERT_MODE" in
      standalone)
        info "Requesting Let's Encrypt cert (standalone, needs port 80 free & DNS ready)…"
        certbot certonly --standalone -d "$DOMAIN" $ca_args --preferred-challenges http \
          || die "certbot failed. Ensure $DOMAIN points to THIS server and TCP/80 is open, or use --cert-mode dns-cloudflare."
        ;;
      webroot)
        info "Requesting Let's Encrypt cert (webroot $WEBROOT)…"
        mkdir -p "$WEBROOT"
        certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" $ca_args \
          || die "certbot webroot failed."
        ;;
      dns-cloudflare)
        local cffile="$CF_TOKEN"
        if [ -n "$CF_TOKEN" ] && [ ! -f "$CF_TOKEN" ]; then
          cffile="/etc/letsencrypt/cloudflare.ini"
          printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$cffile"; chmod 600 "$cffile"
        fi
        [ -f "$cffile" ] || die "dns-cloudflare needs --cf-token (API token or ini file path)"
        info "Requesting Let's Encrypt cert (Cloudflare DNS-01)…"
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$cffile" -d "$DOMAIN" $ca_args \
          || die "certbot dns-cloudflare failed."
        ;;
      *) die "unknown --cert-mode: $CERT_MODE";;
    esac
    c_grn "✓ certificate issued for $DOMAIN"
  fi
}
obtain_cert

# ------------------------------------------------------------------ 5. state file
info "Writing state…"
[ -n "$ADMIN_PASS" ] || ADMIN_PASS="$(rand 16)"
INIT_ARGS=(--role "$ROLE" --domain "$DOMAIN" --force
           --https "$HTTPS_PORT" --socks "$SOCKS_PORT" --http "$HTTP_PORT"
           --tunnel "$TUNNEL_PORT" --dashboard "$DASH_PORT"
           --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASS")
if [ "$CERT_MODE" = "existing" ]; then
  INIT_ARGS+=(--cert-file "$CERT_FILE" --key-file "$KEY_FILE")
fi
if [ "$ROLE" = "entry" ]; then
  INIT_ARGS+=(--exit-host "$EXIT_HOST" --exit-port "$EXIT_PORT"
              --tunnel-user "$TUNNEL_USER" --tunnel-pass "$TUNNEL_PASS")
  [ "$TUNNEL_INSECURE" = "1" ] && INIT_ARGS+=(--tunnel-insecure)
fi
python3 "$INSTALL_DIR/gostctl.py" "${INIT_ARGS[@]}"

# users / shared secret
if [ "$ROLE" = "exit" ]; then
  [ -n "$TUNNEL_USER" ] || TUNNEL_USER="tunnel"
  [ -n "$TUNNEL_PASS" ] || TUNNEL_PASS="$(rand 24)"
  python3 "$INSTALL_DIR/gostctl.py" useradd "$TUNNEL_USER" --password "$TUNNEL_PASS" >/dev/null
else
  [ -n "$PROXY_USER" ] || PROXY_USER="whmcs"
  [ -n "$PROXY_PASS" ] || PROXY_PASS="$(rand 20)"
  python3 "$INSTALL_DIR/gostctl.py" useradd "$PROXY_USER" --password "$PROXY_PASS" >/dev/null
fi
python3 "$INSTALL_DIR/gostctl.py" render >/dev/null
c_grn "✓ configuration written to $STATE_DIR/config.json"

# ------------------------------------------------------------------ 6. systemd
info "Installing systemd services…"
cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=WHMCS SSL proxy (gost) - $ROLE node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C $STATE_DIR/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

if [ "$NO_DASHBOARD" = "0" ]; then
cat > /etc/systemd/system/whmcs-proxy-dashboard.service <<EOF
[Unit]
Description=WHMCS SSL proxy admin dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=GOST_STATE=$STATE_DIR/state.json
Environment=GOST_CONFIG=$STATE_DIR/config.json
ExecStart=/usr/bin/python3 $INSTALL_DIR/dashboard.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now gost >/dev/null 2>&1 || systemctl restart gost
if [ "$NO_DASHBOARD" = "0" ]; then
  systemctl enable --now whmcs-proxy-dashboard >/dev/null 2>&1 || systemctl restart whmcs-proxy-dashboard
fi
c_grn "✓ services started"

# ------------------------------------------------------------------ 7. auto-renew hook
info "Configuring automatic SSL renewal…"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/10-reload-whmcs-proxy.sh <<'EOF'
#!/usr/bin/env bash
# Reload proxy services after Let's Encrypt renews the certificate.
systemctl restart gost 2>/dev/null || true
systemctl restart whmcs-proxy-dashboard 2>/dev/null || true
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/10-reload-whmcs-proxy.sh
# certbot ships a systemd timer that renews twice daily; make sure it's on
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
c_grn "✓ auto-renewal active (certbot.timer + deploy hook reloads the proxy)"

# ------------------------------------------------------------------ 8. firewall
if [ "$OPEN_FIREWALL" = "1" ] && have ufw; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    info "Opening firewall ports (ufw)…"
    ufw allow 80/tcp >/dev/null 2>&1 || true
    if [ "$ROLE" = "exit" ]; then
      ufw allow "${TUNNEL_PORT}/tcp" >/dev/null 2>&1 || true
    else
      ufw allow "${HTTPS_PORT}/tcp" >/dev/null 2>&1 || true
      [ "$SOCKS_PORT" != "0" ] && ufw allow "${SOCKS_PORT}/tcp" >/dev/null 2>&1 || true
      [ "$HTTP_PORT"  != "0" ] && ufw allow "${HTTP_PORT}/tcp"  >/dev/null 2>&1 || true
    fi
    [ "$NO_DASHBOARD" = "0" ] && c_yel "  note: dashboard port ${DASH_PORT} left CLOSED in ufw — open it only to your admin IP:  ufw allow from <your-ip> to any port ${DASH_PORT} proto tcp"
    c_grn "✓ firewall rules applied"
  fi
fi

# ------------------------------------------------------------------ 9. summary
CREDFILE="/root/whmcs-proxy-credentials.txt"
{
  echo "WHMCS SSL Proxy — $ROLE node ($DOMAIN)"
  echo "generated: $(date -u) UTC"
  echo
  if [ "$ROLE" = "exit" ]; then
    echo "TUNNEL endpoint (give these to the ENTRY/Iran install):"
    echo "  --exit-host  $DOMAIN"
    echo "  --exit-port  $TUNNEL_PORT"
    echo "  --tunnel-user $TUNNEL_USER"
    echo "  --tunnel-pass $TUNNEL_PASS"
  else
    echo "PROXY endpoints for WHMCS (Iran IP, valid SSL):"
    echo "  HTTPS proxy : https://$DOMAIN:$HTTPS_PORT   (type=HTTPS)"
    echo "  SOCKS5      : socks5h://$DOMAIN:$SOCKS_PORT"
    [ "$HTTP_PORT" != "0" ] && echo "  HTTP proxy  : http://$DOMAIN:$HTTP_PORT"
    echo "  proxy user  : $PROXY_USER"
    echo "  proxy pass  : $PROXY_PASS"
    echo "  cURL proxy  : https://$PROXY_USER:$PROXY_PASS@$DOMAIN:$HTTPS_PORT"
  fi
  echo
  [ "$NO_DASHBOARD" = "0" ] && {
    echo "DASHBOARD: https://$DOMAIN:$DASH_PORT"
    echo "  admin user: $ADMIN_USER"
    echo "  admin pass: $ADMIN_PASS"
  }
} | tee "$CREDFILE"
chmod 600 "$CREDFILE"

echo
c_grn "════════════════════════════════════════════════════════════"
c_grn " Done. Summary saved to $CREDFILE (chmod 600)."
c_grn "════════════════════════════════════════════════════════════"
python3 "$INSTALL_DIR/gostctl.py" status || true
if [ "$ROLE" = "exit" ]; then
  echo
  c_yel "NEXT: run the ENTRY install on the Iran server with the tunnel values above."
else
  echo
  info "Verify from the Iran server:"
  echo "  curl -x https://$PROXY_USER:$PROXY_PASS@$DOMAIN:$HTTPS_PORT https://bsc-dataseed4.binance.org/ -I"
fi
