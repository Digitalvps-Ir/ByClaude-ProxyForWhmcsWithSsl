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

ask(){ local p="$1" d="${2:-}" v=""; read -rp "$p${d:+ [$d]}: " v || true; echo "${v:-$d}"; }
gen(){ local n="${1:-24}" s; s="$(head -c "$((n*10+32))" /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"; printf '%s' "${s:0:n}"; }

# no terminal (piped) and no flags: print the manual commands and exit
if [ ! -t 0 ]; then
  cat <<EOF

Project is in: $DEST  — run one of:

  # 1) Iran server (panel + proxy):
  sudo $DEST/setup.sh --role entry --domain proxy.YOURDOMAIN --email you@mail.com \\
       --exit-host <FOREIGN_IP> --tunnel-user tunnel --tunnel-pass <SECRET> --tunnel-insecure

  # 2) foreign server (tunnel only):
  sudo $DEST/setup.sh --role exit --self-signed --tunnel-user tunnel --tunnel-pass <SECRET>

EOF
  exit 0
fi

# NOTE: every printed line starts with an ASCII character so the terminal keeps
# a left-to-right base direction — this stops Persian/English from scrambling
# over SSH. Prompts are English; Persian help is on its own '#'-prefixed lines.
echo
echo "=================================================================="
echo "  WHMCS SSL Proxy — installer"
echo "  #  نصب‌کننده‌ی پروکسی SSL برای WHMCS"
echo "=================================================================="
echo "  Which server is this?"
echo "  #  این سرور کدام است؟"
echo
echo "   1) Iran server   — dashboard + proxy   (install this FIRST)"
echo "   #  سرور ایران    — پنل و پروکسی         (اول این را نصب کنید)"
echo
echo "   2) Foreign server — tunnel only (no domain, no dashboard)"
echo "   #  سرور خارج      — فقط تانل (بدون دامنه و داشبورد)"
echo "=================================================================="
RC="$(ask 'choose 1 or 2' '1')"

# ============================ EXIT (foreign) =====================
if [ "$RC" = "2" ]; then
  echo
  echo "  Foreign node = tunnel only. Best: paste the ready command that the"
  echo "  Iran install printed, or enter the SAME tunnel user/pass used on Iran."
  echo "  #  سرور خارج فقط تانل است. بهتر است همان دستوری که سرور ایران چاپ کرد را بزنید،"
  echo "  #  یا همان یوزر/پسورد تانلی که روی ایران استفاده کردید را وارد کنید."
  TP="$(ask 'tunnel port' '8443')"
  TU="$(ask 'tunnel user' 'tunnel')"
  TPW="$(ask 'tunnel pass (blank = auto-generate)')"
  [ -n "$TPW" ] || { TPW="$(gen 24)"; echo "  generated tunnel pass: $TPW"; echo "  #  این پسورد باید روی ایران هم همین باشد."; }
  echo; info "Running foreign tunnel setup…"
  exec ./setup.sh --role exit --self-signed --tunnel-port "$TP" --tunnel-user "$TU" --tunnel-pass "$TPW"
fi

# ============================ ENTRY (Iran) =======================
echo
echo "  Iran node — the dashboard and the SOCKS/HTTPS proxy are installed here."
echo "  #  سرور ایران — پنل مدیریت و پروکسی اینجا نصب می‌شود."
echo
echo "  [1/4] Proxy subdomain — you enter THIS in WHMCS (never the IP)."
echo "  #  ساب‌دامین پروکسی — همین را در WHMCS وارد می‌کنید، نه IP."
echo "  #  رکورد A آن باید به IP همین سرور ایران اشاره کند."
echo "  #  اگر IP بگذارید خطای cURL 51 می‌گیرید (گواهی روی نام صادر می‌شود)."
DOMAIN="$(ask 'subdomain (e.g. proxy.yourdomain.com)')"
[ -n "$DOMAIN" ] || die "subdomain required"

echo
echo "  [2/4] Foreign server public IP (the tunnel connects there)."
echo "  #  IP سرور خارج که تانل به آن وصل می‌شود."
EXIP="$(ask 'foreign IP')"
[ -n "$EXIP" ] || die "foreign IP required"
TP="$(ask 'tunnel port' '8443')"

echo
echo "  [3/4] Email for Let's Encrypt (optional, press Enter to skip)."
echo "  #  ایمیل برای گواهی Let's Encrypt (اختیاری)."
EMAIL="$(ask 'email')"

echo
echo "  [4/4] Certificate method:"
echo "  #  روش صدور گواهی:"
echo "     standalone      - simple; needs port 80 open and the CDN OFF"
echo "     #  ساده — پورت ۸۰ باز و ابر/CDN خاموش"
echo "     dns-cloudflare  - domain on Cloudflare (works with the CDN ON)"
echo "     #  دامنه روی Cloudflare (با CDN روشن هم کار می‌کند)"
echo "     dns-arvan       - domain on ArvanCloud (works with the CDN ON)"
echo "     #  دامنه روی ArvanCloud (با CDN روشن هم کار می‌کند)"
CM="$(ask 'cert mode' 'standalone')"

# the Iran side mints the shared tunnel secret
TU="tunnel"; TPW="$(gen 24)"

ARGS=(--role entry --domain "$DOMAIN" --exit-host "$EXIP" --exit-port "$TP"
      --tunnel-user "$TU" --tunnel-pass "$TPW" --tunnel-insecure --cert-mode "$CM")
[ -n "$EMAIL" ] && ARGS+=(--email "$EMAIL")
if [ "$CM" = "dns-cloudflare" ]; then
  ARGS+=(--cf-token "$(ask 'Cloudflare API token (Zone:DNS:Edit)')")
elif [ "$CM" = "dns-arvan" ]; then
  echo "  #  رکورد A را در ArvanCloud روی DNS-only (ابر خاموش) بگذارید."
  ARGS+=(--arvan-token "$(ask 'ArvanCloud API key')")
fi

echo; info "Running Iran setup…"
./setup.sh "${ARGS[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo
  red "Iran install did not finish (exit code $rc)."
  echo "  #  نصب سرور ایران کامل نشد. متن بالا را برای بررسی بفرست."
  exit "$rc"
fi

# hand the operator the exact command for the foreign server
echo
grn "=================================================================="
grn "  NEXT: run this on the FOREIGN server ($EXIP)"
echo "  #  گام بعد: این دستور را روی سرور خارج ($EXIP) اجرا کنید:"
grn "=================================================================="
echo
echo "bash <(curl -fsSL https://raw.githubusercontent.com/$SLUG/$BRANCH/install.sh) \\"
echo "     --role exit --self-signed --tunnel-port $TP --tunnel-user $TU --tunnel-pass $TPW"
echo
echo "  After that runs on the foreign box, the tunnel comes up and it all works."
echo "  #  بعد از اجرای آن روی خارج، تانل بالا می‌آید و پروکسی کامل کار می‌کند."
echo "  (also saved to /root/run-on-foreign-server.txt)"
{
  echo "# Run this on the FOREIGN server ($EXIP):"
  echo "bash <(curl -fsSL https://raw.githubusercontent.com/$SLUG/$BRANCH/install.sh) --role exit --self-signed --tunnel-port $TP --tunnel-user $TU --tunnel-pass $TPW"
} > /root/run-on-foreign-server.txt
chmod 600 /root/run-on-foreign-server.txt
