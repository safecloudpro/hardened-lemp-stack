#!/usr/bin/env bash
# ==============================================================================
# Title: tune-stack.sh
# Version: 1.0.0 (SafeCloud.PRO)
# Purpose: Re-tune an already-installed hardened LEMP stack to the machine it is
#          running on. Four phases:
#            1. DETECT   — inventory installed + running/enabled services and
#                          their current tunable values.
#            2. CONFIRM  — show the findings and let the operator confirm which
#                          services to (re)tune.
#            3. SIZE     — read RAM/CPU and compute recommended values using the
#                          SAME math as setup.sh (lib/sizing.sh).
#            4. PROPOSE  — print a current-vs-proposed diff, then APPLY on
#                          approval (backup → write → validate → restart → verify,
#                          rolling back any service whose restart fails).
#
# Run as root:  sudo ./tune-stack.sh [OPTIONS]
# ==============================================================================

set -uo pipefail

# ----- appearance -------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi
info(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){  echo -e "${RED}[ERROR]${NC} $*" >&2; }
hr(){   echo -e "${CYAN}----------------------------------------------------------------------${NC}"; }

# ----- options ----------------------------------------------------------------
INTERACTIVE=true      # false with --yes: still shows the plan, applies without per-prompt
DRY_RUN=false         # true: propose only, never write
ASSUME_YES=false      # --yes
NO_COLOR=false
# Sizing overrides (mirror setup.sh; consumed by lib/sizing.sh via globals)
DB_POOL_SIZE="auto";     DB_POOL_FORCED=false
PHP_WORKERS=0;           PHP_WORKERS_FORCED=false
PHP_VERSION="auto"

show_help() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Re-tune an installed hardened LEMP stack to the host's current RAM/CPU.

Options:
  -y, --yes            Apply the proposed changes without the per-service prompt
                       (the plan is still printed first).
  -d, --dry-run        Detect, size, and print the proposed diff; change nothing.
  --db-pool SIZE       Pin the MariaDB InnoDB buffer pool (e.g. 2G, 512M).
  --php-workers NUM    Pin the static PHP-FPM worker count.
  --php-version VER    Target a specific PHP series (default: auto-detect).
  --no-color           Disable coloured output.
  -h, --help           Show this help and exit.

Default (no flags): interactive — shows findings, asks you to confirm, prints a
current-vs-proposed diff, and asks before applying. Every edited file is backed
up first and each service is validated + rolled back if its restart fails.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)        ASSUME_YES=true; INTERACTIVE=false; shift;;
        -d|--dry-run)    DRY_RUN=true; shift;;
        --db-pool)       [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]] || { err "--db-pool needs a value"; exit 1; }
                         DB_POOL_SIZE="$2"; DB_POOL_FORCED=true; shift 2;;
        --php-workers)   [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+$ ]] || { err "--php-workers needs an integer"; exit 1; }
                         PHP_WORKERS="$2"; PHP_WORKERS_FORCED=true; shift 2;;
        --php-version)   [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+\.[0-9]+$ ]] || { err "--php-version needs X.Y"; exit 1; }
                         PHP_VERSION="$2"; shift 2;;
        --no-color)      NO_COLOR=true; shift;;
        -h|--help)       show_help; exit 0;;
        *)               err "Unknown option: $1"; show_help; exit 1;;
    esac
done

if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# ----- preconditions ----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    err "Must be run as root (sudo) to read service configs and apply changes."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${SCRIPT_DIR}/lib/sizing.sh" ]; then
    # shellcheck source=lib/sizing.sh
    . "${SCRIPT_DIR}/lib/sizing.sh"
else
    err "Required library ${SCRIPT_DIR}/lib/sizing.sh is missing. Re-clone the repo."
    exit 1
fi

# Populated by compute_memory_budget():
RESERVED_SYS_MB=0; REDIS_MAXMEMORY_MB=0; DB_POOL_MB=0

# ----- small helpers ----------------------------------------------------------
is_installed(){ command -v "$1" &>/dev/null; }
svc_state(){ local out; out=$(systemctl is-active "$1" 2>/dev/null); echo "${out:-inactive}"; }
svc_enabled(){ local out; out=$(systemctl is-enabled "$1" 2>/dev/null); echo "${out:-disabled}"; }

detect_php_version() {
    if [ "$PHP_VERSION" != "auto" ]; then echo "$PHP_VERSION"; return; fi
    if is_installed php; then
        php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null
    fi
}

# ==============================================================================
# PHASE 1 — DETECT
# ==============================================================================
declare -A CUR       # current value per tunable key
declare -A NEW       # proposed value per tunable key
declare -A PRESENT   # service -> yes/no (installed)

echo -e "${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}SAFECLOUD.PRO STACK TUNING ADVISOR${NC}"
echo -e "  Re-sizes an installed LEMP stack to this host's RAM & CPU"
echo -e "${CYAN}======================================================================${NC}\n"

TOTAL_RAM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
PHPV=$(detect_php_version)

echo -e "${BLUE}[1/4] Detecting installed services and current configuration...${NC}"
printf "  %-16s | %-9s | %-9s | %s\n" "Service" "Installed" "Running" "Enabled"
echo   "  --------------------------------------------------------------"

detect_row() {
    local label="$1" bin="$2" unit="$3"
    if is_installed "$bin"; then
        PRESENT[$label]=yes
        printf "  %-16s | ${GREEN}%-9s${NC} | %-9s | %s\n" "$label" "yes" "$(svc_state "$unit")" "$(svc_enabled "$unit")"
    else
        PRESENT[$label]=no
        printf "  %-16s | ${YELLOW}%-9s${NC} | %-9s | %s\n" "$label" "no" "-" "-"
    fi
}

detect_row "nginx"     "nginx"                     "nginx"
detect_row "php-fpm"   "php"                       "php${PHPV}-fpm"
detect_row "mariadb"   "mariadb"                   "mariadb"
detect_row "redis"     "redis-server"              "redis-server"
detect_row "prometheus" "prometheus-node-exporter" "prometheus-node-exporter"
detect_row "fail2ban"  "fail2ban-client"           "fail2ban"

# ---- read current tunable values (best-effort; blank if unreadable) ----------
NGINX_CONF="/etc/nginx/nginx.conf"
if [ "${PRESENT[nginx]}" = yes ] && [ -f "$NGINX_CONF" ]; then
    CUR[nginx_worker_processes]=$(grep -oP '^\s*worker_processes\s+\K[^;]+' "$NGINX_CONF" | head -1)
    CUR[nginx_worker_connections]=$(grep -oP '^\s*worker_connections\s+\K[0-9]+' "$NGINX_CONF" | head -1)
fi

PHP_POOL="/etc/php/${PHPV}/fpm/pool.d/www.conf"
if [ "${PRESENT[php-fpm]}" = yes ] && [ -f "$PHP_POOL" ]; then
    CUR[php_max_children]=$(grep -oP '^\s*pm\.max_children\s*=\s*\K[0-9]+' "$PHP_POOL" | head -1)
fi
OPCACHE_INI="/etc/php/${PHPV}/mods-available/opcache.ini"
if [ "${PRESENT[php-fpm]}" = yes ] && [ -f "$OPCACHE_INI" ]; then
    CUR[opcache_mem]=$(grep -oP '^\s*opcache\.memory_consumption\s*=\s*\K[0-9]+' "$OPCACHE_INI" | head -1)
fi

if [ "${PRESENT[mariadb]}" = yes ]; then
    _dbc=mariadb; is_installed mariadb || _dbc=mysql
    _bytes=$("$_dbc" -N -s -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | awk '{print $2}' | head -1)
    if [[ "${_bytes:-}" =~ ^[0-9]+$ ]] && [ "${_bytes}" -gt 0 ]; then
        CUR[db_pool_mb]=$(( _bytes / 1024 / 1024 ))
    fi
fi

REDIS_CONF="/etc/redis/redis.conf"
if [ "${PRESENT[redis]}" = yes ] && [ -f "$REDIS_CONF" ]; then
    _rm=$(grep -oiP '^\s*maxmemory\s+\K[0-9a-z]+' "$REDIS_CONF" | head -1)
    case "${_rm,,}" in
        *gb) CUR[redis_maxmemory_mb]=$(( ${_rm%[gG][bB]} * 1024 ));;
        *mb) CUR[redis_maxmemory_mb]=${_rm%[mM][bB]};;
        *kb) CUR[redis_maxmemory_mb]=$(( ${_rm%[kK][bB]} / 1024 ));;
        ''|0) CUR[redis_maxmemory_mb]=0;;
        *)   CUR[redis_maxmemory_mb]=$(( _rm / 1024 / 1024 ));;
    esac
fi

echo
info "Host: ${BOLD}$(mb_to_gb "$TOTAL_RAM_MB") GB RAM${NC} / ${BOLD}${CPU_COUNT} vCPU${NC}   PHP: ${BOLD}${PHPV:-not detected}${NC}"

# ==============================================================================
# PHASE 2 — CONFIRM
# ==============================================================================
if [ "$INTERACTIVE" = true ] && [ "$DRY_RUN" != true ]; then
    echo
    read -rp "Proceed to analyse the detected services and compute new tuning? [Y/n]: " ans < /dev/tty
    case "${ans:-y}" in [Nn]*) info "No changes made."; exit 0;; esac
fi

# ==============================================================================
# PHASE 3 — SIZE (identical math to setup.sh)
# ==============================================================================
echo -e "\n${BLUE}[2/4] Sizing the machine and computing recommended values...${NC}"
compute_memory_budget "$TOTAL_RAM_MB"

# Derived service knobs from the RAM budget.
if   [ "$TOTAL_RAM_MB" -ge 8192 ]; then NEW_OPCACHE=512; NEW_WORKER_CONN=4096
elif [ "$TOTAL_RAM_MB" -ge 2048 ]; then NEW_OPCACHE=256; NEW_WORKER_CONN=2048
else                                    NEW_OPCACHE=128; NEW_WORKER_CONN=1024; fi

NEW[nginx_worker_processes]="auto"
NEW[nginx_worker_connections]="$NEW_WORKER_CONN"
NEW[php_max_children]="$PHP_WORKERS"
NEW[opcache_mem]="$NEW_OPCACHE"
NEW[db_pool_mb]="$DB_POOL_MB"
NEW[redis_maxmemory_mb]="$REDIS_MAXMEMORY_MB"

echo -e "  Reserved for OS/metrics: ${YELLOW}$(mb_to_gb "$RESERVED_SYS_MB") GB${NC}   Redis cap: ${YELLOW}$(mb_to_gb "$REDIS_MAXMEMORY_MB") GB${NC}   InnoDB: ${GREEN}$(mb_to_gb "$DB_POOL_MB") GB${NC}   PHP workers: ${GREEN}${PHP_WORKERS}${NC}"

# ==============================================================================
# PHASE 4 — PROPOSE (diff) then APPLY
# ==============================================================================
echo -e "\n${BLUE}[3/4] Proposed configuration changes${NC}"
hr
printf "  %-14s %-26s %-16s -> %-16s\n" "SERVICE" "SETTING" "CURRENT" "PROPOSED"
hr

CHANGES=0
row() { # label setting curval newval [unit]
    local label="$1" setting="$2" cur="$3" new="$4" unit="${5:-}"
    local cshow="${cur:-<unset>}${cur:+$unit}" nshow="${new}${unit}"
    if [ "${cur:-}" = "${new}" ]; then
        printf "  %-14s %-26s %-16s == %-16s\n" "$label" "$setting" "$cshow" "$nshow"
    else
        printf "  %-14s %-26s ${YELLOW}%-16s${NC} -> ${GREEN}%-16s${NC}\n" "$label" "$setting" "$cshow" "$nshow"
        CHANGES=$((CHANGES+1))
    fi
}

[ "${PRESENT[nginx]}" = yes ]   && row "nginx"   "worker_processes"        "${CUR[nginx_worker_processes]:-}"   "${NEW[nginx_worker_processes]}"
[ "${PRESENT[nginx]}" = yes ]   && row "nginx"   "worker_connections"      "${CUR[nginx_worker_connections]:-}" "${NEW[nginx_worker_connections]}"
[ "${PRESENT[php-fpm]}" = yes ] && row "php-fpm" "pm.max_children"         "${CUR[php_max_children]:-}"          "${NEW[php_max_children]}"
[ "${PRESENT[php-fpm]}" = yes ] && row "php-fpm" "opcache.memory (MB)"     "${CUR[opcache_mem]:-}"               "${NEW[opcache_mem]}"
[ "${PRESENT[mariadb]}" = yes ] && row "mariadb" "innodb_buffer_pool (MB)" "${CUR[db_pool_mb]:-}"                "${NEW[db_pool_mb]}"
[ "${PRESENT[redis]}" = yes ]   && row "redis"   "maxmemory (MB)"          "${CUR[redis_maxmemory_mb]:-}"        "${NEW[redis_maxmemory_mb]}"
hr

if [ "$CHANGES" -eq 0 ]; then
    info "Everything is already sized correctly for this host. Nothing to change."
    exit 0
fi
echo -e "  ${BOLD}${CHANGES}${NC} setting(s) differ from the recommended values."

if [ "$DRY_RUN" = true ]; then
    echo -e "\n${YELLOW}[DRY RUN] No files were modified.${NC}"
    exit 0
fi

if [ "$ASSUME_YES" != true ]; then
    echo
    read -rp "Apply these changes now (each service is backed up + rolled back on failure)? [y/N]: " ap < /dev/tty
    case "${ap:-n}" in [Yy]*) ;; *) info "No changes applied."; exit 0;; esac
fi

# ----- apply helpers ----------------------------------------------------------
BACKUP_STAMP=$(date +%s)
backup_file(){ [ -f "$1" ] && cp -a "$1" "$1.bak.${BACKUP_STAMP}" && echo "    backed up $1 -> $1.bak.${BACKUP_STAMP}"; }
restore_file(){ [ -f "$1.bak.${BACKUP_STAMP}" ] && cp -a "$1.bak.${BACKUP_STAMP}" "$1"; }

echo -e "\n${BLUE}[4/4] Applying...${NC}"
FAILED=0

# --- nginx ---
if [ "${PRESENT[nginx]}" = yes ] && [ -f "$NGINX_CONF" ]; then
    if [ "${CUR[nginx_worker_connections]:-}" != "${NEW[nginx_worker_connections]}" ] \
       || [ "${CUR[nginx_worker_processes]:-}" != "auto" ]; then
        info "nginx: worker_processes=auto, worker_connections=${NEW[nginx_worker_connections]}"
        backup_file "$NGINX_CONF"
        sed -i -E "s/^(\s*)worker_processes\s+[^;]+;/\1worker_processes auto;/" "$NGINX_CONF"
        sed -i -E "s/^(\s*)worker_connections\s+[0-9]+;/\1worker_connections ${NEW[nginx_worker_connections]};/" "$NGINX_CONF"
        if nginx -t &>/dev/null && systemctl reload nginx; then
            info "nginx reloaded."
        else
            err "nginx failed validation/reload — rolling back."; restore_file "$NGINX_CONF"
            nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
            FAILED=$((FAILED+1))
        fi
    fi
fi

# --- php-fpm pool + opcache ---
if [ "${PRESENT[php-fpm]}" = yes ] && [ -n "${PHPV}" ]; then
    _php_changed=false
    if [ -f "$PHP_POOL" ] && [ "${CUR[php_max_children]:-}" != "${NEW[php_max_children]}" ]; then
        info "php-fpm: pm.max_children=${NEW[php_max_children]}"
        backup_file "$PHP_POOL"
        sed -i -E "s/^(\s*pm\.max_children\s*=\s*)[0-9]+/\1${NEW[php_max_children]}/" "$PHP_POOL"
        _php_changed=true
    fi
    if [ -f "$OPCACHE_INI" ] && [ "${CUR[opcache_mem]:-}" != "${NEW[opcache_mem]}" ]; then
        info "php-fpm: opcache.memory_consumption=${NEW[opcache_mem]}"
        backup_file "$OPCACHE_INI"
        sed -i -E "s/^(\s*opcache\.memory_consumption\s*=\s*)[0-9]+/\1${NEW[opcache_mem]}/" "$OPCACHE_INI"
        _php_changed=true
    fi
    if [ "$_php_changed" = true ]; then
        if "php-fpm${PHPV}" -t &>/dev/null && systemctl restart "php${PHPV}-fpm"; then
            info "php${PHPV}-fpm restarted."
        else
            err "php-fpm failed validation/restart — rolling back."
            restore_file "$PHP_POOL"; restore_file "$OPCACHE_INI"
            systemctl restart "php${PHPV}-fpm" 2>/dev/null || true
            FAILED=$((FAILED+1))
        fi
    fi
fi

# --- mariadb ---
if [ "${PRESENT[mariadb]}" = yes ] && [ "${CUR[db_pool_mb]:-}" != "${NEW[db_pool_mb]}" ]; then
    info "mariadb: innodb_buffer_pool_size=${NEW[db_pool_mb]}M"
    DROPIN="/etc/mysql/mariadb.conf.d/60-safecloud-hardening.cnf"
    if [ -f "$DROPIN" ] && grep -q 'innodb_buffer_pool_size' "$DROPIN"; then
        backup_file "$DROPIN"
        sed -i -E "s/^(\s*innodb_buffer_pool_size\s*=\s*).*/\1${NEW[db_pool_mb]}M/" "$DROPIN"
    else
        DROPIN="/etc/mysql/mariadb.conf.d/62-safecloud-tuning.cnf"
        backup_file "$DROPIN"
        printf '# Written by tune-stack.sh\n[mysqld]\ninnodb_buffer_pool_size = %sM\n' "${NEW[db_pool_mb]}" > "$DROPIN"
    fi
    systemctl reset-failed mariadb 2>/dev/null || true
    if systemctl restart mariadb && systemctl is-active --quiet mariadb; then
        info "mariadb restarted."
    else
        err "mariadb failed to restart — rolling back."; restore_file "$DROPIN"
        systemctl restart mariadb 2>/dev/null || true
        FAILED=$((FAILED+1))
    fi
fi

# --- redis ---
if [ "${PRESENT[redis]}" = yes ] && [ -f "$REDIS_CONF" ] && [ "${CUR[redis_maxmemory_mb]:-}" != "${NEW[redis_maxmemory_mb]}" ]; then
    info "redis: maxmemory=${NEW[redis_maxmemory_mb]}mb"
    backup_file "$REDIS_CONF"
    sed -i -E "s/^(\s*)maxmemory\s+.*/\1maxmemory ${NEW[redis_maxmemory_mb]}mb/" "$REDIS_CONF"
    if systemctl restart redis-server && systemctl is-active --quiet redis-server; then
        info "redis-server restarted."
    else
        err "redis failed to restart — rolling back."; restore_file "$REDIS_CONF"
        systemctl restart redis-server 2>/dev/null || true
        FAILED=$((FAILED+1))
    fi
fi

hr
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}Tuning applied successfully.${NC} Backups saved with suffix .bak.${BACKUP_STAMP}"
else
    echo -e "${RED}${BOLD}Tuning finished with ${FAILED} rolled-back service(s).${NC} Review the errors above."
    exit 1
fi
