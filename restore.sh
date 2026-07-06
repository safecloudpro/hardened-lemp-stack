#!/usr/bin/env bash
# ==============================================================================
# Title: restore.sh
# Version: 1.0.0 (SafeCloud.PRO)
# Purpose: Restore a backup produced by backup.sh — the MariaDB database,
#          wp-content, and (optionally) wp-config.php.
#
#          Steps: decrypt if needed → unpack → show the manifest → CONFIRM →
#          import the database into the target → restore wp-content (and
#          wp-config.php unless --keep-config) → fix ownership/permissions.
#
#   sudo ./restore.sh --file /var/backups/safecloud/wpbackup-...tar.gz
#   sudo ./restore.sh --file backup.tar.gz.gpg --keep-config   # keep current DB creds
#
# The target DB credentials come from the CURRENT wp-config.php (or --db-*),
# so you can restore content into a freshly provisioned site without clobbering
# its database wiring — pass --keep-config to preserve the live wp-config.php.
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
ARCHIVE=""
PASSPHRASE="${BACKUP_PASSPHRASE:-}"
KEEP_CONFIG=false
ASSUME_YES=false
DB_NAME=""; DB_USER=""; DB_PASS=""; DB_HOST=""
NO_COLOR=false

show_help() {
    cat << EOF
Usage: sudo $(basename "$0") --file ARCHIVE [OPTIONS]

Restore a backup.sh archive (database + wp-content [+ wp-config.php]).

Options:
  --file ARCHIVE    The backup tarball (.tar.gz or .tar.gz.gpg). REQUIRED.
  --webroot PATH    WordPress install dir to restore into (default: ${WEBROOT}).
  --keep-config     Do NOT overwrite the live wp-config.php (keep current DB wiring).
  --passphrase STR  Passphrase for an encrypted archive (or BACKUP_PASSPHRASE; prompts).
  --db-name NAME    Override target DB name (else from live wp-config.php).
  --db-user USER    Override target DB user (else from live wp-config.php).
  --db-pass PASS    Override target DB password (else from live wp-config.php).
  -y, --yes         Skip the confirmation prompt.
  --no-color        Disable coloured output.
  -h, --help        Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --file)       ARCHIVE="${2:?}"; shift 2;;
        --webroot)    WEBROOT="${2:?}"; shift 2;;
        --keep-config) KEEP_CONFIG=true; shift;;
        --passphrase) PASSPHRASE="${2:?}"; shift 2;;
        --db-name)    DB_NAME="${2:?}"; shift 2;;
        --db-user)    DB_USER="${2:?}"; shift 2;;
        --db-pass)    DB_PASS="${2:?}"; shift 2;;
        -y|--yes)     ASSUME_YES=true; shift;;
        --no-color)   NO_COLOR=true; shift;;
        -h|--help)    show_help; exit 0;;
        *)            err "Unknown option: $1"; show_help; exit 1;;
    esac
done
if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''; fi

[ "$EUID" -eq 0 ] || { err "Must be run as root (sudo)."; exit 1; }
[ -n "$ARCHIVE" ] || { err "--file is required."; show_help; exit 1; }
[ -f "$ARCHIVE" ] || { err "Archive not found: ${ARCHIVE}"; exit 1; }
DBCLI=mariadb; command -v "$DBCLI" >/dev/null 2>&1 || DBCLI=mysql
command -v "$DBCLI" >/dev/null 2>&1 || { err "Neither mariadb nor mysql client is available."; exit 1; }

read_wpconfig() {
    local wpc="$1"
    command -v php >/dev/null 2>&1 || return 0
    # shellcheck disable=SC2016  # $argv is PHP, must NOT be shell-expanded
    php -r '
        $src = file_get_contents($argv[1]);
        $src = preg_replace("/require_once\s+ABSPATH.*wp-settings\.php.*;/", "", $src);
        if (!defined("ABSPATH")) define("ABSPATH", sys_get_temp_dir()."/");
        eval("?>".$src);
        printf("%s\n%s\n%s\n%s\n", DB_NAME, DB_USER, DB_PASSWORD, defined("DB_HOST")?DB_HOST:"localhost");
    ' "$wpc" 2>/dev/null
}

# ----- unpack -----------------------------------------------------------------
umask 077
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

echo -e "${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}SAFECLOUD.PRO RESTORE${NC}  ←  ${ARCHIVE}"
echo -e "${CYAN}======================================================================${NC}"

TARBALL="$ARCHIVE"
if [[ "$ARCHIVE" == *.gpg ]]; then
    command -v gpg >/dev/null 2>&1 || { err "Encrypted archive needs gpg."; exit 1; }
    [ -n "$PASSPHRASE" ] || { read -rsp "Decryption passphrase: " PASSPHRASE < /dev/tty; echo; }
    info "Decrypting..."
    if ! gpg --batch --yes --pinentry-mode loopback --passphrase "$PASSPHRASE" \
            -o "$STAGE/backup.tar.gz" -d "$ARCHIVE" 2>/dev/null; then
        err "Decryption failed (wrong passphrase?)."; exit 1
    fi
    TARBALL="$STAGE/backup.tar.gz"
fi

info "Unpacking archive..."
tar xzf "$TARBALL" -C "$STAGE" || { err "Failed to unpack archive."; exit 1; }
for need in database.sql wp-content.tar.gz; do
    [ -f "$STAGE/$need" ] || { err "Archive is missing ${need} — not a backup.sh tarball?"; exit 1; }
done

echo -e "${BOLD}Backup manifest:${NC}"
sed 's/^/    /' "$STAGE/MANIFEST.txt" 2>/dev/null || echo "    (no manifest)"

# ----- resolve target DB creds ------------------------------------------------
WPCONFIG="$WEBROOT/wp-config.php"
if { [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; } && [ -f "$WPCONFIG" ]; then
    mapfile -t _c < <(read_wpconfig "$WPCONFIG")
    DB_NAME="${DB_NAME:-${_c[0]:-}}"; DB_USER="${DB_USER:-${_c[1]:-}}"
    DB_PASS="${DB_PASS:-${_c[2]:-}}"; DB_HOST="${DB_HOST:-${_c[3]:-localhost}}"
fi
# Fall back to the backed-up wp-config's creds if we still don't have any.
if { [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; } && [ -f "$STAGE/wp-config.php" ]; then
    mapfile -t _c < <(read_wpconfig "$STAGE/wp-config.php")
    DB_NAME="${DB_NAME:-${_c[0]:-}}"; DB_USER="${DB_USER:-${_c[1]:-}}"
    DB_PASS="${DB_PASS:-${_c[2]:-}}"; DB_HOST="${DB_HOST:-${_c[3]:-localhost}}"
fi
[ -n "$DB_NAME" ] && [ -n "$DB_USER" ] || { err "Could not determine target DB credentials; pass --db-name/--db-user/--db-pass."; exit 1; }

echo
warn "This will OVERWRITE:"
echo -e "   • database ${BOLD}${DB_NAME}${NC} (import from backup)"
echo -e "   • ${BOLD}${WEBROOT}/wp-content${NC} (replaced from backup)"
[ "$KEEP_CONFIG" = "true" ] && echo -e "   • wp-config.php: ${BOLD}kept${NC} (current DB wiring preserved)" \
                            || echo -e "   • ${BOLD}${WEBROOT}/wp-config.php${NC} (replaced from backup)"
if [ "$ASSUME_YES" != "true" ]; then
    echo
    read -rp "Proceed with the restore? [y/N]: " c < /dev/tty
    case "${c:-n}" in [Yy]*) ;; *) info "Aborted. Nothing changed."; exit 0;; esac
fi

# ----- restore DB -------------------------------------------------------------
info "Importing database into '${DB_NAME}'..."
if ! "$DBCLI" -u "$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -h "$DB_HOST" "$DB_NAME" < "$STAGE/database.sql"; then
    err "Database import failed. wp-content/config NOT touched."; exit 1
fi
info "Database imported."

# ----- restore files ----------------------------------------------------------
info "Restoring wp-content..."
if [ -d "$WEBROOT/wp-content" ]; then
    mv "$WEBROOT/wp-content" "$WEBROOT/wp-content.pre-restore.$(date +%s)" 2>/dev/null || true
fi
tar xzf "$STAGE/wp-content.tar.gz" -C "$WEBROOT" || { err "Failed to extract wp-content."; exit 1; }

if [ "$KEEP_CONFIG" != "true" ] && [ -f "$STAGE/wp-config.php" ]; then
    [ -f "$WPCONFIG" ] && cp -a "$WPCONFIG" "${WPCONFIG}.pre-restore.$(date +%s)"
    cp -a "$STAGE/wp-config.php" "$WPCONFIG"
    info "wp-config.php restored from backup."
fi

# ----- ownership/permissions (match harden-wordpress defaults) ----------------
info "Fixing ownership/permissions on restored files..."
chown -R www-data:www-data "$WEBROOT/wp-content"
find "$WEBROOT/wp-content" -type d -exec chmod 755 {} +
find "$WEBROOT/wp-content" -type f -exec chmod 644 {} +
[ -f "$WPCONFIG" ] && chmod 640 "$WPCONFIG"

echo -e "${GREEN}${BOLD}Restore complete.${NC}"
echo -e "  The previous wp-content was kept alongside as ${BOLD}wp-content.pre-restore.*${NC} (delete once verified)."
echo -e "  Load the site in a browser to confirm, then run ${BOLD}sudo ./harden-wordpress.sh${NC} to re-assert hardening."
