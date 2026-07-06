#!/usr/bin/env bash
# ==============================================================================
# Title: configure-cloudflare-realip.sh
# Version: 1.0.0 (SafeCloud.PRO)
# Purpose: Restore the real visitor IP behind Cloudflare.
#          When the origin is proxied through Cloudflare, nginx sees a Cloudflare
#          edge IP as the client unless it is told to trust Cloudflare and read
#          the CF-Connecting-IP header. Without this:
#            * the access log records Cloudflare IPs, so the nginx-wp-login
#              Fail2ban jail would ban CLOUDFLARE — taking the whole site down;
#            * WordPress/WooCommerce sees every visitor as a Cloudflare IP.
#
#          This pulls Cloudflare's CURRENT ranges and writes
#          /etc/nginx/conf.d/cloudflare-realip.conf with:
#            set_real_ip_from <each Cloudflare CIDR>;
#            real_ip_header    CF-Connecting-IP;
#            real_ip_recursive on;
#          then validates and reloads nginx (rolling back on failure).
#
#   sudo ./configure-cloudflare-realip.sh              # write + reload
#   sudo ./configure-cloudflare-realip.sh --print      # print the config, change nothing
#
# Re-run whenever Cloudflare updates its ranges (pairs with
# configure-security-group.sh, which uses the same list at the network edge).
# ==============================================================================

set -uo pipefail

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi
info(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){  echo -e "${RED}[ERROR]${NC} $*" >&2; }

CONF="/etc/nginx/conf.d/cloudflare-realip.conf"
CF_V4_URL="https://www.cloudflare.com/ips-v4"
CF_V6_URL="https://www.cloudflare.com/ips-v6"
PRINT_ONLY=false
NO_COLOR=false

show_help() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Write /etc/nginx/conf.d/cloudflare-realip.conf so nginx logs and passes the true
visitor IP (from CF-Connecting-IP) instead of a Cloudflare edge IP.

Options:
  --print       Print the generated config to stdout and exit (no changes).
  --conf PATH   Output path (default: ${CONF}).
  --no-color    Disable coloured output.
  -h, --help    Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --print)    PRINT_ONLY=true; shift;;
        --conf)     [ -n "${2:-}" ] || { err "--conf needs a path"; exit 1; }; CONF="$2"; shift 2;;
        --no-color) NO_COLOR=true; shift;;
        -h|--help)  show_help; exit 0;;
        *)          err "Unknown option: $1"; show_help; exit 1;;
    esac
done
if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''; fi

# ----- fetch Cloudflare ranges ------------------------------------------------
info "Fetching Cloudflare's current published IP ranges..."
mapfile -t CF_V4 < <(curl -fsSL --max-time 20 "$CF_V4_URL" | grep -E '^[0-9]+\.' || true)
mapfile -t CF_V6 < <(curl -fsSL --max-time 20 "$CF_V6_URL" | grep -E '^[0-9a-fA-F:]+/' || true)
if [ "${#CF_V4[@]}" -eq 0 ]; then
    err "Could not retrieve Cloudflare IPv4 ranges from ${CF_V4_URL}. Check outbound connectivity."
    exit 1
fi
info "Retrieved ${BOLD}${#CF_V4[@]}${NC} IPv4 and ${BOLD}${#CF_V6[@]}${NC} IPv6 ranges."

# ----- render the config ------------------------------------------------------
render() {
    echo "# Managed by configure-cloudflare-realip.sh — do not hand-edit; re-run to refresh."
    echo "# Restores the true client IP from Cloudflare's CF-Connecting-IP header."
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    local c
    for c in "${CF_V4[@]}"; do echo "set_real_ip_from ${c};"; done
    for c in "${CF_V6[@]}"; do echo "set_real_ip_from ${c};"; done
    echo
    echo "real_ip_header    CF-Connecting-IP;"
    echo "real_ip_recursive on;"
}

if [ "$PRINT_ONLY" = "true" ]; then
    render
    exit 0
fi

# ----- must be root to write nginx config -------------------------------------
if [ "$EUID" -ne 0 ]; then
    err "Must be run as root (sudo) to write ${CONF} and reload nginx (use --print to preview unprivileged)."
    exit 1
fi
command -v nginx >/dev/null 2>&1 || { err "nginx is not installed."; exit 1; }

mkdir -p "$(dirname "$CONF")"
BK=""
if [ -f "$CONF" ]; then BK="${CONF}.bak.$(date +%s)"; cp -a "$CONF" "$BK"; fi

render > "$CONF"
info "Wrote ${BOLD}${CONF}${NC} ($(( ${#CF_V4[@]} + ${#CF_V6[@]} )) trusted ranges)."

if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    info "nginx reloaded — the access log and WordPress now see the real client IP."
    [ -n "$BK" ] && rm -f "$BK"
    echo -e "${YELLOW}Note:${NC} this is what makes the ${BOLD}nginx-wp-login${NC} Fail2ban jail ban real"
    echo -e "      offenders instead of Cloudflare's edge IPs. Re-run when Cloudflare updates its ranges."
else
    err "nginx -t failed with the new real-IP config. Rolling back."
    nginx -t 2>&1 | sed 's/^/    /'
    if [ -n "$BK" ]; then cp -a "$BK" "$CONF"; else rm -f "$CONF"; fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    err "Reverted ${CONF}. No change applied."
    exit 1
fi
