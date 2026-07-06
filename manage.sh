#!/usr/bin/env bash
# ==============================================================================
# Title: manage.sh
# Version: 1.0.0 (SafeCloud.PRO)
# Purpose: One discoverable entry point for the whole toolkit. Thin dispatcher —
#          each subcommand just runs the matching script and forwards your args.
#
#   ./manage.sh help
#   ./manage.sh lint                 # shellcheck + bash -n across all scripts
#   ./manage.sh test                 # bats unit tests (lib/sizing.sh)
#   ./manage.sh plan                 # setup.sh --dry-run
#   sudo ./manage.sh setup -y        # run the provisioner (args forwarded)
#   sudo ./manage.sh backup --encrypt
# ==============================================================================

set -uo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
else
    GREEN=''; CYAN=''; BOLD=''; YELLOW=''; NC=''
fi
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat << EOF
${BOLD}SafeCloud.PRO — Hardened LEMP Stack${NC}
Usage: $(basename "$0") <command> [args...]

${BOLD}Provisioning & lifecycle${NC}
  setup           Run the master provisioner (setup.sh)           [args forwarded]
  plan            Preview the sizing budget (setup.sh --dry-run)
  provision       Create the WP database + user + install WordPress (wordpress-provision.sh)
  cert            Install a Cloudflare Origin certificate (install-cloudflare-cert.sh)
  harden          Apply WordPress app-layer hardening (harden-wordpress.sh)
  redis-cache     Enable the Redis object cache drop-in (enable-redis-cache.sh)
  tune            Re-tune the stack to this host's RAM/CPU (tune-stack.sh)

${BOLD}Edge / firewall${NC}
  realip          Restore the real visitor IP behind Cloudflare (configure-cloudflare-realip.sh)
  sg              Generate the Cloudflare→EC2 Security Group commands (configure-security-group.sh)

${BOLD}Backup${NC}
  backup          Back up DB + wp-content + wp-config (backup.sh)
  restore         Restore a backup (restore.sh)

${BOLD}Audit & ops${NC}
  audit           Full stack security/config audit (scripts/status-report.sh)
  verify          AppArmor confinement verification (scripts/verify-apparmor.sh)
  fail2ban-report Ban statistics digest (scripts/fail2ban-report.sh)
  benchmark       Performance & sizing benchmark (scripts/performance-benchmark.sh)

${BOLD}Development${NC}
  lint            shellcheck + bash -n over every script
  test            Run the bats unit tests (tests/)
  help            Show this help

Any extra arguments are passed straight through to the underlying script, e.g.
  sudo $(basename "$0") tune --dry-run
EOF
}

run() { local s="$DIR/$1"; shift; [ -f "$s" ] || { echo "Missing script: $s" >&2; exit 1; }; exec bash "$s" "$@"; }

cmd_lint() {
    local rc=0
    mapfile -t sh < <(grep -rIlE '^#!.*(bash|sh)' "$DIR" --include='*.sh' | grep -v '/.git/')
    echo -e "${CYAN}[*] bash -n (${#sh[@]} scripts)...${NC}"
    for f in "${sh[@]}"; do bash -n "$f" || { echo "  syntax FAIL: $f"; rc=1; }; done
    if command -v shellcheck >/dev/null 2>&1; then
        echo -e "${CYAN}[*] shellcheck...${NC}"
        shellcheck -x "${sh[@]}" || rc=1
    else
        echo -e "${YELLOW}[!] shellcheck not installed — skipped (apt-get install -y shellcheck).${NC}"
    fi
    [ "$rc" -eq 0 ] && echo -e "${GREEN}[✓] lint clean.${NC}"
    return "$rc"
}

cmd_test() {
    command -v bats >/dev/null 2>&1 || { echo -e "${YELLOW}[!] bats not installed (apt-get install -y bats).${NC}"; exit 1; }
    exec bats "$DIR/tests/"
}

CMD="${1:-help}"; shift || true
case "$CMD" in
    setup)            run "setup.sh" "$@";;
    plan)             run "setup.sh" --dry-run "$@";;
    provision)        run "wordpress-provision.sh" "$@";;
    cert)             run "install-cloudflare-cert.sh" "$@";;
    harden)           run "harden-wordpress.sh" "$@";;
    redis-cache)      run "enable-redis-cache.sh" "$@";;
    tune)             run "tune-stack.sh" "$@";;
    realip)           run "configure-cloudflare-realip.sh" "$@";;
    sg)               run "configure-security-group.sh" "$@";;
    backup)           run "backup.sh" "$@";;
    restore)          run "restore.sh" "$@";;
    audit)            run "scripts/status-report.sh" "$@";;
    verify)           run "scripts/verify-apparmor.sh" "$@";;
    fail2ban-report)  run "scripts/fail2ban-report.sh" "$@";;
    benchmark)        run "scripts/performance-benchmark.sh" "$@";;
    lint)             cmd_lint;;
    test)             cmd_test;;
    help|-h|--help)   usage;;
    *)                echo "Unknown command: $CMD" >&2; echo; usage; exit 1;;
esac
