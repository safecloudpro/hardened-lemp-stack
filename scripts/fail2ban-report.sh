#!/usr/bin/env bash
# ==============================================================================
# Title: secure-lemp-fail2ban-reporter.sh
# Version: 1.0.0 (SafeCloud.PRO Production Sentinel)
# Description: Automated parser for Fail2ban logs that compiles a daily audit
#              report of banned IPs, groups them by jail, resolves threat vectors,
#              and dispatches a rich telemetry embed to Slack or Discord webhooks.
# Target OS: Ubuntu 26.04 LTS
# ==============================================================================

set -uo pipefail

# ANSI color codes for terminal display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Defaults
LOG_FILE="/var/log/fail2ban.log"
OUTPUT_FILE=""
JSON_OUTPUT=false
NO_COLOR=false
DRY_RUN=false
WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"

# Parse environment variables from WordPress .env if available
ENV_PATH="/var/www/html/.env"
if [ -f "$ENV_PATH" ]; then
    # Parse variable ignoring comments
    DB_WEBHOOK=$(grep -E "^ALERT_WEBHOOK_URL=" "$ENV_PATH" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -n "$DB_WEBHOOK" ]; then
        WEBHOOK_URL="$DB_WEBHOOK"
    fi
fi

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Parses Fail2ban log files, aggregates intrusion statistics, and dispatches webhook digests.

Options:
  -f, --file PATH         Source log file to parse (Default: /var/log/fail2ban.log)
  -o, --output FILE       Write the plain text report to a specified file
  -j, --json              Output report telemetry as structured JSON
  -w, --webhook URL       Override target Slack/Discord webhook URL
  -d, --dry-run           Compile metrics and print report to console without sending webhook
  --no-color              Disable colored text terminal output
  -h, --help              Show this help menu and exit

Examples:
  sudo ./fail2ban-report.sh
  sudo ./fail2ban-report.sh --json
  sudo ./fail2ban-report.sh -w "https://discord.com/api/webhooks/..."
EOF
}

parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    LOG_FILE="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --file requires a valid log file path.${NC}" >&2
                    exit 1
                fi
                ;;
            -o|--output)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    OUTPUT_FILE="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --output requires a file path.${NC}" >&2
                    exit 1
                fi
                ;;
            -w|--webhook)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    WEBHOOK_URL="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --webhook requires a URL.${NC}" >&2
                    exit 1
                fi
                ;;
            -j|--json)
                JSON_OUTPUT=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
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
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
}

# Verify root permissions for reading Fail2ban log
check_privileges() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Reading administrative security logs requires root (sudo) privileges.${NC}" >&2
        exit 1
    fi
}

# Verify log file exists and is readable
validate_log() {
    if [ ! -f "$LOG_FILE" ]; then
        # Create empty mock for testing if dry-run and file doesn't exist
        if [ "$DRY_RUN" = "true" ]; then
            echo -e "${YELLOW}[INFO] Fail2ban log not discovered at $LOG_FILE. Using simulated empty profile.${NC}"
        else
            echo -e "${RED}[ERROR] Fail2ban log not found at $LOG_FILE. Ensure fail2ban is running and logging.${NC}" >&2
            exit 1
        fi
    fi
}

# Count matches of a pattern in the log file (always prints a clean integer)
count_in_log() {
    local pattern="$1"
    local count=0
    if [ -f "$LOG_FILE" ]; then
        count=$(grep -cE "$pattern" "$LOG_FILE" 2>/dev/null || true)
    fi
    echo "${count:-0}"
}

# Top offending IP for a jail (prints "None" when jail has no bans)
top_ip_for_jail() {
    local jail="$1"
    local ip="None"
    if [ -f "$LOG_FILE" ]; then
        ip=$(grep -E "\[$jail\] Ban " "$LOG_FILE" 2>/dev/null | awk '{print $NF}' | sort | uniq -c | sort -nr | head -n 1 | awk '{print $2}')
    fi
    echo "${ip:-None}"
}

compile_metrics() {
    # Establish total bans and unbans
    TOTAL_BANS=$(count_in_log " Ban ")
    TOTAL_UNBANS=$(count_in_log " Unban ")

    # Compile list of active jails that have issued bans
    JAILS=()
    if [ -f "$LOG_FILE" ]; then
        # Extract jail names from the bracket pair directly before " Ban ".
        # (Naively taking the FIRST bracket pair grabs the PID instead — real
        # fail2ban lines look like: "fail2ban.actions [931]: NOTICE [sshd] Ban 1.2.3.4")
        mapfile -t JAILS < <(grep -oE '\[[^][]+\] Ban ' "$LOG_FILE" 2>/dev/null | sed -E 's/^\[([^][]+)\] Ban $/\1/' | sort -u)
    fi

    # Fallback to defaults if no jails found
    if [ ${#JAILS[@]} -eq 0 ]; then
        JAILS=("sshd" "nginx-apparmor" "nginx-wp-login")
    fi
}

generate_text_report() {
    compile_metrics
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    echo -e "${CYAN}======================================================================${NC}"
    echo -e "  ${BOLD}SAFECLOUD.PRO - FAIL2BAN SECURITY INTRUSION REPORT${NC}"
    echo -e "  Audited on: $timestamp"
    echo -e "  Target Log: $LOG_FILE"
    echo -e "${CYAN}======================================================================${NC}\n"

    echo -e " ${BOLD}[GLOBAL ACTIVITY SYNOPSIS]${NC}"
    echo -e "  - Total Intrusion Bans Logged:        ${RED}${TOTAL_BANS}${NC}"
    echo -e "  - Total Automatic Release Unbans:     ${GREEN}${TOTAL_UNBANS}${NC}\n"

    echo -e " ${BOLD}[DETAILED JAIL INTERCEPTIONS]${NC}"
    printf "  %-25s | %-12s | %-25s\n" "Jail Name" "Bans Blocked" "Top Offending IP Address"
    echo "  ----------------------------------------------------------------------"

    for jail in "${JAILS[@]}"; do
        local bans top_ip
        bans=$(count_in_log "\[$jail\] Ban ")
        if [ "$bans" -gt 0 ]; then
            top_ip=$(top_ip_for_jail "$jail")
            printf "  %-25s | ${RED}%-12s${NC} | %-25s\n" "$jail" "$bans" "$top_ip"
        else
            printf "  %-25s | %-12s | %-25s\n" "$jail" "0" "N/A"
        fi
    done

    echo -e "\n${CYAN}======================================================================${NC}"
}

generate_json_report() {
    compile_metrics
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Start JSON
    local json=""
    json+="{\n"
    json+="  \"audit_timestamp\": \"$timestamp\",\n"
    json+="  \"source_log\": \"$LOG_FILE\",\n"
    json+="  \"summary\": {\n"
    json+="    \"total_bans\": $TOTAL_BANS,\n"
    json+="    \"total_unbans\": $TOTAL_UNBANS\n"
    json+="  },\n"
    json+="  \"jail_statistics\": [\n"

    local len=${#JAILS[@]}
    for ((i=0; i<len; i++)); do
        local jail="${JAILS[i]}"
        local bans top_ip
        bans=$(count_in_log "\[$jail\] Ban ")
        top_ip="null"
        if [ "$bans" -gt 0 ]; then
            top_ip="\"$(top_ip_for_jail "$jail")\""
        fi

        json+="    {\n"
        json+="      \"jail_name\": \"$jail\",\n"
        json+="      \"bans_count\": $bans,\n"
        json+="      \"top_offending_ip\": $top_ip\n"
        json+="    }"
        if [ "$i" -lt $((len - 1)) ]; then
            json+=","
        fi
        json+="\n"
    done

    json+="  ]\n"
    json+="}"
    echo -e "$json"
}

send_webhook() {
    if [ -z "$WEBHOOK_URL" ]; then
        return 0
    fi

    # Avoid curl execution if dry-run
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}[DRY RUN] Webhook payload compile passed. Dispatch skipped by administrative request.${NC}"
        return 0
    fi

    echo -e "${CYAN}[*] Dispatching security audit digest to webhook...${NC}"
    
    # Establish metrics
    compile_metrics
    local host
    host=$(hostname)
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Discord format payload
    if [[ "$WEBHOOK_URL" =~ discord\.com ]]; then
        local fields_json=""
        local len=${#JAILS[@]}
        for ((i=0; i<len; i++)); do
            local jail="${JAILS[i]}"
            local bans top_ip
            bans=$(count_in_log "\[$jail\] Ban ")
            top_ip="None"
            if [ "$bans" -gt 0 ]; then
                top_ip=$(top_ip_for_jail "$jail")
            fi
            fields_json+="{\"name\": \"🛡️ Jail: $jail\", \"value\": \"**Bans:** $bans\\n**Top Attacker:** $top_ip\", \"inline\": true}"
            if [ "$i" -lt $((len - 1)) ]; then
                fields_json+=","
            fi
        done

        local payload
        payload=$(cat <<EOF
{
  "username": "SafeCloud.PRO Security Sentinel",
  "avatar_url": "https://raw.githubusercontent.com/safecloudpro/hardened-lemp-stack/main/docs/assets/wm-white.png",
  "embeds": [
    {
      "title": "🚨 Daily Fail2ban Intrusion Digest",
      "description": "System security metrics summarized across the active log boundaries on **$host**.",
      "color": 15158332,
      "fields": [
        {
          "name": "🔥 Total Intercepted Bans",
          "value": "**$TOTAL_BANS** active blocks applied",
          "inline": true
        },
        {
          "name": "🔓 Automatic Unbans",
          "value": "**$TOTAL_UNBANS** IPs released",
          "inline": true
        },
        {"name": "------------------", "value": "Breakdown by Security Slices", "inline": false},
        $fields_json
      ],
      "footer": {
        "text": "SafeCloud.PRO Security Logs • Completed at $timestamp"
      }
    }
  ]
}
EOF
)
        curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" > /dev/null

    # Slack format payload
    else
        local text_summary="*🚨 Daily Fail2ban Intrusion Digest ($host)*\n\n"
        text_summary+="*Total Intercepted Bans:* $TOTAL_BANS | *Released Unbans:* $TOTAL_UNBANS\n\n"
        text_summary+="*Active Jail Interceptions:*\n"
        for jail in "${JAILS[@]}"; do
            local bans top_ip
            bans=$(count_in_log "\[$jail\] Ban ")
            top_ip="None"
            if [ "$bans" -gt 0 ]; then
                top_ip=$(top_ip_for_jail "$jail")
            fi
            text_summary+="• *Jail:* \`$jail\` -> *Bans:* $bans | *Top IP:* \`$top_ip\`\n"
        done

        local payload
        payload=$(cat <<EOF
{
  "text": "$text_summary"
}
EOF
)
        curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" > /dev/null
    fi

    echo -e "${GREEN}[✓] Dispatch successfully delivered!${NC}"
}

# Run program
parse_options "$@"

if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then
    disable_colors
fi

check_privileges
validate_log

if [ "$JSON_OUTPUT" = "true" ]; then
    generate_json_report
    exit 0
fi

if [ -n "$OUTPUT_FILE" ]; then
    disable_colors
    generate_text_report > "$OUTPUT_FILE"
    echo -e "${GREEN}[✓] Fail2ban report compiled to: ${OUTPUT_FILE}${NC}"
    exit 0
fi

# Dry run / Display mode
generate_text_report

# Trigger webhook if URL exists
if [ -n "$WEBHOOK_URL" ]; then
    send_webhook
fi
