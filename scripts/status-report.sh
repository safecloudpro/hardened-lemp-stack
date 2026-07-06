#!/usr/bin/env bash
# ==============================================================================
# Title: secure-lemp-status-report.sh
# Target OS: Ubuntu 26.04 LTS (ARM64 / Graviton)
# Target Environment: Hardened WordPress & WooCommerce Stack
# Version: 2.2.0
# Description: Automated system auditing, file verification, and state reporting.
# ==============================================================================

set -uo pipefail

# ANSI color codes for clean reporting
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Defaults
OUTPUT_FILE=""
QUIET_MODE=false
JSON_OUTPUT=false
NO_COLOR=false
INSTALL_LOG="/var/log/lemp_interactive_install.log"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Audits and reports on the current security and operational status of the LEMP stack.

Options:
  -o, --output FILE   Write report to specified text file without prompting
  -q, --quiet         Suppress console output (Exit code 0 on success, >0 if any checks fail)
  -j, --json          Output findings as structured JSON
  --no-color          Disable colored terminal output
  -h, --help          Show this help menu and exit

Examples:
  ./status-report.sh
  ./status-report.sh -o ./live_audit_report.txt
  ./status-report.sh --json
EOF
}

# Parse options
parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    OUTPUT_FILE="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --output requires a file path.${NC}" >&2
                    exit 1
                fi
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -j|--json)
                JSON_OUTPUT=true
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
    RED='' GREEN='' CYAN='' BOLD='' NC=''
}

# Helper to check if a systemd service is active
check_service() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "ACTIVE"
    else
        echo "INACTIVE"
    fi
}

# Print the mode (enforce/complain/"") a loaded AppArmor profile is in.
# aa-status lists profile names bare under section headers ("N profiles are in
# enforce mode."); the old "name (enforce)" format no longer exists.
aa_profile_mode() {
    local prof="$1"
    aa-status 2>/dev/null | awk -v p="$prof" '
        /profiles are in enforce mode/  {s="enforce";  next}
        /profiles are in complain mode/ {s="complain"; next}
        /profiles are in/               {s="other";    next}
        /processes/                     {exit}
        s && $1 == p                    {print s; exit}'
}

# Helper to find running PHP version
detect_php_version() {
    if command -v php &>/dev/null; then
        php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null
    else
        echo ""
    fi
}

# Compile audit metrics
compile_audit() {
    # System & Firewall
    UFW_STATUS="INACTIVE"
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        UFW_STATUS="ACTIVE"
    fi

    # Web Server
    NGINX_STATUS=$(check_service "nginx")
    NGINX_VERSION="N/A"
    if [ "$NGINX_STATUS" = "ACTIVE" ]; then
        NGINX_VERSION=$(nginx -v 2>&1 | cut -d'/' -f2 | awk '{print $1}')
    fi
    AOP_CERT_EXISTS="NO"
    if [ -f "/etc/nginx/certs/cloudflare.crt" ]; then
        AOP_CERT_EXISTS="YES"
    fi

    # AppArmor Confinement
    NGINX_APPARMOR_STATUS="INACTIVE"
    if [ -f "/etc/apparmor.d/usr.sbin.nginx" ] && command -v aa-status &>/dev/null; then
        case "$(aa_profile_mode /usr/sbin/nginx)" in
            enforce)  NGINX_APPARMOR_STATUS="ACTIVE (Enforced)" ;;
            complain) NGINX_APPARMOR_STATUS="COMPLAIN (Not Enforced)" ;;
        esac
    fi

    # PHP-FPM
    local php_ver
    php_ver=$(detect_php_version)
    PHP_STATUS="INACTIVE"
    PHP_FPM_VER="N/A"
    OPCACHE_SECURE="NO"
    DISABLE_FUNCS="NO"

    if [ -n "$php_ver" ]; then
        PHP_FPM_VER="$php_ver"
        PHP_STATUS=$(check_service "php${php_ver}-fpm")
        
        # Check security configurations (tolerate "key=1" and "key = 1" spellings)
        local ini_file="/etc/php/${php_ver}/fpm/php.ini"
        if [ -f "$ini_file" ]; then
            if grep -Eq "^\s*opcache\.validate_permission\s*=\s*1" "/etc/php/${php_ver}/mods-available/opcache.ini" 2>/dev/null; then
                OPCACHE_SECURE="YES"
            fi
            if grep -Eq "^\s*disable_functions\s*=.*exec" "$ini_file" 2>/dev/null; then
                DISABLE_FUNCS="YES"
            fi
        fi
    fi

    # MariaDB
    MARIADB_STATUS=$(check_service "mariadb")
    MARIADB_VERSION="N/A"
    DB_LOCAL_BIND="NO"
    DB_POOL_SIZE="N/A"

    if [ "$MARIADB_STATUS" = "ACTIVE" ]; then
        MARIADB_VERSION=$(mariadb --version | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+-[a-zA-Z0-9.-]+' | head -n 1)
        if ss -tln 2>/dev/null | grep -q "127.0.0.1:3306"; then
            DB_LOCAL_BIND="YES"
        fi
        local db_client="mariadb"
        command -v "$db_client" &>/dev/null || db_client="mysql"
        local pool_bytes
        pool_bytes=$("$db_client" -N -s -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | awk '{print $2}' | head -n 1)
        if [[ "$pool_bytes" =~ ^[0-9]+$ ]] && [ "$pool_bytes" -gt 0 ]; then
            DB_POOL_SIZE="$((pool_bytes / 1024 / 1024)) MB"
        fi
    fi

    # Prometheus
    PROM_STATUS=$(check_service "prometheus-node-exporter")
    PROM_LOCAL_BIND="NO"
    if [ "$PROM_STATUS" = "ACTIVE" ]; then
        if ss -tln 2>/dev/null | grep -q "127.0.0.1:9100"; then
            PROM_LOCAL_BIND="YES"
        fi
    fi
}

generate_text_report() {
    compile_audit
    
    local report=""
    report+="${CYAN}======================================================================${NC}\n"
    report+="  ${BOLD}SAFECLOUD.PRO LEMP SECURITY AUDIT & CONFIGURATION REPORT${NC}\n"
    report+="  Generated on: $(date)\n"
    report+="${CYAN}======================================================================${NC}\n\n"

    # Status summary
    report+=" ${BOLD}[SYSTEM & EDGE COHESION]${NC}\n"
    report+="  - UFW Firewall Status:               $UFW_STATUS\n"
    report+="  - Nginx Server Running:              $NGINX_STATUS (Version: $NGINX_VERSION)\n"
    report+="  - Nginx AppArmor Confinement:        $NGINX_APPARMOR_STATUS\n"
    report+="  - Cloudflare Origin Pulls (AOP) Cert: $AOP_CERT_EXISTS\n\n"

    report+=" ${BOLD}[APPLICATION SECTOR SECURITY]${NC}\n"
    report+="  - PHP-FPM Service Running:           $PHP_STATUS (Version: $PHP_FPM_VER)\n"
    report+="  - OPcache Shared-Memory Hardened:     $OPCACHE_SECURE\n"
    report+="  - Dangerous Functions Disabled:       $DISABLE_FUNCS\n\n"

    report+=" ${BOLD}[PERSISTENCE LAYER HARDENING]${NC}\n"
    report+="  - MariaDB Service Running:           $MARIADB_STATUS (Version: $MARIADB_VERSION)\n"
    report+="  - Locked strictly to Localhost:      $DB_LOCAL_BIND\n"
    report+="  - Active Buffer Pool Cache Size:     $DB_POOL_SIZE\n\n"

    report+=" ${BOLD}[OBSERVABILITY CONFINEMENT]${NC}\n"
    report+="  - Prometheus Exporter Running:       $PROM_STATUS\n"
    report+="  - Exporter Isolated to Local Loop:   $PROM_LOCAL_BIND\n\n"

    # Read installation log comparison
    report+="${CYAN}----------------------------------------------------------------------${NC}\n"
    report+=" ${BOLD}[DEPLOYMENT HISTORY COMPARISON LOG]${NC}\n"
    report+="${CYAN}----------------------------------------------------------------------${NC}\n"
    if [ -f "$INSTALL_LOG" ]; then
        report+="$(cat "$INSTALL_LOG")\n"
    else
        report+="  - No deployment log file discovered at ${INSTALL_LOG}.\n"
    fi
    report+="${CYAN}======================================================================${NC}\n"

    echo -e "$report"
}

generate_json_report() {
    compile_audit
    cat << EOF
{
  "audit_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "system_and_edge": {
    "ufw_firewall_status": "$UFW_STATUS",
    "nginx_server_status": "$NGINX_STATUS",
    "nginx_version": "$NGINX_VERSION",
    "nginx_apparmor_status": "$NGINX_APPARMOR_STATUS",
    "cloudflare_aop_installed": "$AOP_CERT_EXISTS"
  },
  "application_layer": {
    "php_fpm_status": "$PHP_STATUS",
    "php_version": "$PHP_FPM_VER",
    "opcache_isolation_hardened": "$OPCACHE_SECURE",
    "dangerous_functions_disabled": "$DISABLE_FUNCS"
  },
  "persistence_layer": {
    "mariadb_status": "$MARIADB_STATUS",
    "mariadb_version": "$MARIADB_VERSION",
    "restricted_to_loopback": "$DB_LOCAL_BIND",
    "innodb_buffer_pool_size": "$DB_POOL_SIZE"
  },
  "observability_layer": {
    "prometheus_node_exporter_status": "$PROM_STATUS",
    "exporter_isolated_to_loopback": "$PROM_LOCAL_BIND"
  }
}
EOF
}

# Run program
parse_options "$@"

if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then
    disable_colors
fi

# Audit and exit for quiet checks
if [ "$QUIET_MODE" = "true" ]; then
    compile_audit
    # Fail if critical services are down
    if [ "$NGINX_STATUS" != "ACTIVE" ] || [ "$PHP_STATUS" != "ACTIVE" ] || [ "$MARIADB_STATUS" != "ACTIVE" ]; then
        exit 1
    fi
    exit 0
fi

if [ "$JSON_OUTPUT" = "true" ]; then
    generate_json_report
    exit 0
fi

# Direct output write option
if [ -n "$OUTPUT_FILE" ]; then
    echo -e "[*] Writing secure status report to: ${BOLD}${OUTPUT_FILE}${NC}"
    disable_colors
    generate_text_report > "$OUTPUT_FILE"
    exit 0
fi

# Print normal report
generate_text_report

# Prompt to write to file if not pre-specified
while true; do
    read -rp "Would you like to save this report to a text file? [y/n]: " yn < /dev/tty
    case $yn in
        [Yy]* )
            read -rp "Enter output file path [default: ./system_status_report.txt]: " user_path < /dev/tty
            user_path=${user_path:-"./system_status_report.txt"}
            disable_colors
            generate_text_report > "$user_path"
            echo -e "${GREEN}[✓] Status report written to: ${user_path}${NC}"
            break
            ;;
        [Nn]* )
            break
            ;;
        * ) echo "Please answer 'y' or 'n'.";;
    esac
done
