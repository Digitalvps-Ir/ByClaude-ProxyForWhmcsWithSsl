#!/usr/bin/env bash
# lib/common.sh — shared helpers for setup.sh and the whmcsproxy menu.
# Sourced, never executed directly. Bash 4+.

WP_INSTALL_DIR="${WP_INSTALL_DIR:-/opt/whmcs-proxy}"
WP_STATE="${GOST_STATE:-/etc/gost/state.json}"
WP_LOG_DIR="${WP_LOG_DIR:-/var/log/gost}"

wp_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
wp_yel(){ printf '\033[33m%s\033[0m\n' "$*"; }
wp_red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
wp_info(){ printf '\033[36m›\033[0m %s\n' "$*"; }
wp_die(){ wp_red "ERROR: $*"; return 1; }
wp_have(){ command -v "$1" >/dev/null 2>&1; }
wp_rand(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-18}"; }

wp_ctl(){ python3 "$WP_INSTALL_DIR/gostctl.py" "$@"; }

# read a value from the state JSON:  wp_jget "state['domain']"
wp_jget(){
  python3 - "$WP_STATE" "$1" <<'PY' 2>/dev/null
import json,sys
try:
    state=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
try:
    print(eval(sys.argv[2], {"state":state}))
except Exception:
    sys.exit(1)
PY
}

wp_first_user(){ wp_jget "next((u['username'] for u in state['users'] if u.get('enabled',True)),'')"; }
wp_first_pass(){ wp_jget "next((u['password'] for u in state['users'] if u.get('enabled',True)),'')"; }

# ---------------------------------------------------------------- certificates
# wp_issue_cert DOMAIN EMAIL MODE EXTRA
#   MODE: standalone | webroot | dns-cloudflare | existing(skip)
#   EXTRA: webroot path (webroot) or CF token/file (dns-cloudflare)
wp_issue_cert(){
  local domain="$1" email="$2" mode="${3:-standalone}" extra="$4"
  [ -n "$domain" ] || { wp_die "wp_issue_cert: domain required"; return 1; }
  if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
    wp_info "certificate for $domain already present"; return 0
  fi
  wp_have certbot || wp_apt_install certbot
  local ca="--non-interactive --agree-tos"
  if [ -n "$email" ]; then ca="$ca -m $email"; else ca="$ca --register-unsafely-without-email"; fi
  case "$mode" in
    standalone)
      wp_info "Issuing Let's Encrypt cert for $domain (standalone; needs :80 free & DNS ready)…"
      certbot certonly --standalone -d "$domain" $ca --preferred-challenges http ;;
    webroot)
      mkdir -p "${extra:-/var/www/html}"
      certbot certonly --webroot -w "${extra:-/var/www/html}" -d "$domain" $ca ;;
    dns-cloudflare)
      local cf="$extra"
      if [ -n "$extra" ] && [ ! -f "$extra" ]; then
        cf="/etc/letsencrypt/cloudflare.ini"
        printf 'dns_cloudflare_api_token = %s\n' "$extra" > "$cf"; chmod 600 "$cf"
      fi
      wp_have certbot-dns-cloudflare || wp_apt_install python3-certbot-dns-cloudflare
      certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$cf" -d "$domain" $ca ;;
    dns-arvan)
      local hook="$WP_INSTALL_DIR/certbot-arvan-hook.sh"
      [ -f "$hook" ] || hook="$(dirname "${BASH_SOURCE[0]}")/certbot-arvan-hook.sh"
      [ -f "$hook" ] || { wp_die "ArvanCloud hook not found ($hook)"; return 1; }
      [ -n "$extra" ] || { wp_die "dns-arvan needs the ArvanCloud API key"; return 1; }
      wp_info "Issuing cert for $domain via ArvanCloud DNS-01 (works behind the CDN)…"
      ARVAN_API_KEY="$extra" certbot certonly --manual --preferred-challenges dns \
        --manual-auth-hook "$hook auth" --manual-cleanup-hook "$hook cleanup" \
        -d "$domain" $ca ;;
    *) wp_die "unknown cert mode: $mode"; return 1 ;;
  esac
}

wp_apt_install(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq "$@" >/dev/null
}

# ---------------------------------------------------------------- domain change
# wp_migrate_proxy_domain NEWDOMAIN [EMAIL] [MODE] [EXTRA]
wp_migrate_proxy_domain(){
  local nd="$1" email="$2" mode="${3:-standalone}" extra="$4"
  [ -n "$nd" ] || { wp_die "new domain required"; return 1; }
  wp_issue_cert "$nd" "$email" "$mode" "$extra" || { wp_red "cert issuance failed; domain NOT changed"; return 1; }
  wp_ctl set-domain "$nd" --apply
  wp_restart_dashboard   # dashboard may share this cert
  wp_grn "✓ proxy now serves https://$nd  (update WHMCS to this host)"
}

# wp_migrate_dashboard_domain NEWDOMAIN [EMAIL] [MODE] [EXTRA]
wp_migrate_dashboard_domain(){
  local nd="$1" email="$2" mode="${3:-standalone}" extra="$4"
  [ -n "$nd" ] || { wp_die "new domain required"; return 1; }
  wp_issue_cert "$nd" "$email" "$mode" "$extra" || { wp_red "cert issuance failed; dashboard domain NOT changed"; return 1; }
  wp_ctl set-domain "$nd" --dashboard --apply
  wp_restart_dashboard
  local dp; dp="$(wp_jget "state['ports']['dashboard']")"
  wp_grn "✓ dashboard now at https://$nd:${dp}"
}

wp_restart_dashboard(){ systemctl restart whmcs-proxy-dashboard 2>/dev/null || true; }
wp_restart_gost(){ systemctl restart gost 2>/dev/null || true; }

# ---------------------------------------------------------------- network tuning
# High-throughput / low-latency tuning for a long-haul tunnel:
#  BBR congestion control + fq qdisc, large socket buffers, TCP fast open,
#  no slow-start-after-idle, MTU probing, big backlog & fd limits.
wp_apply_tuning(){
  wp_info "Applying network performance tuning (BBR + buffers)…"
  modprobe tcp_bbr 2>/dev/null || true
  grep -q '^tcp_bbr' /etc/modules-load.d/*.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-whmcs-proxy.conf <<'EOF'
# WHMCS proxy tunnel tuning — throughput & latency for long-haul links
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1000000
EOF
  sysctl --system >/dev/null 2>&1 || true
  # raise open-file limits for the services
  if ! grep -q 'whmcs-proxy nofile' /etc/security/limits.conf 2>/dev/null; then
    printf '* soft nofile 1048576\n* hard nofile 1048576\n# whmcs-proxy nofile\n' >> /etc/security/limits.conf
  fi
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  local qd; qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  wp_grn "✓ tuning applied (congestion=$cc qdisc=$qd)"
  [ "$cc" = "bbr" ] || wp_yel "  note: BBR not active — kernel may need 'modprobe tcp_bbr' or a reboot"
}

# ---------------------------------------------------------------- benchmark
# Measures the ENTRY→EXIT tunnel quality end to end.
wp_tunnel_benchmark(){
  local role; role="$(wp_jget "state['role']")"
  local domain https user pass exit_host
  domain="$(wp_jget "state['domain']")"
  https="$(wp_jget "state['ports']['https']")"
  exit_host="$(wp_jget "state['exit']['host']")"
  user="$(wp_first_user)"; pass="$(wp_first_pass)"

  echo "── Tunnel benchmark ────────────────────────────────"
  if [ "$role" != "entry" ]; then
    wp_yel "run this on the ENTRY (Iran) node"; return 0
  fi
  local proxy="https://$user:$pass@$domain:$https"

  # 1) path quality to the exit (packet loss + jitter via ICMP if allowed)
  if wp_have ping && [ -n "$exit_host" ]; then
    echo "• Path to exit ($exit_host):"
    ping -c 20 -i 0.2 -W 2 "$exit_host" 2>/dev/null | tail -2 | sed 's/^/    /' \
      || echo "    (ICMP blocked — skipping; TCP latency below is what matters)"
  fi

  # 2) request latency through the tunnel + jitter (20 samples)
  echo "• Request latency through the tunnel (20 samples):"
  local target="${1:-https://bsc-dataseed4.binance.org/}"
  local tmp; tmp="$(mktemp)"
  local t
  for _ in $(seq 1 20); do
    t="$(curl -sS -o /dev/null -m 15 -x "$proxy" -w '%{time_total}' "$target" 2>/dev/null || echo '')"
    [ -n "$t" ] && echo "$t" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    awk '{s+=$1; if(min==""||$1<min)min=$1; if($1>max)max=$1; a[NR]=$1}
      END{m=s/NR; for(i=1;i<=NR;i++){d=a[i]-m; v+=d*d}; j=sqrt(v/NR);
      printf "    samples=%d  min=%.0fms  avg=%.0fms  max=%.0fms  jitter=%.1fms\n",
      NR, min*1000, m*1000, max*1000, j*1000}' "$tmp"
    local ok; ok=$(wc -l < "$tmp")
    printf "    packet/req loss: %d%%\n" $(( (20-ok)*100/20 ))
  else
    wp_red "    all requests failed — tunnel or proxy is down"
  fi
  rm -f "$tmp"

  # 3) throughput through the tunnel
  echo "• Throughput through the tunnel (10 MB download):"
  local spd
  spd="$(curl -sS -o /dev/null -m 60 -x "$proxy" \
        -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=10000000' 2>/dev/null || echo 0)"
  awk -v s="$spd" 'BEGIN{ if(s+0>0) printf "    %.2f MB/s (%.1f Mbit/s)\n", s/1048576, s*8/1000000; else print "    (download test unavailable)"}'

  # 4) egress IP as seen by the internet (should be the EXIT server)
  echo "• Exit IP seen by the internet:"
  local eip; eip="$(curl -sS -m 15 -x "$proxy" https://api.ipify.org 2>/dev/null || echo '?')"
  echo "    $eip"
  echo "────────────────────────────────────────────────────"
}

wp_tunnel_health(){
  local user pass domain https
  domain="$(wp_jget "state['domain']")"; https="$(wp_jget "state['ports']['https']")"
  user="$(wp_first_user)"; pass="$(wp_first_pass)"
  local code
  code="$(curl -sS -o /dev/null -m 15 -x "https://$user:$pass@$domain:$https" \
        -w '%{http_code}' https://api.ipify.org 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then wp_grn "tunnel OK (proxy reachable, egress works)"; return 0; fi
  wp_red "tunnel DOWN (code=$code) — check: systemctl status gost; journalctl -u gost -n 40"; return 1
}
