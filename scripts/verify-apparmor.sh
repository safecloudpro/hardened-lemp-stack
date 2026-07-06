#!/usr/bin/env bash
# ==============================================================================
# SafeCloud.PRO - Automated AppArmor Verification & Compliance Auditor
# Version: 1.0.0 (LTS Hardened)
# Description: On-demand automated script to run non-destructive security tests,
#              validate active AppArmor profile enforcement, and compile 
#              hardening compliance reports for auditors.
# Target OS: Ubuntu 26.04 LTS
# ==============================================================================

set -euo pipefail

# ANSI color codes for high-readability logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
EXPORT_TXT="/var/log/safecloud_apparmor_compliance.txt"

# Check root execution
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This verification script must be run as root (sudo) to query kernel states and simulate service users.${NC}" >&2
    exit 1
fi

print_header() {
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "  ${BOLD}SAFECLOUD.PRO APPARMOR AUTOMATED VERIFICATION ENGINE${NC}"
    echo -e "  Kernel-Enforced Confinement Verification | Ubuntu 26.04 LTS${NC}"
    echo -e "${CYAN}======================================================================${NC}\n"
}

# Print the mode (enforce/complain/"") a loaded AppArmor profile is in.
# aa-status lists profile names bare under section headers ("N profiles are in
# enforce mode."); the old "name (enforce)" suffix format no longer exists.
aa_profile_mode() {
    local prof="$1"
    aa-status 2>/dev/null | awk -v p="$prof" '
        /profiles are in enforce mode/  {s="enforce";  next}
        /profiles are in complain mode/ {s="complain"; next}
        /profiles are in/               {s="other";    next}
        /processes/                     {exit}
        s && $1 == p                    {print s; exit}'
}

# 1. System-Level Verification
check_apparmor_status() {
    echo -e "${BLUE}[1/5] Auditing System AppArmor Status...${NC}"
    if [ ! -d /sys/module/apparmor ]; then
        echo -e "  - Kernel Support:  ${RED}FAILED (AppArmor module not loaded)${NC}"
        return 1
    fi
    echo -e "  - Kernel Support:  ${GREEN}PASS (Active)${NC}"

    if ! aa-status &>/dev/null; then
        echo -e "  - Admin Utilities: ${RED}FAILED (aa-status utility not available)${NC}"
        return 1
    fi
    echo -e "  - Admin Utilities: ${GREEN}PASS (aa-status ready)${NC}"

    # Query active enforced profiles (aa-status --enforced prints the count directly)
    local enforced_count
    enforced_count=$(aa-status --enforced 2>/dev/null || true)
    enforced_count=${enforced_count:-0}
    echo -e "  - Active Enforced Profiles: ${BOLD}${enforced_count}${NC}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

# 2. Profile Presence and Enforce-Mode Audit
audit_profile_confinement() {
    echo -e "${BLUE}[2/5] Auditing Profile Confinement States...${NC}"
    
    # NOTE: path-attached profiles display in aa-status by binary path; the
    # PHP-FPM profile is a *named* profile ("profile php-fpm ...") and shows as "php-fpm".
    local profiles=("/usr/sbin/nginx" "php-fpm" "/usr/sbin/mariadbd" "/usr/sbin/redis-server")
    local display_names=(
        "Nginx Web Tier"
        "PHP-FPM Processing Pool"
        "MariaDB Persistence Layer"
        "Redis Object Caching Daemon"
    )

    for i in "${!profiles[@]}"; do
        local prof="${profiles[$i]}"
        local name="${display_names[$i]}"
        
        # Check if profile is active and in enforce mode
        case "$(aa_profile_mode "$prof")" in
            enforce)  echo -e "  - ${name} (${prof}): ${GREEN}ENFORCED (Secure)${NC}" ;;
            complain) echo -e "  - ${name} (${prof}): ${YELLOW}WARNING (Complain Mode)${NC}" ;;
            *)        echo -e "  - ${name} (${prof}): ${RED}FAILED (Unconfined/Not Loaded)${NC}" ;;
        esac
    done
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

# 3. Simulate and Verify Isolation Boundaries (Non-Destructive)
verify_isolation_boundaries() {
    echo -e "${BLUE}[3/5] Simulating Non-Destructive Vulnerability Vectors...${NC}"

    # Test 3.1: Web-user Write Containment (defense-in-depth: file permissions layer)
    # NOTE: this exercises the DAC/file-permission layer as the www-data user; the
    # AppArmor profile additionally denies these writes for the confined daemons.
    echo -e "  - Test 3.1: simulating web user (www-data) writing to protected code directories..."
    if [ -d /var/www/html/wp-admin ]; then
        if sudo -u www-data touch /var/www/html/wp-admin/malicious_skimmer.php 2>/dev/null; then
            echo -e "    ${RED}[VIOLATION] Web user (www-data) successfully wrote to wp-admin!${NC}"
            rm -f /var/www/html/wp-admin/malicious_skimmer.php
        else
            echo -e "    ${GREEN}[SUCCESS] Write to wp-admin blocked for www-data (Permission Denied).${NC}"
        fi
    else
        echo -e "    ${YELLOW}[SKIP] /var/www/html/wp-admin not found (Clean environment).${NC}"
    fi

    # Test 3.2: PHP-FPM execution block
    echo -e "  - Test 3.2: verifying PHP uploads execution isolation..."
    if [ -d /var/www/html/wp-content/uploads ]; then
        # Check if dummy PHP script can be executed as www-data via local PHP runtime CLI if confined
        # Note: True PHP-FPM runs via socket. We can verify if executions in uploads are forbidden.
        # This checks the file directory setup.sh configuration parameter.
        if [ -f /etc/nginx/sites-available/wordpress ]; then
            if grep -q "location ~\* ^/wp-content/uploads/.*\.php" /etc/nginx/sites-available/wordpress 2>/dev/null; then
                echo -e "    ${GREEN}[SUCCESS] Nginx config blocks executing raw PHP in uploads (TryFiles deny matched).${NC}"
            else
                echo -e "    ${YELLOW}[WARNING] Nginx uploads PHP block missing in active configuration file.${NC}"
            fi
        fi
    else
        echo -e "    ${YELLOW}[SKIP] /var/www/html/wp-content/uploads not found.${NC}"
    fi

    # Test 3.3: Database-user Write Containment (defense-in-depth: file permissions layer)
    echo -e "  - Test 3.3: simulating database user (mysql) writing to Nginx web root..."
    if [ -d /var/www/html/wp-content/uploads ]; then
        if sudo -u mysql touch /var/www/html/wp-content/uploads/database_dump.txt 2>/dev/null; then
            echo -e "    ${RED}[VIOLATION] Database user (mysql) successfully wrote to web root uploads!${NC}"
            rm -f /var/www/html/wp-content/uploads/database_dump.txt
        else
            echo -e "    ${GREEN}[SUCCESS] Write to web root blocked for mysql user (Permission Denied).${NC}"
        fi
    else
        echo -e "    ${YELLOW}[SKIP] Uploads directory not found.${NC}"
    fi

    # Test 3.4: Redis Network Isolation
    echo -e "  - Test 3.4: validating Redis local loopback and port binding restriction..."
    if [ -f /etc/redis/redis.conf ]; then
        if grep -q "^port 0" /etc/redis/redis.conf 2>/dev/null; then
            echo -e "    ${GREEN}[SUCCESS] Redis configured to bind exclusively to memory domain UNIX sockets (Port 0 active).${NC}"
        else
            echo -e "    ${YELLOW}[WARNING] Redis TCP listening port is enabled. Ensure network firewall is active.${NC}"
        fi
    else
        echo -e "    ${YELLOW}[SKIP] /etc/redis/redis.conf not found.${NC}"
    fi
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

# 4. Compile Kernel AVC Denials
compile_kernel_denials() {
    echo -e "${BLUE}[4/5] Counting Kernel AVC Violation Events...${NC}"
    
    local aa_logs=""
    if [ -f /var/log/audit/audit.log ]; then
        aa_logs=$(tail -n 1000 /var/log/audit/audit.log 2>/dev/null || echo "")
    else
        aa_logs=$(dmesg | tail -n 1000)
    fi

    # grep -c already prints 0 on no-match; "|| true" only guards the non-zero exit
    local nginx_denials
    nginx_denials=$(echo "$aa_logs" | grep -c 'profile="/usr/sbin/nginx"' || true)
    local php_denials
    php_denials=$(echo "$aa_logs" | grep -c 'profile="php-fpm"' || true)
    local db_denials
    db_denials=$(echo "$aa_logs" | grep -c 'profile="/usr/sbin/mariadbd"' || true)
    local redis_denials
    redis_denials=$(echo "$aa_logs" | grep -c 'profile="/usr/sbin/redis-server"' || true)

    echo -e "  - Nginx Web Tier Blocked Actions:     ${BOLD}${nginx_denials}${NC}"
    echo -e "  - PHP-FPM Pool Blocked Actions:       ${BOLD}${php_denials}${NC}"
    echo -e "  - MariaDB Database Blocked Actions:   ${BOLD}${db_denials}${NC}"
    echo -e "  - Redis Memory Cache Blocked Actions: ${BOLD}${redis_denials}${NC}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

# 5. Export Audit Report
generate_audit_report() {
    echo -e "${BLUE}[5/5] Compiling Auditor-Ready Compliance Document...${NC}"
    
    {
        echo "======================================================================"
        echo "   SAFECLOUD.PRO APPARMOR SECURITY HARDENING AUDIT & COMPLIANCE REPORT"
        echo "   Generated on: $(date)"
        echo "   Host Substrate: $(hostname) ($(uname -r))"
        echo "   License Scope: Apache License 2.0 (Open-Source)"
        echo "======================================================================"
        echo ""
        echo "1. SYSTEM LEVEL STATUS"
        echo "----------------------------------------------------------------------"
        if [ -d /sys/module/apparmor ]; then
            echo "  AppArmor Kernel Module: ACTIVE"
        else
            echo "  AppArmor Kernel Module: INACTIVE"
        fi
        echo "  Active Profiles: $(aa-status --enforced 2>/dev/null || echo 0)"
        echo ""
        echo "2. SERVICE CONFINEMENT COMPLIANCE SUMMARY"
        echo "----------------------------------------------------------------------"
        for prof in "/usr/sbin/nginx" "php-fpm" "/usr/sbin/mariadbd" "/usr/sbin/redis-server"; do
            if [ "$(aa_profile_mode "$prof")" = "enforce" ]; then
                printf "  %-30s | COMPLIANT (Enforced)\n" "${prof}"
            else
                printf "  %-30s | NON-COMPLIANT (Unconfined)\n" "${prof}"
            fi
        done
        echo ""
        echo "3. AUDIT SIGN-OFF"
        echo "----------------------------------------------------------------------"
        echo "  Report generated by: SafeCloud.PRO AppArmor verification tooling"
        echo "  Compliance status: see per-service confinement summary in section 2."
        echo "======================================================================"
    } > "$EXPORT_TXT"

    echo -e "  ${GREEN}[✓] Compliance report successfully saved to:${NC}"
    echo -e "      - ${BOLD}${EXPORT_TXT}${NC}\n"
}

# Main execution loop
print_header
check_apparmor_status
audit_profile_confinement
verify_isolation_boundaries
compile_kernel_denials
generate_audit_report
