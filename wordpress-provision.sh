#!/usr/bin/env bash
# ==============================================================================
# Title: wordpress-provision.sh
# Purpose: Provision a WordPress site against the hardened LEMP stack:
#          1. Prompt for the WordPress DB name, DB user, and DB password.
#          2. Create the database + user and grant that user full rights on it.
#          3. Prompt for a MariaDB root password and secure the server
#             (remove anonymous users, disallow remote root, drop the test DB,
#             restrict networking to localhost).
#          4. Download the latest WordPress and write wp-config.php wired to the
#             database user/password created above (with fresh salts).
#
# Run as root (sudo) on the box AFTER setup.sh has installed MariaDB + PHP-FPM.
#   sudo ./wordpress-provision.sh
# ==============================================================================

set -uo pipefail

# ----- appearance -------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi
info(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){  echo -e "${RED}[ERROR]${NC} $*" >&2; }
hr(){   echo -e "${CYAN}----------------------------------------------------------------------${NC}"; }

# ----- config -----------------------------------------------------------------
# Default to /var/www/html: it matches the root in setup.sh's generated nginx
# config AND the paths allowed by the nginx AppArmor profile, so no nginx or
# profile edits are needed. Override with --webroot (or WP_DIR=) only if you also
# update those two places.
WP_DIR="${WP_DIR:-/var/www/html}"        # webroot nginx should serve
WP_TARBALL_URL="https://wordpress.org/latest.tar.gz"
SALT_API="https://api.wordpress.org/secret-key/1.1/salt/"

# ----- options ----------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --webroot)
            if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then WP_DIR="$2"; shift 2
            else err "--webroot requires a path (e.g. --webroot /var/www/html)."; exit 1; fi
            ;;
        -h|--help)
            echo "Usage: sudo $(basename "$0") [--webroot PATH]"
            echo "  --webroot PATH   Install WordPress here (default: /var/www/html)."
            exit 0
            ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# ----- must be root -----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (sudo)."
    exit 1
fi

# ----- helpers ----------------------------------------------------------------
# Escape a value for a single-quoted SQL string literal (backslash + quote).
sql_esc(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }
# Escape a value for a single-quoted PHP string ( \ and ' ).
php_esc(){ local s=$1; s=${s//\\/\\\\}; s=${s//\'/\\\'}; printf '%s' "$s"; }
# Validate a MySQL identifier (db/user name): letters, digits, underscore only.
valid_ident(){ [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

prompt_secret(){ # var_name  prompt_text
    local __var="$1" __prompt="$2" __p1 __p2
    while true; do
        read -rsp "$__prompt: " __p1 < /dev/tty; echo
        if [ -z "$__p1" ]; then err "Password cannot be empty."; continue; fi
        read -rsp "Confirm $__prompt: " __p2 < /dev/tty; echo
        if [ "$__p1" != "$__p2" ]; then err "Passwords do not match, try again."; continue; fi
        printf -v "$__var" '%s' "$__p1"
        break
    done
}

# ==============================================================================
# 0. Gather inputs
# ==============================================================================
echo -e "${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}WORDPRESS + MARIADB PROVISIONER${NC}"
echo -e "${CYAN}======================================================================${NC}"

while true; do
    read -rp "WordPress database name to create: " DB_NAME < /dev/tty
    valid_ident "$DB_NAME" && break
    err "Use only letters, digits, and underscores (no spaces/quotes)."
done

while true; do
    read -rp "MariaDB username to create for this database: " DB_USER < /dev/tty
    if ! valid_ident "$DB_USER"; then err "Use only letters, digits, and underscores."; continue; fi
    [ "${#DB_USER}" -le 80 ] && break
    err "Username too long (max 80 characters)."
done

prompt_secret DB_PASS "Password for MariaDB user '${DB_USER}'"

echo
info "About to create database ${BOLD}${DB_NAME}${NC} and user ${BOLD}${DB_USER}@localhost${NC}."

# ==============================================================================
# 1. Connect to MariaDB as root (socket auth first; fall back to a password)
# ==============================================================================
ROOT_CMD=(mariadb)
if ! mariadb -u root -e 'SELECT 1' >/dev/null 2>&1; then
    warn "Root socket login unavailable; MariaDB root appears to already have a password."
    read -rsp "Current MariaDB root password: " CUR_ROOT < /dev/tty; echo
    ROOT_CMD=(mariadb -u root "-p${CUR_ROOT}")
    if ! "${ROOT_CMD[@]}" -e 'SELECT 1' >/dev/null 2>&1; then
        err "Could not authenticate to MariaDB as root. Aborting."
        exit 1
    fi
fi
root_sql(){ "${ROOT_CMD[@]}" -e "$1"; }

# Make sure MariaDB is actually running before we try to talk to it.
if ! systemctl is-active --quiet mariadb; then
    info "Starting MariaDB..."
    systemctl start mariadb || { err "MariaDB is not running and failed to start."; exit 1; }
fi

# ==============================================================================
# 2. Create database, user, and grant privileges
# ==============================================================================
info "Creating database and user..."
DB_PASS_SQL=$(sql_esc "$DB_PASS")
if ! root_sql "
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
"; then
    err "Failed to create the database/user. Aborting before touching root or WordPress."
    exit 1
fi
info "Database '${DB_NAME}' and user '${DB_USER}'@'localhost' ready."

# ==============================================================================
# 3. Root password + secure the server (local-only)
# ==============================================================================
hr
echo -e "${BOLD}Now securing MariaDB.${NC}"
prompt_secret ROOT_PASS "New password for the MariaDB 'root' user"
ROOT_PASS_SQL=$(sql_esc "$ROOT_PASS")

info "Removing anonymous users, remote root, and the test database..."
# Cleanup first (does NOT change root's own auth, so the socket session stays valid).
root_sql "
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
" || warn "Some cleanup statements did not apply (they may already be clean)."

info "Setting the root password..."
# Preferred: keep unix_socket for local convenience AND add a password.
if ! root_sql "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${ROOT_PASS_SQL}');" 2>/dev/null; then
    # Fallback for builds without dual-auth syntax: password-only.
    if ! root_sql "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS_SQL}';"; then
        warn "Could not set the root password automatically; set it manually with mariadb-secure-installation."
    else
        warn "Root now authenticates by PASSWORD only (socket login disabled). Use: mariadb -u root -p"
    fi
fi

# Restrict networking to localhost (idempotent drop-in; complements setup.sh).
BIND_CNF="/etc/mysql/mariadb.conf.d/61-local-only.cnf"
if [ -d /etc/mysql/mariadb.conf.d ]; then
    cat > "$BIND_CNF" <<'CNF'
# Provisioned by wordpress-provision.sh — restrict MariaDB to the local host.
[mysqld]
bind-address    = 127.0.0.1
skip-name-resolve
CNF
    info "Wrote ${BIND_CNF} (bind-address=127.0.0.1)."
fi

info "Restarting MariaDB to apply local-only networking..."
systemctl restart mariadb || warn "MariaDB restart reported an error — check 'systemctl status mariadb'."

# ==============================================================================
# 4. Download + install WordPress
# ==============================================================================
hr
info "Downloading the latest WordPress..."
TMP_WP="$(mktemp -d)"
trap 'rm -rf "$TMP_WP"' EXIT
if ! curl -fSL --retry 3 "$WP_TARBALL_URL" -o "$TMP_WP/wp.tar.gz"; then
    err "Failed to download WordPress from ${WP_TARBALL_URL}."
    exit 1
fi
tar -xzf "$TMP_WP/wp.tar.gz" -C "$TMP_WP"   # creates $TMP_WP/wordpress

if [ ! -f "$TMP_WP/wordpress/wp-settings.php" ]; then
    err "Downloaded archive does not look like WordPress. Aborting."
    exit 1
fi

mkdir -p "$WP_DIR"
if [ -f "$WP_DIR/wp-config.php" ]; then
    BK="$WP_DIR/wp-config.php.bak.$(date +%s)"
    warn "Existing wp-config.php found — backing it up to ${BK}"
    cp -a "$WP_DIR/wp-config.php" "$BK"
fi
info "Installing WordPress into ${WP_DIR}..."
cp -a "$TMP_WP/wordpress/." "$WP_DIR/"

# ==============================================================================
# 5. Generate wp-config.php
# ==============================================================================
info "Writing wp-config.php..."
DB_NAME_PHP=$(php_esc "$DB_NAME")
DB_USER_PHP=$(php_esc "$DB_USER")
DB_PASS_PHP=$(php_esc "$DB_PASS")

WP_CONFIG="$WP_DIR/wp-config.php"
{
    # --- header + DB credentials (expanded; values are PHP-escaped) ---
    cat <<PHP
<?php
/**
 * WordPress configuration generated by wordpress-provision.sh
 */

// ** Database settings ** //
define( 'DB_NAME', '${DB_NAME_PHP}' );
define( 'DB_USER', '${DB_USER_PHP}' );
define( 'DB_PASSWORD', '${DB_PASS_PHP}' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

PHP

    # --- authentication salts (raw bytes; no shell expansion) ---
    echo "// ** Authentication unique keys and salts ** //"
    if ! curl -fsS --retry 2 "$SALT_API" 2>/dev/null; then
        # Offline fallback: generate locally (strip ' and \ so PHP stays valid).
        for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
                 AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            v=$(openssl rand -base64 48 | tr -d "\n'\\\\")
            printf "define('%s', '%s');\n" "$k" "$v"
        done
    fi
    echo

    # --- table prefix, debug, ABSPATH, bootstrap ($ escaped for the here-doc) ---
    # The "That's all, stop editing!" line is the standard WordPress anchor that
    # WP-CLI's `wp config set` looks for to place new constants — keep it so tools
    # like harden-wordpress.sh / enable-redis-cache.sh work smoothly.
    cat <<PHP
\$table_prefix = 'wp_';

define( 'WP_DEBUG', false );

/* That's all, stop editing! Happy publishing. */

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
PHP
} > "$WP_CONFIG"

# ==============================================================================
# 6. Ownership + permissions
# ==============================================================================
info "Setting ownership and permissions (www-data)..."
chown -R www-data:www-data "$WP_DIR"
find "$WP_DIR" -type d -exec chmod 755 {} \;
find "$WP_DIR" -type f -exec chmod 644 {} \;
chmod 640 "$WP_CONFIG"

# ==============================================================================
# 7. Summary
# ==============================================================================
hr
echo -e "${GREEN}${BOLD}WordPress provisioned successfully.${NC}"
echo -e "  Database:   ${BOLD}${DB_NAME}${NC}"
echo -e "  DB user:    ${BOLD}${DB_USER}@localhost${NC} (full rights on ${DB_NAME})"
echo -e "  Webroot:    ${BOLD}${WP_DIR}${NC}"
echo -e "  wp-config:  ${BOLD}${WP_CONFIG}${NC}"
echo
echo -e "${BOLD}Next steps:${NC}"

# Only nag about the nginx root if it doesn't already point at this webroot.
NGINX_SITE="/etc/nginx/sites-available/wordpress"
if [ -f "$NGINX_SITE" ] && grep -qE "^[[:space:]]*root[[:space:]]+${WP_DIR}/?;" "$NGINX_SITE"; then
    echo -e "  1. nginx already serves ${BOLD}${WP_DIR}${NC} — no webroot change needed."
else
    echo -e "  1. Point nginx at this webroot (it currently serves a different path):"
    echo -e "       sudo sed -i 's#root .*;#root ${WP_DIR};#' ${NGINX_SITE}"
    echo -e "       sudo nginx -t && sudo systemctl reload nginx"
    echo -e "     ${YELLOW}Note:${NC} if the nginx AppArmor profile is enforced, a webroot outside"
    echo -e "     /var/www/html also needs matching read rules added to the profile."
fi
echo -e "  2. Load your domain in a browser to finish the WordPress install wizard."
echo -e "  3. MariaDB root now has the password you set; local root login: ${BOLD}sudo mariadb${NC} (or 'mariadb -u root -p')."
hr
