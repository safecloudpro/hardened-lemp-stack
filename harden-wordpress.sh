#!/usr/bin/env bash
# ==============================================================================
# Title: harden-wordpress.sh
# Purpose: Apply application-layer hardening to an installed WordPress site,
#          complementing the OS/Nginx/MariaDB hardening from setup.sh.
#            1. Inject security constants into wp-config.php (idempotent).
#            2. Lock down file ownership and permissions.
#            3. Remove version-disclosure and sample files.
#            4. Deploy the SafeCloud MU-plugin so hardening loads before plugins.
#            5. (optional) Rotate the authentication salts.
#
# Run as root:  sudo ./harden-wordpress.sh [--webroot PATH]
#
# Idempotent: safe to run repeatedly. The wp-config block is delimited by markers
# and rewritten in place, and every constant uses defined()||define() so it never
# collides with a value WordPress or another config already set.
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

# ----- config / options -------------------------------------------------------
WEBROOT="${WEBROOT:-/var/www/html}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MU_PLUGIN_SRC="${MU_PLUGIN_SRC:-$SCRIPT_DIR/wordpress/mu-plugins/safecloud-hardening.php}"
ALLOW_UPDATES=false     # true → permit dashboard plugin/theme/core updates
ROTATE_SALTS=false      # true → regenerate auth salts (logs everyone out)
SALT_API="https://api.wordpress.org/secret-key/1.1/salt/"
MARK_BEGIN="// >>> SafeCloud WP hardening (managed by harden-wordpress.sh) >>>"
MARK_END="// <<< SafeCloud WP hardening (managed by harden-wordpress.sh) <<<"

while [ $# -gt 0 ]; do
    case "$1" in
        --webroot)   WEBROOT="${2:?--webroot needs a path}"; shift 2;;
        --mu-plugin) MU_PLUGIN_SRC="${2:?--mu-plugin needs a path}"; shift 2;;
        --allow-updates) ALLOW_UPDATES=true; shift;;
        --rotate-salts)  ROTATE_SALTS=true; shift;;
        -h|--help)
            cat <<EOF
Usage: sudo $(basename "$0") [OPTIONS]
  --webroot PATH     WordPress install directory (default: /var/www/html)
  --mu-plugin PATH   Path to safecloud-hardening.php to deploy
  --allow-updates    Permit dashboard/auto updates (default: locked down)
  --rotate-salts     Regenerate authentication salts (logs all users out)
  -h, --help         Show this help
EOF
            exit 0;;
        *) err "Unknown option: $1"; exit 1;;
    esac
done

# ----- preconditions ----------------------------------------------------------
[ "$EUID" -eq 0 ] || { err "Must be run as root (sudo)."; exit 1; }
WPCONFIG="$WEBROOT/wp-config.php"
[ -f "$WPCONFIG" ] || { err "wp-config.php not found at ${WPCONFIG}. Set --webroot."; exit 1; }
grep -q "wp-settings.php" "$WPCONFIG" || { err "${WPCONFIG} doesn't look like a WordPress config."; exit 1; }

umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ----- 0. backup --------------------------------------------------------------
BK="${WPCONFIG}.bak.$(date +%s)"
cp -a "$WPCONFIG" "$BK"
info "Backed up wp-config.php -> ${BK}"

# ==============================================================================
# 1. Security constants block (idempotent)
# ==============================================================================
info "Applying security constants to wp-config.php..."

# Remove any previous managed block so re-runs don't stack up.
sed -i "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\/.*^$]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\/.*^$]/\\&/g')/d" "$WPCONFIG"

# Build the fresh block.
{
    echo "$MARK_BEGIN"
    echo "// Edit the flags in harden-wordpress.sh and re-run; do not hand-edit this block."
    echo "defined('FORCE_SSL_ADMIN')         || define('FORCE_SSL_ADMIN', true);"
    echo "defined('DISALLOW_FILE_EDIT')      || define('DISALLOW_FILE_EDIT', true);"
    if [ "$ALLOW_UPDATES" = "true" ]; then
        echo "defined('DISALLOW_FILE_MODS')      || define('DISALLOW_FILE_MODS', false);"
        echo "defined('WP_AUTO_UPDATE_CORE')     || define('WP_AUTO_UPDATE_CORE', 'minor');"
    else
        echo "defined('DISALLOW_FILE_MODS')      || define('DISALLOW_FILE_MODS', true);"
        echo "defined('AUTOMATIC_UPDATER_DISABLED') || define('AUTOMATIC_UPDATER_DISABLED', true);"
    fi
    echo "defined('DISALLOW_UNFILTERED_HTML')|| define('DISALLOW_UNFILTERED_HTML', true);"
    echo "defined('WP_DEBUG')                || define('WP_DEBUG', false);"
    echo "defined('WP_DEBUG_DISPLAY')        || define('WP_DEBUG_DISPLAY', false);"
    echo "defined('WP_DEBUG_LOG')            || define('WP_DEBUG_LOG', false);"
    echo "defined('WP_POST_REVISIONS')       || define('WP_POST_REVISIONS', 5);"
    echo "defined('EMPTY_TRASH_DAYS')        || define('EMPTY_TRASH_DAYS', 7);"
    echo "@ini_set('display_errors', '0');"
    echo "$MARK_END"
} > "$TMP/block.php"

# Insert the block immediately before the wp-settings.php bootstrap line.
awk -v bf="$TMP/block.php" '
    /require_once.*wp-settings\.php/ && !ins {
        while ((getline l < bf) > 0) print l
        print ""
        ins=1
    }
    { print }
    END { if (!ins) { while ((getline l < bf) > 0) print l } }
' "$WPCONFIG" > "$TMP/wpc" && cat "$TMP/wpc" > "$WPCONFIG"

# ==============================================================================
# 2. Optional: rotate authentication salts
# ==============================================================================
if [ "$ROTATE_SALTS" = "true" ]; then
    info "Rotating authentication salts (all sessions will be logged out)..."
    if curl -fsS --retry 2 "$SALT_API" -o "$TMP/salts.php" 2>/dev/null && grep -q AUTH_KEY "$TMP/salts.php"; then
        # Drop existing salt defines, then insert the fresh set before wp-settings.
        sed -i -E "/define\(\s*'(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT)'/d" "$WPCONFIG"
        awk -v bf="$TMP/salts.php" '
            /require_once.*wp-settings\.php/ && !ins { while ((getline l < bf) > 0) print l; ins=1 }
            { print }
        ' "$WPCONFIG" > "$TMP/wpc2" && cat "$TMP/wpc2" > "$WPCONFIG"
        info "Salts rotated."
    else
        warn "Could not fetch new salts from ${SALT_API}; leaving existing salts unchanged."
    fi
fi

# ==============================================================================
# 3. Validate the edited config (rollback on failure)
# ==============================================================================
if command -v php >/dev/null 2>&1; then
    if ! php -l "$WPCONFIG" >/dev/null 2>&1; then
        err "Edited wp-config.php failed php -l. Restoring backup."
        php -l "$WPCONFIG" 2>&1 | sed 's/^/    /'
        cp -a "$BK" "$WPCONFIG"
        exit 1
    fi
    info "wp-config.php passes php -l."
else
    warn "php CLI not found — skipped syntax check (backup kept at ${BK})."
fi

# ==============================================================================
# 4. Remove version-disclosure and sample files
# ==============================================================================
info "Removing version-disclosure and sample files..."
for f in readme.html license.txt wp-config-sample.php \
         wp-content/plugins/hello.php; do
    if [ -e "$WEBROOT/$f" ]; then rm -f "$WEBROOT/$f" && echo "    removed $f"; fi
done

# ==============================================================================
# 5. Ownership and permissions
# ==============================================================================
# Default (locked-down) model: code is owned by root and only READABLE by the
# web user, so even outside PHP (whose AppArmor profile already denies these
# writes) www-data cannot modify wp-admin/wp-includes/plugins/themes. Only the
# runtime paths (uploads, cache) stay web-writable.
# With --allow-updates the dashboard updater needs write access to the code
# directories, so everything reverts to www-data ownership.
if [ "$ALLOW_UPDATES" = "true" ]; then
    info "Setting ownership (www-data, dashboard updates allowed) and permissions..."
    chown -R www-data:www-data "$WEBROOT"
else
    info "Setting ownership (root:www-data code, www-data runtime dirs) and permissions..."
    chown -R root:www-data "$WEBROOT"
fi
find "$WEBROOT" -type d -exec chmod 755 {} +
find "$WEBROOT" -type f -exec chmod 644 {} +
# wp-config.php: not world-readable; group read lets PHP-FPM (www-data) load it.
chown "$([ "$ALLOW_UPDATES" = "true" ] && echo www-data || echo root)":www-data "$WPCONFIG"
chmod 640 "$WPCONFIG"
# Ensure the web-writable runtime directories exist and belong to the web user.
install -d -o www-data -g www-data -m 755 "$WEBROOT/wp-content/uploads" "$WEBROOT/wp-content/cache"
chown -R www-data:www-data "$WEBROOT/wp-content/uploads" "$WEBROOT/wp-content/cache"

# ==============================================================================
# 6. Deploy the SafeCloud MU-plugin
# ==============================================================================
if [ -f "$MU_PLUGIN_SRC" ]; then
    info "Deploying MU-plugin (loads before all standard plugins, cannot be disabled from the dashboard)..."
    install -d -o www-data -g www-data -m 755 "$WEBROOT/wp-content/mu-plugins"
    install -o www-data -g www-data -m 644 "$MU_PLUGIN_SRC" \
        "$WEBROOT/wp-content/mu-plugins/$(basename "$MU_PLUGIN_SRC")"
    echo "    installed $(basename "$MU_PLUGIN_SRC")"
else
    warn "MU-plugin not found at ${MU_PLUGIN_SRC} — skipped. Use --mu-plugin PATH to point at it."
fi

# ==============================================================================
# 7. Summary
# ==============================================================================
echo -e "${CYAN}----------------------------------------------------------------------${NC}"
echo -e "${GREEN}${BOLD}WordPress hardening applied.${NC}"
echo -e "  Webroot:        ${BOLD}${WEBROOT}${NC}"
echo -e "  Dashboard edits: ${BOLD}disabled${NC} (DISALLOW_FILE_EDIT)"
if [ "$ALLOW_UPDATES" = "true" ]; then
    echo -e "  Updates:        ${BOLD}dashboard/auto updates allowed${NC} (--allow-updates)"
else
    echo -e "  Updates:        ${BOLD}locked${NC} (DISALLOW_FILE_MODS) — update via WP-CLI / deploy pipeline"
fi
echo -e "  Admin over TLS: ${BOLD}forced${NC} (FORCE_SSL_ADMIN)"
echo -e "  Backup:         ${BOLD}${BK}${NC}"
echo -e "${YELLOW}Note:${NC} DISALLOW_FILE_MODS blocks the dashboard's plugin/theme/core updater, and"
echo -e "      code directories are owned by root (www-data has read-only access)."
echo -e "      To update: re-run with ${BOLD}--allow-updates${NC} (restores www-data ownership),"
echo -e "      update via dashboard or WP-CLI, then re-run ${BOLD}$(basename "$0")${NC} to re-lock."
echo -e "${CYAN}----------------------------------------------------------------------${NC}"
