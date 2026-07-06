#!/usr/bin/env bash
# ==============================================================================
# Title: backup.sh
# Version: 1.0.0 (SafeCloud.PRO)
# Purpose: Consistent, restorable backup of a WordPress site on the hardened
#          stack — the irreplaceable parts: the MariaDB database, wp-content,
#          and wp-config.php (WordPress core is re-downloadable, so it's skipped).
#
#          Steps: read DB creds from wp-config.php → dump the DB
#          (--single-transaction, no table locks) → archive wp-content +
#          wp-config.php → bundle into one timestamped tarball → optionally
#          encrypt (gpg symmetric) → prune old local backups → optionally push
#          to S3.
#
#   sudo ./backup.sh                                  # /var/backups/safecloud/...
#   sudo ./backup.sh --encrypt --keep 14              # encrypted, keep 14 newest
#   sudo ./backup.sh --s3 s3://my-bucket/wp-backups   # also upload to S3
#
# Pair with a cron entry for daily backups (see monitoring/README.md).
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

# ----- defaults ---------------------------------------------------------------
WEBROOT="${WEBROOT:-/var/www/html}"
DEST="${BACKUP_DEST:-/var/backups/safecloud}"
KEEP=7
ENCRYPT=false
PASSPHRASE="${BACKUP_PASSPHRASE:-}"
S3_URI=""
DB_NAME=""; DB_USER=""; DB_PASS=""; DB_HOST=""
NO_COLOR=false

show_help() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Back up the WordPress database + wp-content + wp-config.php into one tarball.

Options:
  --webroot PATH    WordPress install dir (default: ${WEBROOT}).
  --dest DIR        Where to write backups (default: ${DEST}).
  --keep N          Keep only the N newest local backups (default: ${KEEP}; 0 = keep all).
  --encrypt         Encrypt the tarball with gpg symmetric (AES256).
  --passphrase STR  Passphrase for --encrypt (or set BACKUP_PASSPHRASE; prompts if neither).
  --s3 S3URI        Also upload the finished archive (e.g. s3://bucket/prefix) via aws-cli.
  --db-name NAME    Override DB name (else read from wp-config.php).
  --db-user USER    Override DB user (else read from wp-config.php).
  --db-pass PASS    Override DB password (else read from wp-config.php).
  --no-color        Disable coloured output.
  -h, --help        Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --webroot)    WEBROOT="${2:?}"; shift 2;;
        --dest)       DEST="${2:?}"; shift 2;;
        --keep)       KEEP="${2:?}"; shift 2;;
        --encrypt)    ENCRYPT=true; shift;;
        --passphrase) PASSPHRASE="${2:?}"; shift 2;;
        --s3)         S3_URI="${2:?}"; shift 2;;
        --db-name)    DB_NAME="${2:?}"; shift 2;;
        --db-user)    DB_USER="${2:?}"; shift 2;;
        --db-pass)    DB_PASS="${2:?}"; shift 2;;
        --no-color)   NO_COLOR=true; shift;;
        -h|--help)    show_help; exit 0;;
        *)            err "Unknown option: $1"; show_help; exit 1;;
    esac
done
if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''; fi
[[ "$KEEP" =~ ^[0-9]+$ ]] || { err "--keep must be an integer."; exit 1; }

# ----- preconditions ----------------------------------------------------------
[ "$EUID" -eq 0 ] || { err "Must be run as root (sudo) to read wp-config.php and the DB socket."; exit 1; }
WPCONFIG="$WEBROOT/wp-config.php"
[ -f "$WPCONFIG" ] || { err "wp-config.php not found at ${WPCONFIG}. Set --webroot."; exit 1; }
DUMP=mariadb-dump; command -v "$DUMP" >/dev/null 2>&1 || DUMP=mysqldump
command -v "$DUMP" >/dev/null 2>&1 || { err "Neither mariadb-dump nor mysqldump is available."; exit 1; }

# ----- read DB creds from wp-config.php (unless overridden) --------------------
# Evaluate ONLY the constant defines — the wp-settings bootstrap line is stripped
# so nothing actually loads WordPress. Robust to escaped quotes in passwords.
read_wpconfig() {
    if command -v php >/dev/null 2>&1; then
        # shellcheck disable=SC2016  # $argv is PHP, must NOT be shell-expanded
        php -r '
            $src = file_get_contents($argv[1]);
            $src = preg_replace("/require_once\s+ABSPATH.*wp-settings\.php.*;/", "", $src);
            if (!defined("ABSPATH")) define("ABSPATH", sys_get_temp_dir()."/");
            eval("?>".$src);
            printf("%s\n%s\n%s\n%s\n", DB_NAME, DB_USER, DB_PASSWORD, defined("DB_HOST")?DB_HOST:"localhost");
        ' "$WPCONFIG" 2>/dev/null
    fi
}
if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
    mapfile -t _c < <(read_wpconfig)
    DB_NAME="${DB_NAME:-${_c[0]:-}}"
    DB_USER="${DB_USER:-${_c[1]:-}}"
    DB_PASS="${DB_PASS:-${_c[2]:-}}"
    DB_HOST="${DB_HOST:-${_c[3]:-localhost}}"
fi
[ -n "$DB_NAME" ] && [ -n "$DB_USER" ] || { err "Could not determine DB credentials from ${WPCONFIG}; pass --db-name/--db-user/--db-pass."; exit 1; }

if [ "$ENCRYPT" = "true" ]; then
    command -v gpg >/dev/null 2>&1 || { err "--encrypt needs gpg (apt-get install -y gnupg)."; exit 1; }
    if [ -z "$PASSPHRASE" ]; then
        read -rsp "Encryption passphrase: " PASSPHRASE < /dev/tty; echo
        [ -n "$PASSPHRASE" ] || { err "Empty passphrase."; exit 1; }
    fi
fi

# ----- do the backup ----------------------------------------------------------
umask 077
mkdir -p "$DEST"
STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$(hostname -s 2>/dev/null || echo host)
BASE="wpbackup-${HOST}-${STAMP}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

echo -e "${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}SAFECLOUD.PRO BACKUP${NC}  →  ${DEST}/${BASE}.tar.gz$([ "$ENCRYPT" = true ] && echo .gpg)"
echo -e "${CYAN}======================================================================${NC}"

info "Dumping database '${DB_NAME}'..."
if ! "$DUMP" --single-transaction --quick --routines --triggers --events \
        -u "$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -h "$DB_HOST" "$DB_NAME" > "$STAGE/database.sql" 2>"$STAGE/dump.err"; then
    err "Database dump failed:"; sed 's/^/    /' "$STAGE/dump.err" >&2; exit 1
fi
info "Database dumped ($(du -h "$STAGE/database.sql" | cut -f1))."

info "Archiving wp-content and wp-config.php..."
tar czf "$STAGE/wp-content.tar.gz" -C "$WEBROOT" wp-content 2>/dev/null || { err "Failed to archive wp-content."; exit 1; }
cp -a "$WPCONFIG" "$STAGE/wp-config.php"

{
    echo "site_host=$HOST"
    echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "webroot=$WEBROOT"
    echo "db_name=$DB_NAME"
    echo "db_user=$DB_USER"
    echo "dump_tool=$DUMP"
} > "$STAGE/MANIFEST.txt"

ARCHIVE="${DEST}/${BASE}.tar.gz"
tar czf "$ARCHIVE" -C "$STAGE" database.sql wp-content.tar.gz wp-config.php MANIFEST.txt
info "Bundled archive: ${BOLD}${ARCHIVE}${NC} ($(du -h "$ARCHIVE" | cut -f1))."

if [ "$ENCRYPT" = "true" ]; then
    gpg --batch --yes --pinentry-mode loopback --passphrase "$PASSPHRASE" \
        --symmetric --cipher-algo AES256 -o "${ARCHIVE}.gpg" "$ARCHIVE" \
        && rm -f "$ARCHIVE" && ARCHIVE="${ARCHIVE}.gpg"
    info "Encrypted → ${BOLD}${ARCHIVE}${NC}"
fi

# ----- retention --------------------------------------------------------------
if [ "$KEEP" -gt 0 ]; then
    # Sort our own timestamped backups newest-first; names are controlled (no spaces).
    # shellcheck disable=SC2012
    mapfile -t OLD < <(ls -1t "${DEST}"/wpbackup-*.tar.gz* 2>/dev/null | tail -n +$((KEEP + 1)))
    if [ "${#OLD[@]}" -gt 0 ]; then
        info "Pruning ${#OLD[@]} old backup(s) (keeping ${KEEP} newest)..."
        for f in "${OLD[@]}"; do rm -f "$f" && echo "    removed $(basename "$f")"; done
    fi
fi

# ----- optional S3 upload -----------------------------------------------------
if [ -n "$S3_URI" ]; then
    if command -v aws >/dev/null 2>&1; then
        info "Uploading to ${S3_URI%/}/$(basename "$ARCHIVE")..."
        if aws s3 cp "$ARCHIVE" "${S3_URI%/}/$(basename "$ARCHIVE")"; then
            info "Uploaded to S3."
        else
            warn "S3 upload failed (archive is still saved locally)."
        fi
    else
        warn "aws CLI not installed — skipped S3 upload (archive saved locally)."
    fi
fi

echo -e "${GREEN}${BOLD}Backup complete.${NC}  Restore with: ${BOLD}sudo ./restore.sh --file ${ARCHIVE}${NC}"
