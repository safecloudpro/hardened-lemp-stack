#!/usr/bin/env bash
# =============================================================================
# Title: alert-apparmor-status.sh
# Version: 1.0.0 (SafeCloud.PRO Monitoring Suite)
# Description: On-demand audit runner and real-time AppArmor denial sweeper
#              that dispatches structured alerts to Discord/Slack webhooks.
# Target OS: Ubuntu 26.04 LTS
# =============================================================================

set -uo pipefail

# ANSI color codes for administrative debugging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values (Overridden via environment variables or .env file)
WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
STATE_DIR="/var/lib/safecloud"
LAST_LINE_FILE="${STATE_DIR}/apparmor_last_line.txt"
STATUS_SCRIPT_PATH="/usr/local/bin/status-report.sh"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Sweeps system logs for recent AppArmor denials and queries system health via status-report.sh,
then dispatches immediate telemetry alerts to Discord/Slack webhooks.

Options:
  -w, --webhook URL    Specify the Discord/Slack Webhook URL directly
  -s, --status PATH    Path to status-report.sh script (Default: /usr/local/bin/status-report.sh)
  -h, --help           Show this help menu and exit

This script must be run with root or sudo privileges to access kernel audit logs.
EOF
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--webhook)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                WEBHOOK_URL="$2"
                shift 2
            else
                echo -e "${RED}[ERROR] --webhook requires a URL value.${NC}" >&2
                exit 1
            fi
            ;;
        -s|--status)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                STATUS_SCRIPT_PATH="$2"
                shift 2
            else
                echo -e "${RED}[ERROR] --status requires a valid file path.${NC}" >&2
                exit 1
            fi
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

# Ensure root access for log sweeping
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This alerting engine must be run as root (sudo) to access kernel security logs.${NC}" >&2
    exit 1
fi

# Load local environment configurations if present
if [ -f "./.env" ]; then
    # Parse whitelisted variables from .env to prevent injection
    ENV_URL=$(grep -E "^ALERT_WEBHOOK_URL=" "./.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -n "$ENV_URL" ] && [ -z "$WEBHOOK_URL" ]; then
        WEBHOOK_URL="$ENV_URL"
    fi
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo -e "${YELLOW}[WARNING] No ALERT_WEBHOOK_URL specified. Alerts will be printed to stdout only.${NC}"
fi

if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}[WARNING] 'jq' not found — service states will report as UNKNOWN. Install via: apt-get install jq${NC}"
fi

# Initialize persistent state directory
mkdir -p "$STATE_DIR"
if [ ! -f "$LAST_LINE_FILE" ]; then
    # On first run, baseline to the end of the current log to prevent alarm storms
    if [ -f "/var/log/audit/audit.log" ]; then
        wc -l < /var/log/audit/audit.log | tr -d ' ' > "$LAST_LINE_FILE"
    else
        echo "0" > "$LAST_LINE_FILE"
    fi
fi

# 1. SWEEP APPARMOR LOGS FOR DENIALS
check_apparmor_denials() {
    local log_file=""
    if [ -f "/var/log/audit/audit.log" ]; then
        log_file="/var/log/audit/audit.log"
    elif [ -f "/var/log/syslog" ]; then
        log_file="/var/log/syslog"
    fi

    if [ -z "$log_file" ]; then
        echo "NO_LOGS"
        return 0
    fi

    local last_line
    last_line=$(cat "$LAST_LINE_FILE")
    local current_line_count
    current_line_count=$(wc -l < "$log_file" | tr -d ' ')

    # If log rotated or is smaller, reset pointer
    if [ "$current_line_count" -lt "$last_line" ]; then
        last_line=0
    fi

    local lines_to_read=$((current_line_count - last_line))
    local denials=""

    if [ "$lines_to_read" -gt 0 ]; then
        # Sweep only the newly appended log segment for "denied" or "apparmor=\"DENIED\""
        denials=$(tail -n "$lines_to_read" "$log_file" | grep -Ei "apparmor=\"DENIED\"|denied_mask" || true)
    fi

    # Save the updated cursor state
    echo "$current_line_count" > "$LAST_LINE_FILE"

    if [ -n "$denials" ]; then
        echo "$denials"
    else
        echo "CLEAN"
    fi
}

# 2. RUN STATUS AUDITOR (JSON output)
run_status_audit() {
    if [ -x "$STATUS_SCRIPT_PATH" ]; then
        "$STATUS_SCRIPT_PATH" --json
    else
        # Fallback raw payload if status-report.sh isn't deployed locally
        cat << EOF
{
  "audit_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "system_and_edge": { "nginx_server_status": "UNKNOWN" },
  "application_layer": { "php_fpm_status": "UNKNOWN" },
  "persistence_layer": { "mariadb_status": "UNKNOWN" }
}
EOF
    fi
}

# 3. CONSTRUCT SECURE POST PAYLOAD AND DISPATCH
dispatch_alert() {
    local audit_json="$1"
    local apparmor_status="$2"
    
    # Parse JSON values safely using jq (fallbacks defined)
    local nginx_status
    nginx_status=$(echo "$audit_json" | jq -r '.system_and_edge.nginx_server_status' 2>/dev/null || echo "UNKNOWN")
    local php_status
    php_status=$(echo "$audit_json" | jq -r '.application_layer.php_fpm_status' 2>/dev/null || echo "UNKNOWN")
    local mariadb_status
    mariadb_status=$(echo "$audit_json" | jq -r '.persistence_layer.mariadb_status' 2>/dev/null || echo "UNKNOWN")

    local status_color=65280 # Green (Decimal for Discord Embeds)
    local description="All core e-commerce services are running smoothly inside their hardened compartments."

    if [ "$nginx_status" != "ACTIVE" ] || [ "$php_status" != "ACTIVE" ] || [ "$mariadb_status" != "ACTIVE" ]; then
        status_color=16711680 # Red
        description="CRITICAL SERVICE OUTAGE DETECTED! One or more services are offline or failing health audits."
    fi

    local apparmor_field_title="🛡️ AppArmor Core Violations"
    local apparmor_field_val="No kernel access control violations detected in this sweep interval."

    if [ "$apparmor_status" != "CLEAN" ] && [ "$apparmor_status" != "NO_LOGS" ]; then
        status_color=16753920 # Orange
        # Flatten to one line here; JSON escaping happens once, below, for both
        # branches (escaping in both places produced \\" and broke the payload).
        apparmor_field_val=$(echo "$apparmor_status" | head -n 3 | tr '\n' ' ')
        description="AppArmor MANDATORY ACCESS CONTROL VIOLATION! Host kernel has actively blocked an unauthorized filesystem or process call."
    fi

    # Escape JSON string special characters (backslashes first, then quotes)
    description=$(echo "$description" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    apparmor_field_val=$(echo "$apparmor_field_val" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

    # Construct complete JSON payload for Discord/Slack webhook
    local payload
    payload=$(cat << EOF
{
  "username": "SafeCloud.PRO Security Sentinel",
  "avatar_url": "https://raw.githubusercontent.com/safecloudpro/hardened-lemp-stack/main/docs/assets/wm-white.png",
  "embeds": [
    {
      "title": "System Hardening & Observability Audit",
      "description": "${description}",
      "color": ${status_color},
      "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
      "fields": [
        {
          "name": "🌐 Nginx Web Gateway",
          "value": "\`${nginx_status}\`",
          "inline": true
        },
        {
          "name": "⚙️ PHP-FPM Engine",
          "value": "\`${php_status}\`",
          "inline": true
        },
        {
          "name": "🗄️ MariaDB Database",
          "value": "\`${mariadb_status}\`",
          "inline": true
        },
        {
          "name": "${apparmor_field_title}",
          "value": "\`\`\`${apparmor_field_val}\`\`\`"
        }
      ],
      "footer": {
        "text": "SafeCloud.PRO Node Audit • Host: $(hostname)"
      }
    }
  ]
}
EOF
)

    if [ -n "$WEBHOOK_URL" ]; then
        # Post payload strictly to the HTTPS endpoint via curl
        if curl -fsS --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload" "$WEBHOOK_URL" > /dev/null; then
            echo -e "${GREEN}[✓] Telemetry alert successfully dispatched to Webhook Endpoint.${NC}"
        else
            echo -e "${RED}[ERROR] Webhook dispatch failed (endpoint unreachable or rejected payload).${NC}" >&2
        fi
    else
        echo -e "${YELLOW}[INFO] Webhook alert output payload:${NC}\n$payload\n"
    fi
}

# --- MAIN EXECUTION PIPELINE ---
echo -e "${CYAN}[*] Initiating SafeCloud.PRO Security Sentinel Sweeper...${NC}"

APPARMOR_RESULTS=$(check_apparmor_denials)
AUDIT_JSON=$(run_status_audit)

# Only alert if an incident has occurred (service is down or AppArmor blocked an intrusion)
if [ "$APPARMOR_RESULTS" != "CLEAN" ] || [ "$(echo "$AUDIT_JSON" | jq -r '.system_and_edge.nginx_server_status' 2>/dev/null)" != "ACTIVE" ] || [ "$(echo "$AUDIT_JSON" | jq -r '.application_layer.php_fpm_status' 2>/dev/null)" != "ACTIVE" ] || [ "$(echo "$AUDIT_JSON" | jq -r '.persistence_layer.mariadb_status' 2>/dev/null)" != "ACTIVE" ]; then
    echo -e "${RED}[🚨] INCIDENT DETECTED! Formulating emergency security payload...${NC}"
    dispatch_alert "$AUDIT_JSON" "$APPARMOR_RESULTS"
else
    echo -e "${GREEN}[✓] System scan complete. No service outages or AppArmor violations discovered.${NC}"
fi
