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

ask(){ local p="$1" d="${2:-}" v; read -rp "$p${d:+ [$d]}: " v; echo "${v:-$d}"; }
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

echo
cat <<'B'
─────────────────────────────────────────────────────────────────
  این سرور کدام است؟   /   Which server is this?

    1) سرور ایران  (پنل مدیریت + پروکسی)   ← اول این را نصب کنید
       ENTRY — Iran  (dashboard + proxy)   ← install FIRST

    2) سرور خارج  (فقط تانل، بدون دامنه)
       EXIT  — Foreign (tunnel only, no domain)
─────────────────────────────────────────────────────────────────
B
RC="$(ask 'شماره / number' '1')"

# ============================ EXIT (foreign) =====================
if [ "$RC" = "2" ]; then
  echo
  yel "سرور خارج فقط تانل است: بدون دامنه، بدون گواهی معتبر، بدون داشبورد."
  echo "Foreign node = tunnel only. Best: paste the ready command that the Iran"
  echo "install printed. Otherwise enter the SAME tunnel user/pass you used on Iran."
  TP="$(ask 'پورت تانل / tunnel port' '8443')"
  TU="$(ask 'یوزر تانل / tunnel user' 'tunnel')"
  TPW="$(ask 'پسورد تانل / tunnel pass (خالی=ساخت خودکار)')"
  [ -n "$TPW" ] || { TPW="$(gen 24)"; yel "پسورد ساخته‌شده / generated: $TPW  (باید روی ایران هم همین باشد)"; }
  echo; info "Running foreign tunnel setup…"
  exec ./setup.sh --role exit --self-signed --tunnel-port "$TP" --tunnel-user "$TU" --tunnel-pass "$TPW"
fi

# ============================ ENTRY (Iran) =======================
echo
grn "سرور ایران — پنل مدیریت و پروکسیِ WHMCS اینجا نصب می‌شود."
echo   "Iran node — the dashboard and the SOCKS/HTTPS proxy live here."
echo
echo "▸ ساب‌دامینِ پروکسی (همان که در WHMCS وارد می‌کنید)."
echo "  یک رکورد A بسازید که به IP همین سرور ایران اشاره کند."
echo "  مهم: در WHMCS باید همین «نام» را بگذارید، نه IP — چون گواهی SSL روی نام صادر"
echo "  می‌شود و اگر IP بگذارید خطای cURL 51 می‌گیرید."
echo "  (Proxy subdomain used in WHMCS; A record must point to THIS server.)"
DOMAIN="$(ask 'ساب‌دامین / subdomain (e.g. proxy.digitalvps.ir)')"
[ -n "$DOMAIN" ] || die "subdomain required / ساب‌دامین لازم است"

echo
echo "▸ IP سرور خارج (تانل به آن وصل می‌شود)."
echo "  The foreign server's public IP (the tunnel connects there)."
EXIP="$(ask 'IP سرور خارج / foreign IP')"
[ -n "$EXIP" ] || die "foreign IP required / IP خارج لازم است"
TP="$(ask 'پورت تانل / tunnel port' '8443')"

echo
echo "▸ ایمیل برای Let's Encrypt (اختیاری) / email (optional)."
EMAIL="$(ask 'email')"

echo
echo "▸ روش گواهی / certificate method:"
echo "   standalone      : ساده — پورت ۸۰ باز و CDN خاموش  (simple; needs :80, CDN off)"
echo "   dns-cloudflare  : دامنه روی Cloudflare (با CDN هم کار می‌کند)"
echo "   dns-arvan       : دامنه روی ArvanCloud (با CDN هم کار می‌کند)"
CM="$(ask 'cert mode' 'standalone')"

# the Iran side mints the shared tunnel secret
TU="tunnel"; TPW="$(gen 24)"

ARGS=(--role entry --domain "$DOMAIN" --exit-host "$EXIP" --exit-port "$TP"
      --tunnel-user "$TU" --tunnel-pass "$TPW" --tunnel-insecure --cert-mode "$CM")
[ -n "$EMAIL" ] && ARGS+=(--email "$EMAIL")
if [ "$CM" = "dns-cloudflare" ]; then
  ARGS+=(--cf-token "$(ask 'Cloudflare API token (Zone:DNS:Edit)')")
elif [ "$CM" = "dns-arvan" ]; then
  yel "رکورد A را در ArvanCloud روی DNS-only (ابر خاموش) بگذارید."
  ARGS+=(--arvan-token "$(ask 'ArvanCloud API key')")
fi

echo; info "Running Iran setup… / نصب سرور ایران…"
./setup.sh "${ARGS[@]}"
rc=$?
[ "$rc" -eq 0 ] || { red "نصب ایران کامل نشد (کد $rc). خروجی بالا را بفرست."; exit "$rc"; }

# hand the operator the exact command for the foreign server
echo
grn "═══════════════════════════════════════════════════════════════════"
grn "  گام بعد — این دستور را روی سرور خارج ($EXIP) اجرا کنید:"
grn "  NEXT — run this on the FOREIGN server ($EXIP):"
grn "═══════════════════════════════════════════════════════════════════"
echo
echo "bash <(curl -fsSL https://raw.githubusercontent.com/$SLUG/$BRANCH/install.sh) \\"
echo "     --role exit --self-signed --tunnel-port $TP --tunnel-user $TU --tunnel-pass $TPW"
echo
echo "پس از اجرای دستور بالا روی خارج، تانل بالا می‌آید و پروکسی کامل کار می‌کند."
echo "(After that runs on the foreign box, the tunnel comes up and the proxy works.)"
echo
grn "این دستور در فایل زیر هم ذخیره شد:  /root/run-on-foreign-server.txt"
{
  echo "# Run this on the FOREIGN server ($EXIP):"
  echo "bash <(curl -fsSL https://raw.githubusercontent.com/$SLUG/$BRANCH/install.sh) --role exit --self-signed --tunnel-port $TP --tunnel-user $TU --tunnel-pass $TPW"
} > /root/run-on-foreign-server.txt
chmod 600 /root/run-on-foreign-server.txt
