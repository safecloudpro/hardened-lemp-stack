#!/usr/bin/env bash
# ==============================================================================
# Title: secure-lemp-setup.sh
# Version: 3.3.1 (LTS Hardened Flag-Driven with AppArmor)
# Description: Production-grade security hardening and optimization script
#              for WordPress/WooCommerce on Ubuntu 26.04 LTS (Graviton/ARM64).
# Target Instance: AWS t4g.xlarge (4 vCPUs, 16 GB RAM)
# =============================================================================
# This script operates in dual modes:
#   1. Interactive (Default): Explains each component and prompts for approval.
#   2. Headless (-y/--yes): Automatic, non-interactive execution for automated CI/CD.
# ==============================================================================

set -uo pipefail

# ANSI color codes (disabled if stdout is not a TTY or --no-color is set)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default Configuration Variables
INTERACTIVE=true
DRY_RUN=false
DB_POOL_SIZE="auto"  # auto-sized from detected RAM unless --db-pool is passed
DB_POOL_FORCED=false # true when the user pins a pool size with --db-pool
PHP_WORKERS=0        # 0 = auto-size from detected RAM unless --php-workers is passed
PHP_WORKERS_FORCED=false # true when the user pins a worker count with --php-workers
PHP_VERSION="auto"   # resolved from the distro's APT repos unless --php-version is passed
PHP_VERSION_FORCED=false  # true when the user pins a version with --php-version
# Populated by compute_memory_budget() from detected RAM:
RESERVED_SYS_MB=0
REDIS_MAXMEMORY_MB=0
DB_POOL_MB=0
INSTALL_EXPORTERS=true
SKIP_TUNE=false      # true with --no-tune: skip the post-install tuning advisor
CONFIGURE_SG=false   # true with --configure-sg: run the Cloudflare→EC2 SG step in headless mode
FULL_UPGRADE=false   # headless opt-in (--full-upgrade); interactive always asks
INSTALL_WPCLI=false  # headless opt-in (--wp-cli); interactive always asks
NO_COLOR=false
INSTALL_LOG_FILE="/var/log/lemp_interactive_install.log"
LOCAL_LOG_FILE="./installation_choices.log"

# Component list and description arrays
COMPONENTS=(
    "system-updates"
    "nginx-http3"
    "nginx-apparmor"
    "php-opcache"
    "php-apparmor"
    "redis-cache"
    "redis-apparmor"
    "mariadb"
    "mariadb-apparmor"
    "prometheus-exporter"
)

declare -A COMP_NAMES=(
    ["system-updates"]="System Updates & UFW Firewall"
    ["nginx-http3"]="Nginx Web Server with HTTP/3 & Cloudflare AOP"
    ["nginx-apparmor"]="Nginx AppArmor Profile Containment"
    ["php-opcache"]="PHP-FPM & OPcache Hardening"
    ["php-apparmor"]="PHP-FPM AppArmor Profile Containment"
    ["redis-cache"]="Redis Object Cache (Unix-Socket Only)"
    ["redis-apparmor"]="Redis AppArmor Profile Containment"
    ["mariadb"]="MariaDB 11.x Database Hardening"
    ["mariadb-apparmor"]="MariaDB AppArmor Profile Containment"
    ["prometheus-exporter"]="Prometheus Exporter Local Isolation"
)

declare -A COMP_DESCS=(
    ["system-updates"]="Upgrades all OS packages, activates automated unattended security patches, installs fail2ban, and configures the UFW firewall to block all incoming traffic except SSH (22), HTTP (80), and HTTP/3 QUIC (443 TCP/UDP)."
    ["nginx-http3"]="Installs Nginx with HTTP/3 support. Downloads the Cloudflare Authenticated Origin Pulls (AOP) CA cert to cryptographically block all requests not originating from Cloudflare's Edge. Enforces secure HTTP headers and blocks direct execution of PHP files in media upload directories."
    ["nginx-apparmor"]="Deploys a mandatory access control AppArmor profile to confine the Nginx daemon to strict read-only access on webroots, restrict process execution, limit socket traffic, and protect private SSL/TLS certificate directories."
    ["php-opcache"]="Installs PHP-FPM and tunes it. It sets up a highly reliable STATIC worker pool of children to eliminate CPU spawning spikes and prevent Out-Of-Memory (OOM) crashes on 16GB systems. It hardens OPcache memory permissions to block cross-pool sensitive database leaks, and enables CLI OPcache caching for fast WP-CLI crons."
    ["php-apparmor"]="Deploys a mandatory access control AppArmor profile confining every PHP-FPM worker to its socket, upload staging, and outbound API needs — blocking shell spawns and writes into WordPress core/plugin/theme code even from a compromised plugin."
    ["redis-cache"]="Installs Redis as a WordPress object cache, bound exclusively to a local Unix domain socket (TCP port disabled entirely). Disables disk persistence for a pure in-memory cache role, caps memory at 1 GB with LRU eviction, and grants the web user socket access."
    ["redis-apparmor"]="Deploys a mandatory access control AppArmor profile confining Redis to its data directory and Unix socket, and attaches it via a systemd drop-in (Ubuntu's redis-server.service sets NoNewPrivileges=true, which otherwise leaves Redis unconfined)."
    ["mariadb"]="Installs MariaDB and locks it down to localhost (127.0.0.1) to disable external network attacks. Allocates an optimized InnoDB buffer pool to host your WordPress database comfortably in-memory, while leaving ample system RAM headroom for expansion."
    ["mariadb-apparmor"]="Deploys a mandatory access control AppArmor profile confining MariaDB to its data directory, denying every execution path on the system (neutralizing SQL-injection→file-write→execute chains). Disables Ubuntu's own generic mariadbd profile first, since two profiles claiming the same binary path leave the kernel confining neither."
    ["prometheus-exporter"]="Installs the Prometheus node_exporter to gather server telemetry metrics and binds it strictly to 127.0.0.1:9100. This isolates monitoring data locally, making it inaccessible to the public network or internal VPC subnets unless accessed via secure SSH local forwarding tunnels."
)

declare -A LOG_CHOICES
declare -A COMP_STATUS
declare -A COMP_VERSIONS

print_header() {
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "  ${BOLD}INTERACTIVE HARDENED LEMP STACK PROVISIONER (UBUNTU 26.04 LTS)${NC}"
    echo -e "  Tailored for AWS t4g.xlarge | Memory-Optimized for WordPress/WooCommerce"
    echo -e "${CYAN}======================================================================${NC}"
}

# Print usage instructions
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Production-grade secure LEMP stack deployment script for Ubuntu 26.04 LTS.

Options:
  -i, --interactive       Prompt for each component, explaining its purpose (Default)
  -y, --yes               Non-interactive mode, automatically install all components
  -d, --dry-run           Perform resource budget checks, print configuration plan, and exit
  --db-pool SIZE          Override MariaDB InnoDB Buffer Pool size (e.g., 1.5G, 2G, 512M) (Default: auto-size from RAM)
  --php-workers NUM       Override static PHP-FPM max_children count (Default: auto-size from RAM)
  --php-version VER       Force a specific PHP version (e.g., 8.4, 8.5) (Default: auto-detect from APT)
  --exclude-exporters     Do not install or configure Prometheus exporters
  --full-upgrade          Headless: upgrade all system packages to latest before installing
                          (interactive mode always asks). Idempotent.
  --wp-cli                Headless: install WP-CLI to /usr/local/bin/wp
                          (interactive mode always asks). Idempotent.
  --no-tune               Skip the post-install fine-tuning advisor (tune-stack.sh)
  --configure-sg          In headless mode, also generate the Cloudflare→EC2 Security
                          Group commands (interactive mode always offers it)
  --no-color              Disable colored terminal output
  -h, --help              Show this help menu and exit

By default every memory setting (system reserve, Redis cap, InnoDB pool, PHP
worker count) is derived from the RAM this host actually has, so the same script
is safe on a 1 GB box and a 16 GB box. --db-pool / --php-workers pin a value.

Examples:
  sudo ./setup.sh -y                      # fully auto-sized
  sudo ./setup.sh -y --db-pool 4G         # pin the DB pool, auto-size the rest
  sudo ./setup.sh --dry-run               # show the sizing plan and exit
EOF
}

# Parse options
parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            -y|--yes|--non-interactive)
                INTERACTIVE=false
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --db-pool)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    DB_POOL_SIZE="$2"
                    DB_POOL_FORCED=true
                    shift 2
                else
                    echo -e "${RED}[ERROR] --db-pool requires a value (e.g., 1.5G, 512M).${NC}" >&2
                    exit 1
                fi
                ;;
            --php-workers)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    PHP_WORKERS="$2"
                    PHP_WORKERS_FORCED=true
                    shift 2
                else
                    echo -e "${RED}[ERROR] --php-workers requires a valid integer value.${NC}" >&2
                    exit 1
                fi
                ;;
            --php-version)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    PHP_VERSION="$2"
                    PHP_VERSION_FORCED=true
                    shift 2
                else
                    echo -e "${RED}[ERROR] --php-version requires a value (e.g., 8.3, 8.4, 8.5).${NC}" >&2
                    exit 1
                fi
                ;;
            --exclude-exporters)
                INSTALL_EXPORTERS=false
                shift
                ;;
            --no-tune)
                SKIP_TUNE=true
                shift
                ;;
            --configure-sg)
                CONFIGURE_SG=true
                shift
                ;;
            --full-upgrade)
                FULL_UPGRADE=true
                shift
                ;;
            --wp-cli)
                INSTALL_WPCLI=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR] Unknown option: $1${NC}" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

disable_colors() {
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
}

# Shared memory-budget math lives in lib/sizing.sh so that setup.sh and
# tune-stack.sh always reach identical numbers for the same RAM. Source it
# relative to THIS script's location (works regardless of the caller's CWD).
_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${_SETUP_DIR}/lib/sizing.sh" ]; then
    # shellcheck source=lib/sizing.sh
    . "${_SETUP_DIR}/lib/sizing.sh"
else
    echo -e "${RED}[ERROR] Required library ${_SETUP_DIR}/lib/sizing.sh is missing. Re-clone the repository so lib/ is present.${NC}" >&2
    exit 1
fi

# Resolve the PHP minor version actually shipped by this Ubuntu release.
# Hardcoding (e.g. 8.4) breaks on releases that ship a different series —
# Ubuntu 26.04's archive carries PHP 8.5, so "php8.4-fpm" simply doesn't exist.
resolve_php_version() {
    if [ "$PHP_VERSION" != "auto" ]; then
        return 0
    fi
    local detected
    detected=$(apt-cache depends php-fpm 2>/dev/null | grep -oE 'php[0-9]+\.[0-9]+-fpm' | head -n 1 | grep -oE '[0-9]+\.[0-9]+' || true)
    if [ -z "$detected" ]; then
        detected=$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | sort -V | tail -n 1 || true)
    fi
    if [ -z "$detected" ]; then
        # Provisional only — the APT index may not be populated yet. The
        # authoritative resolution runs as root after 'apt-get update' and will
        # correct this before any component uses it.
        echo -e "${YELLOW}[NOTE] PHP version not yet detectable from APT; will resolve after the index refresh.${NC}"
        detected="8.5"
    fi
    PHP_VERSION="$detected"
}

# Core memory checking and planning logic
evaluate_system_plan() {
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "  ${BOLD}INFRASTRUCTURE SIZING & RESOURCE BUDGET ALLOCATION${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    
    local total_ram_kb
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_mb=$((total_ram_kb / 1024))

    # Derive every memory setting from the RAM this host actually has.
    compute_memory_budget "$total_ram_mb"

    local php_alloc_mb=$(( total_ram_mb - RESERVED_SYS_MB - REDIS_MAXMEMORY_MB - DB_POOL_MB ))

    echo -e " Detected Physical RAM:  ${BOLD}$(mb_to_gb "$total_ram_mb") GB${NC} (${total_ram_mb} MB)"
    echo -e " Running PHP Version:    ${BOLD}PHP ${PHP_VERSION}${NC}"
    echo -e " InnoDB Buffer Pool:     ${BOLD}$(mb_to_gb "$DB_POOL_MB") GB${NC}$( [ "$DB_POOL_FORCED" = true ] && echo ' (pinned)' || echo ' (auto)')"
    echo -e " Static PHP-FPM Workers: ${BOLD}${PHP_WORKERS} children${NC}$( [ "$PHP_WORKERS_FORCED" = true ] && echo ' (pinned)' || echo ' (auto)')"

    echo -e "\n ${BOLD}[ADAPTIVE MEMORY MAP PLAN]${NC} (auto-sized to detected RAM)"
    echo -e "  - Reserved for System Host / Metrics:  ${YELLOW}$(mb_to_gb "$RESERVED_SYS_MB") GB${NC}"
    echo -e "  - Reserved for Redis Object Cache:     ${YELLOW}$(mb_to_gb "$REDIS_MAXMEMORY_MB") GB${NC}"
    echo -e "  - Allocated to MariaDB Buffer Pool:    ${GREEN}$(mb_to_gb "$DB_POOL_MB") GB${NC}"
    echo -e "  - Available Headroom for PHP-FPM:      ${GREEN}$(mb_to_gb "$php_alloc_mb") GB${NC}"

    local max_safe_workers=$(( php_alloc_mb > 0 ? php_alloc_mb / 50 : 0 ))
    if [ "$php_alloc_mb" -lt 128 ]; then
        echo -e "${RED}[WARNING] Very low memory left for PHP-FPM after reserves. This host may be too small for the full stack.${NC}"
    elif [ "$PHP_WORKERS_FORCED" = "true" ] && [ "$PHP_WORKERS" -gt "$max_safe_workers" ]; then
        echo -e "  ${RED}[DANGER] Pinned php-workers (${PHP_WORKERS}) exceeds the safe maximum (${max_safe_workers}) for this RAM — OOM risk under load.${NC}"
    else
        echo -e "  - Configuration Safety Verification:   ${GREEN}PASS (workers sized to fit RAM)${NC}"
    fi
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

# Prompt user for installation choices
prompt_install() {
    local comp="$1"
    local name="${COMP_NAMES[$comp]}"
    local desc="${COMP_DESCS[$comp]}"
    
    # Adjust descriptions if variables have been customized
    if [ "$comp" = "php-opcache" ]; then
        desc="${desc/children/(${PHP_WORKERS} static children)}"
    elif [ "$comp" = "mariadb" ]; then
        desc="${desc/optimized/optimized (${DB_POOL_SIZE})}"
    fi

    echo -e "\n${BLUE}----------------------------------------------------------------------${NC}"
    echo -e "${BOLD}Component:${NC} ${CYAN}${name}${NC}"
    echo -e "${BOLD}Purpose:${NC}\n${desc}"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    
    if [ "$INTERACTIVE" = "true" ]; then
        while true; do
            read -rp "Install and configure ${name}? [y/n]: " yn < /dev/tty
            case $yn in
                [Yy]* ) 
                    LOG_CHOICES["$comp"]="ACCEPTED"
                    return 0
                    ;;
                [Nn]* ) 
                    LOG_CHOICES["$comp"]="SKIPPED"
                    return 1
                    ;;
                * ) echo -e "${RED}Please answer 'y' (yes) or 'n' (no).${NC}";;
            esac
        done
    else
        LOG_CHOICES["$comp"]="ACCEPTED"
        return 0
    fi
}

verify_service_status() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "SUCCESS"
    else
        echo "FAILED (Not Active)"
    fi
}

# Offer the detect → size → propose → apply tuning pass once the stack is up.
# setup.sh already sizes the memory-critical services during install; the advisor
# additionally scales secondary knobs (nginx worker_connections, OPcache memory)
# to this host and re-confirms every value. Any --db-pool / --php-workers pin is
# forwarded so the advisor never overwrites a value the operator deliberately set.
run_post_install_tuning() {
    [ "$SKIP_TUNE" = "true" ] && return 0
    local tuner="${_SETUP_DIR}/tune-stack.sh"
    [ -f "$tuner" ] || { echo -e "${YELLOW}[NOTE] tune-stack.sh not found next to setup.sh; skipping the tuning advisor.${NC}"; return 0; }

    local tuner_args=()
    [ "$NO_COLOR" = "true" ]          && tuner_args+=(--no-color)
    [ "$DB_POOL_FORCED" = "true" ]    && tuner_args+=(--db-pool "$DB_POOL_SIZE")
    [ "$PHP_WORKERS_FORCED" = "true" ] && tuner_args+=(--php-workers "$PHP_WORKERS")
    [ "$PHP_VERSION" != "auto" ]      && tuner_args+=(--php-version "$PHP_VERSION")

    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "  ${BOLD}POST-INSTALL FINE-TUNING ADVISOR${NC}"
    echo -e "${CYAN}======================================================================${NC}"

    if [ "$INTERACTIVE" = "true" ]; then
        while true; do
            read -rp "Run the tuning advisor to scale secondary settings to this host now? [Y/n]: " yn < /dev/tty
            case "${yn:-y}" in
                [Yy]*) bash "$tuner" "${tuner_args[@]}"; break;;
                [Nn]*) echo -e "  Run it later with: ${BOLD}sudo ./tune-stack.sh${NC}"; break;;
                *) echo -e "${RED}Please answer 'y' or 'n'.${NC}";;
            esac
        done
    else
        # Headless: auto-apply the RAM-scaled recommendations (consistent with -y).
        bash "$tuner" --yes "${tuner_args[@]}" || echo -e "${YELLOW}[WARNING] Tuning advisor reported an issue; review the output above.${NC}"
    fi
}

# Offer to GENERATE the AWS CLI commands that lock this instance's inbound
# firewall to Cloudflare. The generator never calls AWS itself — it writes a
# reviewable command script for the operator to run under their own credentials.
run_security_group_step() {
    local sg="${_SETUP_DIR}/configure-security-group.sh"
    [ -f "$sg" ] || return 0

    local nc_flag=()
    [ "$NO_COLOR" = "true" ] && nc_flag=(--no-color)

    if [ "$INTERACTIVE" = "true" ]; then
        echo -e "\n${CYAN}======================================================================${NC}"
        echo -e "  ${BOLD}CLOUDFLARE EDGE — EC2 SECURITY GROUP (optional)${NC}"
        echo -e "${CYAN}======================================================================${NC}"
        echo -e "Generate the AWS CLI commands that restrict this instance's inbound 80/443"
        echo -e "to Cloudflare's IP ranges. The commands are written to a file for you to"
        echo -e "review and run under AWS credentials that have EC2 permissions."
        local yn
        read -rp "Generate the Cloudflare Security Group commands now? [y/N]: " yn < /dev/tty
        case "${yn:-n}" in
            [Yy]*) bash "$sg" "${nc_flag[@]}" || warn "Security Group generator reported an issue; review above.";;
            *) echo -e "  Skipped. Generate them later with: ${BOLD}./configure-security-group.sh${NC}";;
        esac
    else
        [ "$CONFIGURE_SG" = "true" ] || return 0
        bash "$sg" "${nc_flag[@]}" || true
    fi
}

# Optional first step: bring every system package up to the latest available
# version. Idempotent — a second run simply finds nothing to upgrade.
offer_system_upgrade() {
    local do_it="$FULL_UPGRADE"
    if [ "$INTERACTIVE" = "true" ]; then
        local yn
        read -rp "Update ALL system packages to the latest available versions first? [y/N]: " yn < /dev/tty
        case "${yn:-n}" in [Yy]*) do_it=true;; *) do_it=false;; esac
    fi
    [ "$do_it" = "true" ] || { echo -e "${BLUE}[*] Skipping full system upgrade.${NC}"; return 0; }

    echo -e "${GREEN}[+] Upgrading all system packages (apt-get full-upgrade)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || echo -e "${YELLOW}[WARNING] apt-get update reported an error; continuing.${NC}"
    apt-get -y full-upgrade || echo -e "${YELLOW}[WARNING] full-upgrade reported an error; continuing.${NC}"
    apt-get -y --purge autoremove || true
    if [ -f /var/run/reboot-required ]; then
        echo -e "${YELLOW}[NOTE] A reboot is required to finish applying the upgrade (e.g. a new kernel). Reboot after setup completes.${NC}"
    fi
}

# Optional first step: install WP-CLI. Idempotent — skips if already present.
# The phar only needs to be placed now; it becomes usable once PHP is installed
# (the php-opcache component below installs PHP).
offer_wp_cli_install() {
    local do_it="$INSTALL_WPCLI"
    if [ "$INTERACTIVE" = "true" ]; then
        local yn
        read -rp "Install WP-CLI (the WordPress command-line tool) to /usr/local/bin/wp? [y/N]: " yn < /dev/tty
        case "${yn:-n}" in [Yy]*) do_it=true;; *) do_it=false;; esac
    fi
    [ "$do_it" = "true" ] || { echo -e "${BLUE}[*] Skipping WP-CLI installation.${NC}"; return 0; }

    if command -v wp &>/dev/null; then
        echo -e "${GREEN}[+] WP-CLI already installed ($(command -v wp)); leaving it in place.${NC}"
        return 0
    fi

    echo -e "${GREEN}[+] Installing WP-CLI...${NC}"
    local tmp_phar="/tmp/wp-cli.phar"
    if ! curl -fsSL --max-time 60 -o "$tmp_phar" \
        "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"; then
        echo -e "${YELLOW}[WARNING] Could not download WP-CLI; skipping (install later from https://wp-cli.org).${NC}"
        rm -f "$tmp_phar"; return 0
    fi
    # Sanity check: a valid phar starts with a PHP shebang/opening tag.
    if ! head -c 64 "$tmp_phar" | grep -qE '^#!/usr/bin/env php|<\?php'; then
        echo -e "${YELLOW}[WARNING] Downloaded WP-CLI file does not look valid; skipping.${NC}"
        rm -f "$tmp_phar"; return 0
    fi
    install -m 0755 "$tmp_phar" /usr/local/bin/wp && rm -f "$tmp_phar"
    if command -v php &>/dev/null; then
        if wp --info --allow-root &>/dev/null; then
            echo -e "${GREEN}[+] WP-CLI installed: $(wp --version --allow-root 2>/dev/null | head -n1).${NC}"
        else
            echo -e "${YELLOW}[NOTE] WP-CLI placed at /usr/local/bin/wp but 'wp --info' failed; verify after PHP is fully configured.${NC}"
        fi
    else
        echo -e "${GREEN}[+] WP-CLI placed at /usr/local/bin/wp. It becomes usable once PHP is installed (below).${NC}"
    fi
}

get_installed_version() {
    local comp="$1"
    case "$comp" in
        "system-updates")
            if command -v fail2ban-client &>/dev/null; then
                fail2ban-client --version | head -n 1 | awk '{print $2}'
            else
                echo "N/A"
            fi
            ;;
        "nginx-http3")
            if command -v nginx &>/dev/null; then
                nginx -v 2>&1 | cut -d'/' -f2 | awk '{print $1}'
            else
                echo "N/A"
            fi
            ;;
        "nginx-apparmor")
            if [ -f /etc/apparmor.d/usr.sbin.nginx ]; then
                echo "1.0.0"
            else
                echo "N/A"
            fi
            ;;
        "php-opcache")
            if command -v php &>/dev/null; then
                php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION.'.'.PHP_RELEASE_VERSION;" 2>/dev/null
            else
                echo "N/A"
            fi
            ;;
        "php-apparmor")
            if [ -f /etc/apparmor.d/usr.sbin.php-fpm ]; then
                echo "1.0.0"
            else
                echo "N/A"
            fi
            ;;
        "redis-cache")
            if command -v redis-server &>/dev/null; then
                redis-server --version | grep -o -E 'v=[0-9]+\.[0-9]+\.[0-9]+' | cut -d'=' -f2
            else
                echo "N/A"
            fi
            ;;
        "redis-apparmor")
            if [ -f /etc/apparmor.d/usr.sbin.redis-server ]; then
                echo "1.0.0"
            else
                echo "N/A"
            fi
            ;;
        "mariadb")
            if command -v mariadb &>/dev/null; then
                mariadb --version | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+-[a-zA-Z0-9.-]+' | head -n 1
            else
                echo "N/A"
            fi
            ;;
        "mariadb-apparmor")
            if [ -f /etc/apparmor.d/usr.sbin.mariadbd ]; then
                echo "1.0.0"
            else
                echo "N/A"
            fi
            ;;
        "prometheus-exporter")
            if command -v prometheus-node-exporter &>/dev/null; then
                prometheus-node-exporter --version 2>&1 | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
            else
                echo "N/A"
            fi
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

# Main initialization
parse_options "$@"

if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then
    disable_colors
fi

# Resolve PHP version from APT before any component references it
resolve_php_version

# Display Header and memory calculations
print_header
evaluate_system_plan

# Stop if dry-run
if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}[DRY RUN] Completed. No systems were modified.${NC}\n"
    exit 0
fi

# Check root execution (after option parsing so --help and --dry-run work unprivileged)
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This setup script must be run as root (sudo) to configure system services.${NC}" >&2
    exit 1
fi

# ==========================================================
# 0. PRE-FLIGHT OPTIONS (before any component installs)
# ==========================================================
echo -e "\n${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}PRE-FLIGHT OPTIONS${NC}"
echo -e "${CYAN}======================================================================${NC}"
offer_system_upgrade
offer_wp_cli_install

# Authoritative PHP version resolution.
# The pre-root detection above can be wrong when the APT index is stale (which it
# is on a fresh box before the system-updates component runs its own update).
# nginx bakes the PHP-FPM socket path into its config, so EVERY component must
# agree on one series that APT can actually install — otherwise you get the
# "php8.5-* Unable to locate package / php8.5-fpm.service not found" cascade.
if [ "$PHP_VERSION_FORCED" != "true" ]; then
    echo -e "${CYAN}[*] Refreshing APT index to resolve the correct PHP version...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || \
        echo -e "${YELLOW}[WARNING] apt-get update failed; PHP detection may use a stale index.${NC}"
    _php_prev="$PHP_VERSION"
    _php_detected=$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null \
        | grep -oE 'php[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | sort -V | tail -n 1 || true)
    if [ -n "$_php_detected" ]; then
        PHP_VERSION="$_php_detected"
    fi
    if [ "$_php_prev" != "$PHP_VERSION" ]; then
        echo -e "${YELLOW}[*] PHP version resolved to ${BOLD}${PHP_VERSION}${NC}${YELLOW} (pre-flight guess was '${_php_prev}').${NC}"
    fi
fi

# Refuse to proceed if the resolved series has no installable php-fpm package.
# Failing loudly here beats writing an nginx config that points at a socket no
# PHP-FPM will ever create.
if ! apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] php${PHP_VERSION}-fpm is not installable from the configured APT sources.${NC}" >&2
    _php_avail=$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [ -n "$_php_avail" ]; then
        echo -e "${RED}        Available: ${_php_avail}${NC}" >&2
        echo -e "${RED}        Re-run with --php-version <X.Y> matching one of the above.${NC}" >&2
    else
        echo -e "${RED}        No php*-fpm package is available at all. Add a PHP source first, e.g.:${NC}" >&2
        echo -e "${RED}          add-apt-repository ppa:ondrej/php && apt-get update${NC}" >&2
    fi
    exit 1
fi

# Initialize Log Map Defaults
for comp in "${COMPONENTS[@]}"; do
    LOG_CHOICES["$comp"]="SKIPPED"
    COMP_STATUS["$comp"]="N/A"
    COMP_VERSIONS["$comp"]="N/A"
done

# ==========================================================
# 1. SYSTEM UPDATES & FIREWALL
# ==========================================================
if prompt_install "system-updates"; then
    echo -e "${GREEN}[+] Configuring system updates and ufw firewall...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y ufw unattended-upgrades fail2ban curl jq gnupg openssl

    # Configure UFW rules explicitly
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 80/tcp comment 'Nginx HTTP'
    ufw allow 443/tcp comment 'Nginx HTTPS'
    ufw allow 443/udp comment 'Nginx HTTP/3 QUIC'
    ufw allow 22/tcp comment 'Hardened SSH'
    ufw --force enable

    # Log statuses
    COMP_STATUS["system-updates"]=$(verify_service_status "fail2ban")
    COMP_VERSIONS["system-updates"]=$(get_installed_version "system-updates")
fi

# ==========================================================
# 2. NGINX & HTTP/3 CONFIGURATION
# ==========================================================
if prompt_install "nginx-http3"; then
    echo -e "${GREEN}[+] Installing and hardening Nginx...${NC}"
    # ssl-cert generates the snakeoil placeholder cert the server block boots
    # with until a Cloudflare Origin Certificate is installed. It is only
    # "Suggested" by the nginx package, so it MUST be listed explicitly —
    # without it, nginx -t fails on the missing certificate.
    apt-get install -y nginx ssl-cert

    # ssl-cert normally generates the snakeoil pair on install, but on minimal
    # images it can be empty/absent — which makes nginx -t fail with
    # "PEM_read_bio_X509_AUX() failed ... no start line". Regenerate defensively
    # so the ssl_certificate directive always has a loadable cert.
    if [ ! -s /etc/ssl/certs/ssl-cert-snakeoil.pem ] || [ ! -s /etc/ssl/private/ssl-cert-snakeoil.key ]; then
        make-ssl-cert generate-default-snakeoil --force-overwrite 2>/dev/null || true
    fi

    # Download Cloudflare Authenticated Origin Pulls (AOP) CA certificate.
    # -f prevents saving an HTML error page as a "certificate", and the result
    # is validated with openssl before nginx is ever pointed at it.
    mkdir -p /etc/nginx/certs
    AOP_OK=false
    for aop_url in \
        "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem" \
        "https://developers.cloudflare.com/ssl/static/origin-pull-ca.pem"; do
        if curl -fsSL --max-time 30 -o /etc/nginx/certs/cloudflare.crt "$aop_url" 2>/dev/null \
           && openssl x509 -in /etc/nginx/certs/cloudflare.crt -noout 2>/dev/null; then
            AOP_OK=true
            echo -e "${GREEN}[+] Cloudflare AOP CA downloaded and validated (${aop_url}).${NC}"
            break
        fi
    done

    if [ "$AOP_OK" = "true" ]; then
        AOP_DIRECTIVES="    # Cloudflare Authenticated Origin Pulls (AOP) Enforced
    ssl_client_certificate /etc/nginx/certs/cloudflare.crt;
    ssl_verify_client on;"
    else
        rm -f /etc/nginx/certs/cloudflare.crt
        echo -e "${YELLOW}[WARNING] Could not download a valid Cloudflare AOP CA — writing the server block WITHOUT AOP enforcement so nginx can start.${NC}"
        echo -e "${YELLOW}          Enable it later: save the CA from Cloudflare's AOP docs to /etc/nginx/certs/cloudflare.crt, uncomment the two AOP lines in /etc/nginx/sites-available/wordpress, then 'nginx -t && systemctl reload nginx'.${NC}"
        AOP_DIRECTIVES="    # Cloudflare AOP DISABLED at install time (CA download failed).
    # To enforce: place the CA at /etc/nginx/certs/cloudflare.crt and uncomment:
    # ssl_client_certificate /etc/nginx/certs/cloudflare.crt;
    # ssl_verify_client on;"
    fi

    # Configure Hardened Global Nginx settings
    cat << 'EOF' > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Information Disclosure Hardening
    server_tokens off;

    # Security Headers Module Fallback
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval'; img-src 'self' https: data:; child-src 'self' https:;" always;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    # Setup Hardened Server Block for WordPress + AOP + HTTP/3
    cat << EOF > /etc/nginx/sites-available/wordpress
# Port 80: permanent redirect to HTTPS (UFW allows 80 solely for this hop)
server {
    listen 80;
    listen [::]:80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 quic reuseport;
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name _; # Replace with actual domain in production

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    # Quantum-resistant and secure baseline TLS
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';

${AOP_DIRECTIVES}

    root /var/www/html;
    index index.php index.html;

    # Advertises HTTP/3 alternate service availability
    add_header Alt-Svc 'h3=":443"; ma=86400' always;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Restrict execution of raw PHP scripts inside media directories
    location ~* ^/wp-content/uploads/.*\.php$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Disable direct public access to sensitive code extensions
    location ~* \.(ini|log|conf|bak|sql|git|env|yaml|yml)$ {
        deny all;
    }
}
EOF

    # Activate site and test configurations
    ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    if nginx -t &>/dev/null; then
        systemctl restart nginx || true
        COMP_STATUS["nginx-http3"]="SUCCESS"
    else
        COMP_STATUS["nginx-http3"]="FAILED (Config Syntax Error)"
        echo -e "${RED}[ERROR] nginx -t rejected the generated configuration:${NC}"
        nginx -t 2>&1 | sed 's/^/    /'
        echo -e "${YELLOW}[HINT] If the error mentions \"quic\", this nginx build lacks the HTTP/3 module — remove the 'listen 443 quic' line. If it mentions a missing certificate, verify the ssl-cert package installed correctly.${NC}"
    fi
    COMP_VERSIONS["nginx-http3"]=$(get_installed_version "nginx-http3")

    # Restore the real visitor IP behind Cloudflare. Without this, nginx logs the
    # Cloudflare edge IP as the client, which would make the nginx-wp-login
    # Fail2ban jail ban CLOUDFLARE itself. Reuses the same CF range list.
    _realip="${_SETUP_DIR}/configure-cloudflare-realip.sh"
    if [ "${COMP_STATUS[nginx-http3]}" = "SUCCESS" ] && [ -f "$_realip" ]; then
        echo -e "${GREEN}[+] Configuring Cloudflare real-IP restoration...${NC}"
        _realip_args=()
        [ "$NO_COLOR" = "true" ] && _realip_args=(--no-color)
        bash "$_realip" "${_realip_args[@]}" \
            || echo -e "${YELLOW}[WARNING] Real-IP config step reported an issue; nginx still serving. Run configure-cloudflare-realip.sh later.${NC}"
    fi
fi

# ==========================================================
# 3. NGINX APPARMOR PROFILE CONTAINMENT
# ==========================================================
if prompt_install "nginx-apparmor"; then
    echo -e "${GREEN}[+] Deploying Nginx AppArmor security profile...${NC}"
    # Ensure AppArmor is installed
    if ! command -v apparmor_parser &>/dev/null; then
        echo -e "${YELLOW}[*] AppArmor utilities not found. Installing apparmor-utils...${NC}"
        apt-get install -y apparmor-utils
    fi

    # Write the AppArmor profile directly
    cat << 'EOF' > /etc/apparmor.d/usr.sbin.nginx
# ==============================================================================
# SafeCloud.PRO - Enterprise AppArmor Profile for Hardened Nginx Web Tier
# Target OS: Ubuntu 26.04 LTS
# Binary Path: /usr/sbin/nginx
# Version: 1.0.0 (LTS Hardened)
# ==============================================================================
# This profile enforces strict process-level confinement and directory containment 
# on the Nginx web server, mitigating file leakage and arbitrary code execution vectors.
# ==============================================================================

#include <tunables/global>

/usr/sbin/nginx flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/openssl>
  #include <abstractions/ssl_certs>

  # ----------------------------------------
  # 1. PROCESS & CAPABILITY PRIVILEGES
  # ----------------------------------------
  capability setuid,
  capability setgid,
  capability chown,
  capability kill,
  capability dac_override,
  capability dac_read_search,
  capability net_bind_service,
  capability sys_resource,

  # ----------------------------------------
  # 2. NETWORK PROTOCOLS & SOCKETS
  # ----------------------------------------
  network inet stream,
  network inet dgram,
  network inet6 stream,
  network inet6 dgram,
  network unix stream,
  network unix dgram,

  # ----------------------------------------
  # 3. CORE FILE READ ACCESS (Nginx Engine)
  # ----------------------------------------
  /usr/sbin/nginx mr,
  /usr/bin/nginx mr,
  # Dynamic modules pulled in by include /etc/nginx/modules-enabled/*.conf must
  # be mmap-able (m), or nginx aborts at startup under enforcement — the usual
  # cause of "nginx.service failed" right after loading the profile.
  /usr/lib/nginx/modules/ r,
  /usr/lib/nginx/modules/*.so mr,
  /usr/lib/*/nginx/modules/*.so mr,
  /usr/share/nginx/ r,
  /usr/share/nginx/** r,
  /etc/nginx/ r,
  /etc/nginx/** r,
  /etc/mime.types r,
  /etc/nsswitch.conf r,
  /etc/passwd r,
  /etc/group r,

  # Read-only permission for SSL certificates and origin keys
  /etc/ssl/** r,
  /etc/ssl/certs/** r,
  /etc/ssl/private/** r,
  /etc/nginx/certs/ r,
  /etc/nginx/certs/** r,

  # ----------------------------------------
  # 4. SYSTEM PATHS & RUNTIME DESCRIPTORS
  # ----------------------------------------
  /dev/null rw,
  /dev/urandom r,
  /dev/random r,
  /proc/locks r,
  /proc/cpuinfo r,
  /proc/sys/kernel/ngroups_max r,
  /sys/devices/system/cpu/ r,
  /sys/devices/system/cpu/** r,
  /run/nginx.pid rw,
  /var/run/nginx.pid rw,
  /run/shm/nginx_shared_zone_* rw,

  # Nginx scratch space: client body, proxy and fastcgi temp buffers
  /var/lib/nginx/ r,
  /var/lib/nginx/** rw,

  # ----------------------------------------
  # 5. SITE WORKROOT & MEDIA READ ACCESS
  # ----------------------------------------
  /var/www/html/ r,
  /var/www/html/** r,
  deny /var/www/html/wp-admin/** w,
  deny /var/www/html/wp-includes/** w,
  deny /var/www/html/wp-content/plugins/** w,
  deny /var/www/html/wp-content/themes/** w,
  /var/www/html/wp-content/uploads/ r,
  /var/www/html/wp-content/uploads/** rw,

  # ----------------------------------------
  # 6. TRANSACTION LOGGING (Write Boundaries)
  # ----------------------------------------
  /var/log/nginx/ r,
  /var/log/nginx/** rw,
  /var/log/nginx/*.log w,

  # ----------------------------------------
  # 7. INTER-SERVICE COMMUNICATION SOCKETS
  # ----------------------------------------
  /run/php/ r,
  /run/php/php*.sock rw,
  /var/run/php/php*.sock rw,

  # Exclude arbitrary command execution (No shell access)
  deny /bin/** x,
  deny /usr/bin/** x,
  deny /usr/local/bin/** x,
}
EOF

    # Reload AppArmor and enforce profile.
    if [ ! -f /etc/apparmor.d/usr.sbin.nginx ]; then
        COMP_STATUS["nginx-apparmor"]="FAILED (Profile File Error)"
    elif ! apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx; then
        # A profile that won't parse must not be left half-loaded.
        echo -e "${RED}[ERROR] apparmor_parser rejected the profile; nginx left unconfined.${NC}"
        COMP_STATUS["nginx-apparmor"]="FAILED (Profile Parse Error)"
    else
        systemctl reload apparmor 2>/dev/null || true
        # Golden rule: validate the nginx config BEFORE restarting into the new
        # profile. Restarting a daemon into a broken config or an over-strict
        # profile is exactly what takes the site down.
        if ! nginx -t &>/dev/null; then
            echo -e "${RED}[ERROR] nginx -t failed; not restarting nginx (leaving the running instance untouched).${NC}"
            nginx -t 2>&1 | sed 's/^/    /'
            COMP_STATUS["nginx-apparmor"]="FAILED (nginx config invalid)"
        else
            systemctl restart nginx || true
            if systemctl is-active --quiet nginx; then
                COMP_STATUS["nginx-apparmor"]="SUCCESS"
            else
                # Report the truth instead of an unconditional SUCCESS, and point
                # at the likely culprit: an AppArmor denial.
                echo -e "${RED}[ERROR] nginx failed to start after loading the AppArmor profile.${NC}"
                echo -e "${YELLOW}[HINT] Inspect denials with 'journalctl -k | grep -i apparmor' and 'systemctl status nginx'.${NC}"
                echo -e "${YELLOW}       To unblock without removing confinement: 'aa-complain /etc/apparmor.d/usr.sbin.nginx' then restart nginx, and add the denied paths to the profile.${NC}"
                journalctl -u nginx -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
                COMP_STATUS["nginx-apparmor"]="FAILED (nginx not active under profile)"
            fi
        fi
    fi
    COMP_VERSIONS["nginx-apparmor"]="1.0.0"
fi

# ==========================================================
# 4. PHP-FPM & OPCACHE HARDENING
# ==========================================================
if prompt_install "php-opcache"; then
    echo -e "${GREEN}[+] Installing and tuning PHP ${PHP_VERSION} packages...${NC}"

    # Pre-flight: verify the package series exists before configuring anything,
    # so a wrong version can't leave half-written configs behind.
    if ! apt-cache show "php${PHP_VERSION}-fpm" &>/dev/null; then
        echo -e "${RED}[ERROR] php${PHP_VERSION}-fpm is not available in this release's APT repositories.${NC}"
        echo -e "        Available FPM packages: $(apt-cache search --names-only '^php[0-9.]+-fpm$' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
        echo -e "        Re-run with ${BOLD}--php-version <X.Y>${NC} matching one of the above."
        COMP_STATUS["php-opcache"]="FAILED (Package Unavailable)"
        PHP_INSTALL_OK=false
    elif ! apt-get install -y "php${PHP_VERSION}-fpm"; then
        # Install FPM on its own first: it is the one package everything else
        # depends on, and bundling it with optional extensions means a single
        # missing extension aborts the whole apt transaction and leaves no
        # /etc/php/${PHP_VERSION} tree — the exact failure this script hit before.
        echo -e "${RED}[ERROR] php${PHP_VERSION}-fpm failed to install — skipping PHP configuration.${NC}"
        COMP_STATUS["php-opcache"]="FAILED (FPM Install Error)"
        PHP_INSTALL_OK=false
    else
        PHP_INSTALL_OK=true
        # Optional extensions, installed individually so one unavailable package
        # doesn't cancel the others (or FPM).
        for _php_ext in mysql opcache curl xml mbstring; do
            if apt-get install -y "php${PHP_VERSION}-${_php_ext}"; then
                continue
            fi
            # Some extensions have no separate package because they are compiled
            # into the PHP binary (Ubuntu 26.04 builds OPcache into php8.5 —
            # php8.5-opcache does not exist). Only warn when genuinely absent.
            case "$_php_ext" in
                mysql)   _mod_re='mysqli|mysqlnd' ;;
                opcache) _mod_re='Zend OPcache' ;;
                *)       _mod_re="$_php_ext" ;;
            esac
            if "php${PHP_VERSION}" -m 2>/dev/null | grep -qiE "^(${_mod_re})$"; then
                echo -e "${GREEN}[+] php${PHP_VERSION}-${_php_ext}: no separate package on this release — extension is built into PHP ${PHP_VERSION}.${NC}"
            else
                echo -e "${YELLOW}[WARNING] php${PHP_VERSION}-${_php_ext} unavailable — continuing without it.${NC}"
            fi
        done
    fi

    # Only write configs if the package tree actually materialized.
    if [ "$PHP_INSTALL_OK" = "true" ] && [ ! -d "/etc/php/${PHP_VERSION}/fpm" ]; then
        echo -e "${RED}[ERROR] /etc/php/${PHP_VERSION}/fpm is missing after install — skipping PHP configuration.${NC}"
        COMP_STATUS["php-opcache"]="FAILED (Config Tree Missing)"
        PHP_INSTALL_OK=false
    fi

    if [ "$PHP_INSTALL_OK" = "true" ]; then

    # Tune PHP-FPM Pool configurations
    cat << EOF > "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
[www]
user = www-data
group = www-data
listen = /var/run/php/php${PHP_VERSION}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Static process manager for high reliability and CPU stabilization
; (PHP-FPM/INI files only accept ';' comments — a '#' line parses as a
;  key with a NULL value and aborts FPM startup with status=78/CONFIG)
pm = static
pm.max_children = ${PHP_WORKERS}
pm.max_requests = 1000

request_terminate_timeout = 60s
request_slowlog_timeout = 5s
slowlog = /var/log/php${PHP_VERSION}-fpm-slow.log

; Only ever execute files ending in .php (blocks disguised-extension exploits)
security.limit_extensions = .php
EOF

    # Tune global OPcache and isolation checking.
    # Only emit the zend_extension line when opcache.so actually exists as a
    # shared object — on releases that compile OPcache into the PHP binary
    # (Ubuntu 26.04 / PHP 8.5), loading a nonexistent .so aborts every SAPI start.
    OPCACHE_INI="/etc/php/${PHP_VERSION}/mods-available/opcache.ini"
    mkdir -p "$(dirname "${OPCACHE_INI}")"
    _php_ext_dir=$("php${PHP_VERSION}" -r 'echo ini_get("extension_dir");' 2>/dev/null || true)
    if [ -n "$_php_ext_dir" ] && [ -f "${_php_ext_dir}/opcache.so" ]; then
        echo "zend_extension=opcache.so" > "${OPCACHE_INI}"
    else
        echo "; OPcache is compiled into this PHP build; no zend_extension line needed" > "${OPCACHE_INI}"
    fi
    cat << EOF >> "${OPCACHE_INI}"
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.revalidate_freq=0

; Cross-Site Shared Memory Bytecode Isolation checking
opcache.validate_permission=1
opcache.validate_root=1
EOF

    # Wire the ini into every SAPI (fpm + cli). Normally the phpX.Y-opcache
    # package does this on install, but when OPcache is built into PHP there is
    # no such package and nothing symlinks mods-available/opcache.ini into
    # conf.d — the hardening settings above would silently never load.
    if command -v phpenmod &>/dev/null; then
        phpenmod -v "${PHP_VERSION}" opcache 2>/dev/null || true
    fi
    for _sapi in fpm cli; do
        _confd="/etc/php/${PHP_VERSION}/${_sapi}/conf.d"
        if [ -d "$_confd" ] && ! ls "$_confd"/*opcache.ini &>/dev/null; then
            ln -sf "$OPCACHE_INI" "$_confd/10-opcache.ini"
        fi
    done

    # Edit main PHP configurations to harden runtimes
    PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
    sed -i 's/;realpath_cache_size = .*/realpath_cache_size = 4M/' "${PHP_INI}"
    sed -i 's/;realpath_cache_ttl = .*/realpath_cache_ttl = 600/' "${PHP_INI}"
    sed -i 's/expose_php = .*/expose_php = Off/' "${PHP_INI}"
    sed -i 's/display_errors = .*/display_errors = Off/' "${PHP_INI}"
    sed -i 's/log_errors = .*/log_errors = On/' "${PHP_INI}"
    # Match the setting whether the distro ships it commented (";disable_functions =")
    # or active-but-empty ("disable_functions = ", as PHP 8.x php.ini-production does) —
    # the old commented-only pattern silently left every dangerous function enabled.
    sed -i "s/^;\?disable_functions *=.*/disable_functions = exec,system,shell_exec,passthru,popen,proc_open,show_source/" "${PHP_INI}"
    # Never guess the script path from trailing PATH_INFO (classic nginx+PHP RCE vector)
    sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' "${PHP_INI}"

    systemctl restart "php${PHP_VERSION}-fpm" || true
    COMP_STATUS["php-opcache"]=$(verify_service_status "php${PHP_VERSION}-fpm")
    fi # PHP_INSTALL_OK

    COMP_VERSIONS["php-opcache"]=$(get_installed_version "php-opcache")
fi

# ==========================================================
# 5. PHP-FPM APPARMOR PROFILE CONTAINMENT
# ==========================================================
if prompt_install "php-apparmor"; then
    echo -e "${GREEN}[+] Deploying PHP-FPM AppArmor security profile...${NC}"
    if ! command -v apparmor_parser &>/dev/null; then
        echo -e "${YELLOW}[*] AppArmor utilities not found. Installing apparmor-utils...${NC}"
        apt-get install -y apparmor-utils
    fi

    _php_profile="${_SETUP_DIR}/apparmor/usr.sbin.php-fpm"
    if [ ! -f "$_php_profile" ]; then
        echo -e "${RED}[ERROR] ${_php_profile} not found — re-clone the repo so apparmor/ is present.${NC}"
        COMP_STATUS["php-apparmor"]="FAILED (Profile File Missing)"
    else
        install -m 0644 "$_php_profile" /etc/apparmor.d/usr.sbin.php-fpm
        if ! apparmor_parser -r -W /etc/apparmor.d/usr.sbin.php-fpm; then
            echo -e "${RED}[ERROR] apparmor_parser rejected the profile; PHP-FPM left unconfined.${NC}"
            COMP_STATUS["php-apparmor"]="FAILED (Profile Parse Error)"
        else
            systemctl reload apparmor 2>/dev/null || true
            systemctl restart "php${PHP_VERSION}-fpm" || true
            if systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
                COMP_STATUS["php-apparmor"]="SUCCESS"
            else
                echo -e "${RED}[ERROR] php${PHP_VERSION}-fpm failed to start after loading the AppArmor profile.${NC}"
                echo -e "${YELLOW}[HINT] Inspect denials with 'journalctl -k | grep -i apparmor' and 'systemctl status php${PHP_VERSION}-fpm'.${NC}"
                echo -e "${YELLOW}       To unblock without removing confinement: 'aa-complain /etc/apparmor.d/usr.sbin.php-fpm' then restart, and add the denied paths to the profile.${NC}"
                journalctl -u "php${PHP_VERSION}-fpm" -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
                COMP_STATUS["php-apparmor"]="FAILED (php-fpm not active under profile)"
            fi
        fi
    fi
    COMP_VERSIONS["php-apparmor"]="1.0.0"
fi

# ==========================================================
# 6. REDIS OBJECT CACHE (UNIX-SOCKET ONLY)
# ==========================================================
if prompt_install "redis-cache"; then
    echo -e "${GREEN}[+] Installing and confining Redis object cache...${NC}"
    # Install redis-server on its own: bundling it with the PHP extension means
    # one unavailable package aborts the whole apt transaction (observed when a
    # wrong phpX.Y-redis name cancelled the redis-server install too).
    apt-get install -y redis-server
    if ! apt-get install -y "php${PHP_VERSION}-redis"; then
        echo -e "${YELLOW}[WARNING] php${PHP_VERSION}-redis not installed — Redis itself is configured; install the PHP extension after fixing the PHP component (apt-get install php${PHP_VERSION}-redis).${NC}"
    fi

    if ! command -v redis-server &>/dev/null; then
        echo -e "${RED}[ERROR] redis-server failed to install — skipping Redis configuration.${NC}"
        COMP_STATUS["redis-cache"]="FAILED (Package Install Error)"
    else

    # Cache-role Redis: socket-only transport, no disk persistence, bounded memory.
    # NOTE: Redis does not allow trailing comments on directive lines.
    cat << 'EOF' > /etc/redis/redis.conf
# SafeCloud.PRO hardened Redis (pure object-cache role)

# Transport: Unix domain socket only. TCP listener fully disabled.
port 0
unixsocket /var/run/redis/redis-server.sock
unixsocketperm 770

# Run supervised under systemd (Ubuntu default unit uses Type=notify)
daemonize no
supervised systemd
pidfile /var/run/redis/redis-server.pid

# Memory ceiling — auto-sized to detected RAM (set by setup.sh post-write)
maxmemory 1gb
maxmemory-policy allkeys-lru
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes

# Cache role: never fork to persist to disk
save ""
appendonly no

loglevel notice
logfile /var/log/redis/redis-server.log
EOF

    # Apply the RAM-derived cache ceiling (heredoc is single-quoted, so the value
    # is substituted here rather than inline).
    sed -i "s/^maxmemory .*/maxmemory ${REDIS_MAXMEMORY_MB}mb/" /etc/redis/redis.conf

    # Grant the web tier access to the 770 socket
    usermod -aG redis www-data || true

    systemctl restart redis-server || true
    # PHP-FPM workers must be restarted to pick up the new redis group membership
    systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
    COMP_STATUS["redis-cache"]=$(verify_service_status "redis-server")
    fi # redis-server present

    COMP_VERSIONS["redis-cache"]=$(get_installed_version "redis-cache")
fi

# ==========================================================
# 7. REDIS APPARMOR PROFILE CONTAINMENT
# ==========================================================
if prompt_install "redis-apparmor"; then
    echo -e "${GREEN}[+] Deploying Redis AppArmor security profile...${NC}"
    if ! command -v apparmor_parser &>/dev/null; then
        echo -e "${YELLOW}[*] AppArmor utilities not found. Installing apparmor-utils...${NC}"
        apt-get install -y apparmor-utils
    fi

    _redis_profile="${_SETUP_DIR}/apparmor/usr.sbin.redis-server"
    _redis_dropin="${_SETUP_DIR}/apparmor/redis-server-apparmor.conf"
    if [ ! -f "$_redis_profile" ] || [ ! -f "$_redis_dropin" ]; then
        echo -e "${RED}[ERROR] AppArmor profile/drop-in missing under ${_SETUP_DIR}/apparmor/ — re-clone the repo.${NC}"
        COMP_STATUS["redis-apparmor"]="FAILED (Profile File Missing)"
    else
        install -m 0644 "$_redis_profile" /etc/apparmor.d/usr.sbin.redis-server
        if ! apparmor_parser -r -W /etc/apparmor.d/usr.sbin.redis-server; then
            echo -e "${RED}[ERROR] apparmor_parser rejected the profile; Redis left unconfined.${NC}"
            COMP_STATUS["redis-apparmor"]="FAILED (Profile Parse Error)"
        else
            # Ubuntu's redis-server.service sets NoNewPrivileges=true, which blocks
            # the kernel's implicit path-based attachment at exec() — a systemd
            # drop-in must attach the profile explicitly.
            mkdir -p /etc/systemd/system/redis-server.service.d
            install -m 0644 "$_redis_dropin" /etc/systemd/system/redis-server.service.d/apparmor.conf
            systemctl daemon-reload
            systemctl reload apparmor 2>/dev/null || true
            systemctl restart redis-server || true
            if systemctl is-active --quiet redis-server; then
                COMP_STATUS["redis-apparmor"]="SUCCESS"
            else
                echo -e "${RED}[ERROR] Redis failed to start after loading the AppArmor profile.${NC}"
                echo -e "${YELLOW}[HINT] Inspect denials with 'journalctl -k | grep -i apparmor' and 'systemctl status redis-server'.${NC}"
                echo -e "${YELLOW}       To unblock without removing confinement: 'aa-complain /etc/apparmor.d/usr.sbin.redis-server' then restart, and add the denied paths to the profile.${NC}"
                journalctl -u redis-server -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
                COMP_STATUS["redis-apparmor"]="FAILED (redis-server not active under profile)"
            fi
        fi
    fi
    COMP_VERSIONS["redis-apparmor"]="1.0.0"
fi

# ==========================================================
# 8. MARIADB 11.x HARDENING
# ==========================================================
if prompt_install "mariadb"; then
    echo -e "${GREEN}[+] Installing and configuring MariaDB Database...${NC}"
    apt-get install -y mariadb-server

    # RAM-derived pool size, written as an integer-M value MariaDB accepts.
    DB_POOL_SIZE_CNF="${DB_POOL_MB}M"

    # Hardening goes in a DROP-IN OVERRIDE, not a rewrite of the distro's
    # 50-server.cnf: replacing that file with hardcoded paths (datadir,
    # lc-messages-dir, pid) is exactly what breaks startup when the packaging
    # changes between MariaDB releases. Files in mariadb.conf.d/ are read in
    # lexical order, so 60- cleanly overrides 50- while distro defaults stand.
    cat << EOF > /etc/mysql/mariadb.conf.d/60-safecloud-hardening.cnf
# SafeCloud.PRO hardening & sizing overrides
# (distro operational defaults remain untouched in 50-server.cnf)
[mysqld]
# Strict security: Bind to 127.0.0.1 exclusively (Zero remote network vectors)
bind-address            = 127.0.0.1

# Never resolve client hostnames (loopback-only topology; avoids DNS stalls & spoofing)
skip-name-resolve

# Rebalanced memory budget for 300MB WooCommerce DB with room for aggressive growth
innodb_buffer_pool_size = ${DB_POOL_SIZE_CNF}
innodb_log_file_size    = 256M
innodb_flush_log_at_trx_commit = 1

# NOTE: This baseline is loopback + Unix-socket only, so in-transit TLS is not
# configured here. If you split the database onto a separate host, provision
# server certificates and enable:
#   ssl-ca / ssl-cert / ssl-key + require_secure_transport = ON
EOF

    systemctl reset-failed mariadb 2>/dev/null || true
    if ! systemctl restart mariadb; then
        echo -e "${RED}[ERROR] MariaDB failed to start with the new overrides. Diagnostics:${NC}"
        journalctl -u mariadb -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi
    COMP_STATUS["mariadb"]=$(verify_service_status "mariadb")
    COMP_VERSIONS["mariadb"]=$(get_installed_version "mariadb")
fi

# ==========================================================
# 9. MARIADB APPARMOR PROFILE CONTAINMENT
# ==========================================================
if prompt_install "mariadb-apparmor"; then
    echo -e "${GREEN}[+] Deploying MariaDB AppArmor security profile...${NC}"
    if ! command -v apparmor_parser &>/dev/null; then
        echo -e "${YELLOW}[*] AppArmor utilities not found. Installing apparmor-utils...${NC}"
        apt-get install -y apparmor-utils
    fi

    _mariadb_profile="${_SETUP_DIR}/apparmor/usr.sbin.mariadbd"
    if [ ! -f "$_mariadb_profile" ]; then
        echo -e "${RED}[ERROR] ${_mariadb_profile} not found — re-clone the repo so apparmor/ is present.${NC}"
        COMP_STATUS["mariadb-apparmor"]="FAILED (Profile File Missing)"
    else
        # Ubuntu's mariadb-server package ships its own /etc/apparmor.d/mariadbd
        # profile attached to the SAME binary path. Two profiles claiming one
        # binary leaves the kernel unable to pick one — mariadbd runs unconfined
        # under EITHER. Disable the distro profile before loading this one.
        if [ -f /etc/apparmor.d/mariadbd ]; then
            mkdir -p /etc/apparmor.d/disable
            ln -sf /etc/apparmor.d/mariadbd /etc/apparmor.d/disable/mariadbd
            apparmor_parser -R /etc/apparmor.d/mariadbd 2>/dev/null || true
        fi

        install -m 0644 "$_mariadb_profile" /etc/apparmor.d/usr.sbin.mariadbd
        if ! apparmor_parser -r -W /etc/apparmor.d/usr.sbin.mariadbd; then
            echo -e "${RED}[ERROR] apparmor_parser rejected the profile; MariaDB left unconfined.${NC}"
            COMP_STATUS["mariadb-apparmor"]="FAILED (Profile Parse Error)"
        else
            systemctl reload apparmor 2>/dev/null || true
            systemctl restart mariadb || true
            if systemctl is-active --quiet mariadb; then
                COMP_STATUS["mariadb-apparmor"]="SUCCESS"
            else
                echo -e "${RED}[ERROR] MariaDB failed to start after loading the AppArmor profile.${NC}"
                echo -e "${YELLOW}[HINT] Inspect denials with 'journalctl -k | grep -i apparmor' and 'systemctl status mariadb'.${NC}"
                echo -e "${YELLOW}       To unblock without removing confinement: 'aa-complain /etc/apparmor.d/usr.sbin.mariadbd' then restart, and add the denied paths to the profile.${NC}"
                journalctl -u mariadb -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
                COMP_STATUS["mariadb-apparmor"]="FAILED (mariadb not active under profile)"
            fi
        fi
    fi
    COMP_VERSIONS["mariadb-apparmor"]="1.0.0"
fi

# ==========================================================
# 10. PROMETHEUS LOCALHOST ISOLATION
# ==========================================================
if [ "$INSTALL_EXPORTERS" = "true" ]; then
    if prompt_install "prometheus-exporter"; then
        echo -e "${GREEN}[+] Installing and isolating Prometheus Node Exporter...${NC}"
        apt-get install -y prometheus-node-exporter

        # Bind metrics exclusively to local loopback interface
        sed -i 's/ARGS=.*/ARGS="--web.listen-address=127.0.0.1:9100"/' /etc/default/prometheus-node-exporter

        systemctl restart prometheus-node-exporter || true
        COMP_STATUS["prometheus-exporter"]=$(verify_service_status "prometheus-node-exporter")
        COMP_VERSIONS["prometheus-exporter"]=$(get_installed_version "prometheus-exporter")
    fi
else
    LOG_CHOICES["prometheus-exporter"]="EXCLUDED_BY_FLAG"
fi

# ==========================================================
# 11. SUMMARY LOG WRITING & FINALIZE REPORT
# ==========================================================
echo -e "\n${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}GENERATING SYSTEM HARDENING SUMMARY LOG${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Compile the audit report
{
    echo "========================================================"
    echo "       LEMP STACK SECURITY DEPLOYMENT REPORT (2026)     "
    echo "       Completed on: $(date)"
    echo "========================================================"
    printf "%-45s | %-12s | %-20s\n" "Component" "Choice" "Installed Version"
    echo "------------------------------------------------------------------------"
    for comp in "${COMPONENTS[@]}"; do
        choice=${LOG_CHOICES[$comp]}
        version=${COMP_VERSIONS[$comp]}
        status=${COMP_STATUS[$comp]}
        
        # Format display name
        name=${COMP_NAMES[$comp]}
        
        if [ "$choice" = "ACCEPTED" ]; then
            printf "%-45s | %-12s | %-20s (Status: %s)\n" "$name" "$choice" "$version" "$status"
        else
            printf "%-45s | %-12s | %-20s\n" "$name" "$choice" "N/A"
        fi
    done
    echo "========================================================"
} > "$LOCAL_LOG_FILE"

# Clone log to global destination
mkdir -p "$(dirname "$INSTALL_LOG_FILE")"
cp "$LOCAL_LOG_FILE" "$INSTALL_LOG_FILE" 2>/dev/null || true

# Display the report in terminal
cat "$LOCAL_LOG_FILE"

# Honest exit status: count accepted components that did not reach SUCCESS
FAILED_COUNT=0
for comp in "${COMPONENTS[@]}"; do
    if [ "${LOG_CHOICES[$comp]}" = "ACCEPTED" ] && [[ "${COMP_STATUS[$comp]}" == FAILED* ]]; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

if [ "$FAILED_COUNT" -eq 0 ]; then
    echo -e "${GREEN}\n[✓] Secure LEMP deployment complete! Summary saved to:${NC}"
else
    echo -e "${RED}\n[✗] Deployment finished with ${FAILED_COUNT} FAILED component(s) — review the errors above before going live. Summary saved to:${NC}"
fi
echo -e "  - ${BOLD}${LOCAL_LOG_FILE}${NC} (Local file)"
echo -e "  - ${BOLD}${INSTALL_LOG_FILE}${NC} (Global system log)\n"

# Fine-tune to the detected hardware, but only on a clean install — never tune a
# stack that had component failures.
if [ "$FAILED_COUNT" -eq 0 ]; then
    run_post_install_tuning
    run_security_group_step
fi

[ "$FAILED_COUNT" -eq 0 ] || exit 1
