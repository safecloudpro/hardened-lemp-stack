#!/usr/bin/env bash
# ==============================================================================
# Title: enable-redis-cache.sh
# Version: 1.0.0 (SafeCloud.PRO)
# Purpose: Close the Redis loop — setup.sh installs and hardens Redis (socket
#          only), but WordPress won't USE it until the object-cache drop-in is
#          wired up. This installs the "Redis Object Cache" plugin, points it at
#          the hardened Unix socket, and enables the drop-in via WP-CLI.
#
#          Run AFTER wordpress-provision.sh and BEFORE harden-wordpress.sh —
#          harden-wordpress sets DISALLOW_FILE_MODS and makes the code tree
#          root-owned, which (by design) blocks plugin installation. If you have
#          already hardened, either re-run harden-wordpress.sh with
#          --allow-updates first, or pass --force here (it briefly lifts the lock
#          for the install, then restores it).
#
#   sudo ./enable-redis-cache.sh
#   sudo ./enable-redis-cache.sh --webroot /var/www/html --force
# ==============================================================================

set -uo pipefail

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi
info(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){  echo -e "${RED}[ERROR]${NC} $*" >&2; }

WEBROOT="${WEBROOT:-/var/www/html}"
REDIS_SOCK="/var/run/redis/redis-server.sock"
FORCE=false
NO_COLOR=false

show_help() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Install + enable the Redis Object Cache drop-in for WordPress over the hardened
Unix socket (${REDIS_SOCK}).

Options:
  --webroot PATH   WordPress install dir (default: ${WEBROOT}).
  --socket PATH    Redis Unix socket (default: ${REDIS_SOCK}).
  --force          If DISALLOW_FILE_MODS is set, briefly lift it for the install
                   then restore it (otherwise the script stops with guidance).
  --no-color       Disable coloured output.
  -h, --help       Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --webroot) WEBROOT="${2:?}"; shift 2;;
        --socket)  REDIS_SOCK="${2:?}"; shift 2;;
        --force)   FORCE=true; shift;;
        --no-color) NO_COLOR=true; shift;;
        -h|--help) show_help; exit 0;;
        *)         err "Unknown option: $1"; show_help; exit 1;;
    esac
done
if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''; fi

# ----- preconditions ----------------------------------------------------------
[ "$EUID" -eq 0 ] || { err "Must be run as root (sudo)."; exit 1; }
command -v wp >/dev/null 2>&1 || { err "WP-CLI (wp) not found. Install it (setup.sh offers this) then re-run."; exit 1; }
command -v php >/dev/null 2>&1 || { err "php CLI not found."; exit 1; }
WPCONFIG="$WEBROOT/wp-config.php"
[ -f "$WPCONFIG" ] || { err "wp-config.php not found at ${WPCONFIG}. Set --webroot."; exit 1; }

if ! php -m 2>/dev/null | grep -qi '^redis$'; then
    err "The PHP 'redis' extension is not loaded. Install phpX.Y-redis (setup.sh's redis-cache component does this) and restart PHP-FPM."
    exit 1
fi
if [ ! -S "$REDIS_SOCK" ]; then
    warn "Redis socket ${REDIS_SOCK} not found. Is redis-server running and socket-configured? Continuing, but 'wp redis status' will fail until it exists."
fi

WP=(wp --allow-root --path="$WEBROOT")

echo -e "${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}SAFECLOUD.PRO — ENABLE REDIS OBJECT CACHE${NC}"
echo -e "${CYAN}======================================================================${NC}"

# ----- handle the DISALLOW_FILE_MODS lock -------------------------------------
LOCK_LIFTED=false
if "${WP[@]}" config get DISALLOW_FILE_MODS 2>/dev/null | grep -qi '^1\|true'; then
    if [ "$FORCE" != "true" ]; then
        err "DISALLOW_FILE_MODS is enabled — plugin installation is blocked by design."
        echo -e "  Run this BEFORE ${BOLD}harden-wordpress.sh${NC}, or:" >&2
        echo -e "    • ${BOLD}sudo ./harden-wordpress.sh --allow-updates${NC} (unlock), then re-run this, then re-run harden, or" >&2
        echo -e "    • re-run this with ${BOLD}--force${NC} to briefly lift the lock automatically." >&2
        exit 1
    fi
    info "DISALLOW_FILE_MODS is set — temporarily lifting it for the install (--force)."
    cp -a "$WPCONFIG" "${WPCONFIG}.bak.redis.$(date +%s)"
    "${WP[@]}" config set DISALLOW_FILE_MODS false --raw --type=constant >/dev/null 2>&1 || \
        sed -i -E "s/(define\(\s*'DISALLOW_FILE_MODS'\s*,\s*)true/\1false/" "$WPCONFIG"
    LOCK_LIFTED=true
fi

relock() {
    if [ "$LOCK_LIFTED" = "true" ]; then
        "${WP[@]}" config set DISALLOW_FILE_MODS true --raw --type=constant >/dev/null 2>&1 || \
            sed -i -E "s/(define\(\s*'DISALLOW_FILE_MODS'\s*,\s*)false/\1true/" "$WPCONFIG"
        info "Restored DISALLOW_FILE_MODS=true."
    fi
}
trap relock EXIT

# ----- install + configure ----------------------------------------------------
info "Installing and activating the Redis Object Cache plugin..."
if ! "${WP[@]}" plugin install redis-cache --activate 2>&1 | sed 's/^/    /'; then
    err "Plugin install/activate failed (network? file permissions?)."
    exit 1
fi

info "Pointing WordPress at the Unix socket..."
# Write the connection constants as a managed block inserted before the
# wp-settings bootstrap. This does NOT rely on WP-CLI's "config set", which needs
# the stock "/* That's all, stop editing! */" anchor that a custom wp-config may
# not have. Idempotent: any previous block is removed first.
write_redis_constants() {
    local begin="// >>> SafeCloud Redis object cache (managed by enable-redis-cache.sh) >>>"
    local end="// <<< SafeCloud Redis object cache (managed by enable-redis-cache.sh) <<<"
    local esc_b esc_e tmpd
    esc_b=$(printf '%s' "$begin" | sed 's/[][\/.*^$]/\\&/g')
    esc_e=$(printf '%s' "$end"   | sed 's/[][\/.*^$]/\\&/g')
    sed -i "/$esc_b/,/$esc_e/d" "$WPCONFIG"
    tmpd="$(mktemp -d)"
    {
        echo "$begin"
        echo "defined('WP_REDIS_SCHEME')   || define('WP_REDIS_SCHEME', 'unix');"
        printf "defined('WP_REDIS_PATH')     || define('WP_REDIS_PATH', '%s');\n" "$REDIS_SOCK"
        echo "defined('WP_REDIS_TIMEOUT')  || define('WP_REDIS_TIMEOUT', 1);"
        echo "defined('WP_REDIS_DATABASE') || define('WP_REDIS_DATABASE', 0);"
        echo "$end"
    } > "$tmpd/block.php"
    awk -v bf="$tmpd/block.php" '
        /require_once.*wp-settings\.php/ && !ins { while ((getline l < bf) > 0) print l; print ""; ins=1 }
        { print }
        END { if (!ins) { while ((getline l < bf) > 0) print l } }
    ' "$WPCONFIG" > "$tmpd/wpc" && cat "$tmpd/wpc" > "$WPCONFIG"
    rm -rf "$tmpd"
    php -l "$WPCONFIG" >/dev/null 2>&1 || { err "wp-config.php failed php -l after writing Redis constants."; return 1; }
}
write_redis_constants || exit 1

info "Enabling the object-cache drop-in..."
"${WP[@]}" redis enable 2>&1 | sed 's/^/    /' || warn "'wp redis enable' reported an issue — check 'wp redis status'."

# ----- ownership (match the hardened code model) ------------------------------
for p in "$WEBROOT/wp-content/plugins/redis-cache" "$WEBROOT/wp-content/object-cache.php"; do
    [ -e "$p" ] && chown -R www-data:www-data "$p"
done

# ----- restart PHP-FPM so the web tier picks up the new config -----------------
# OPcache runs with validate_timestamps=0 (setup.sh hardening), so PHP-FPM caches
# wp-config.php and will NOT see the new WP_REDIS_* constants until it restarts —
# without this the just-added object-cache drop-in falls back to TCP and 500s.
_phpv=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
if [ -n "$_phpv" ] && systemctl list-units --type=service 2>/dev/null | grep -q "php${_phpv}-fpm"; then
    info "Restarting php${_phpv}-fpm to clear OPcache (validate_timestamps=0)..."
    systemctl restart "php${_phpv}-fpm" 2>/dev/null || warn "Could not restart php${_phpv}-fpm; do it manually so the cache takes effect."
fi

# ----- verify -----------------------------------------------------------------
echo
info "Redis object cache status:"
"${WP[@]}" redis status 2>&1 | sed 's/^/    /' || true

echo -e "${GREEN}${BOLD}Done.${NC} If status shows ${BOLD}Connected${NC}, WordPress is now serving its object cache from Redis."
echo -e "If you lifted the lock with --force, DISALLOW_FILE_MODS has been restored."
