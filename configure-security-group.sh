#!/usr/bin/env bash
# ==============================================================================
# Title: configure-security-group.sh
# Version: 2.0.0 (SafeCloud.PRO)
# Purpose: GENERATE the exact AWS CLI commands that lock this EC2 instance's
#          inbound firewall to Cloudflare's edge — it does NOT call AWS itself.
#
#          The script pulls Cloudflare's CURRENT published IP ranges, reads this
#          instance's identity from IMDSv2 (instance-id, VPC, region, public IP),
#          and writes a ready-to-run shell script of `aws ec2 ...` commands with
#          those real identifiers baked in. You then review it and run it in a
#          console/session that holds AWS credentials with EC2 permissions.
#
#          Because Cloudflare publishes 22 ranges (15 IPv4 + 7 IPv6), the emitted
#          commands build two customer-managed PREFIX LISTS and reference them
#          from the Security Group — the AWS-recommended pattern that stays under
#          the 60-rule-per-SG quota. The Security Group is ADDED alongside the
#          instance's existing groups (never replacing them), so an active SSH
#          session can't be cut.
#
#   ./configure-security-group.sh                     # generate ./cloudflare-sg-commands.sh
#   ./configure-security-group.sh --mode public       # 0.0.0.0/0 instead of Cloudflare
#   ./configure-security-group.sh -o /tmp/sg.sh       # choose the output path
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

# ----- config / defaults ------------------------------------------------------
MODE="cloudflare"          # cloudflare | public | custom
SG_NAME="safecloud-cloudflare-origin"
PL4_NAME="safecloud-cloudflare-v4"
PL6_NAME="safecloud-cloudflare-v6"
OPEN_HTTP=true             # 80/tcp (Cloudflare still hits :80 for the HTTPS redirect)
OPEN_QUIC=true             # 443/udp (HTTP/3)
SSH_CIDR="auto"            # auto = this box's current public IP /32 ; or CIDR ; or none
OUTPUT_FILE="./cloudflare-sg-commands.sh"
NO_COLOR=false
REGION_OVERRIDE=""; INSTANCE_OVERRIDE=""; VPC_OVERRIDE=""
CF_V4_URL="https://www.cloudflare.com/ips-v4"
CF_V6_URL="https://www.cloudflare.com/ips-v6"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generate the AWS CLI commands that restrict this EC2 instance's inbound web
traffic to Cloudflare (or anywhere / a custom set). Writes a runnable script;
it does NOT call AWS itself — run the generated script where credentials exist.

Options:
  --mode MODE        cloudflare (default) | public | custom
                       cloudflare : 80/443 TCP + 443 UDP from Cloudflare ranges only
                       public     : 80/443 TCP + 443 UDP from 0.0.0.0/0 and ::/0
                       custom     : interactive port/source picker
  --ssh-cidr CIDR    SSH (22/tcp) source: 'auto' = this box's public IP/32,
                     a CIDR like 203.0.113.10/32, or 'none' (default: auto).
  --no-http          Do not open 80/tcp (only 443).
  --no-quic          Do not open 443/udp (HTTP/3 QUIC).
  --sg-name NAME     Security Group name (default: ${SG_NAME}).
  -o, --output FILE  Where to write the generated commands (default: ${OUTPUT_FILE}).
  --region REGION    Override the auto-detected region (baked into the commands).
  --instance-id ID   Override the auto-detected instance id.
  --vpc-id ID        Override the auto-detected VPC id.
  --no-color         Disable coloured output.
  -h, --help         Show this help and exit.

The generated script is idempotent (reuses an existing prefix list / SG by name)
and needs these IAM actions when you run it: ec2 Describe*, Create/Modify on
managed-prefix-list and security-group, AuthorizeSecurityGroupIngress, and
ModifyInstanceAttribute.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)        [ -n "${2:-}" ] || { err "--mode needs a value"; exit 1; }; MODE="$2"; shift 2;;
        --ssh-cidr)    [ -n "${2:-}" ] || { err "--ssh-cidr needs a value"; exit 1; }; SSH_CIDR="$2"; shift 2;;
        --no-http)     OPEN_HTTP=false; shift;;
        --no-quic)     OPEN_QUIC=false; shift;;
        --sg-name)     [ -n "${2:-}" ] || { err "--sg-name needs a value"; exit 1; }; SG_NAME="$2"; shift 2;;
        -o|--output)   [ -n "${2:-}" ] || { err "--output needs a path"; exit 1; }; OUTPUT_FILE="$2"; shift 2;;
        --region)      [ -n "${2:-}" ] || { err "--region needs a value"; exit 1; }; REGION_OVERRIDE="$2"; shift 2;;
        --instance-id) [ -n "${2:-}" ] || { err "--instance-id needs a value"; exit 1; }; INSTANCE_OVERRIDE="$2"; shift 2;;
        --vpc-id)      [ -n "${2:-}" ] || { err "--vpc-id needs a value"; exit 1; }; VPC_OVERRIDE="$2"; shift 2;;
        --no-color)    NO_COLOR=true; shift;;
        -h|--help)     show_help; exit 0;;
        *)             err "Unknown option: $1"; show_help; exit 1;;
    esac
done

if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi
case "$MODE" in cloudflare|public|custom) ;; *) err "Invalid --mode '$MODE'."; exit 1;; esac

echo -e "${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}SAFECLOUD.PRO — CLOUDFLARE EDGE SECURITY GROUP (COMMAND GENERATOR)${NC}"
echo -e "${CYAN}======================================================================${NC}\n"

# ==============================================================================
# 1. Cloudflare's current ranges
# ==============================================================================
info "Fetching Cloudflare's current published IP ranges..."
mapfile -t CF_V4 < <(curl -fsSL --max-time 20 "$CF_V4_URL" | grep -E '^[0-9]+\.' || true)
mapfile -t CF_V6 < <(curl -fsSL --max-time 20 "$CF_V6_URL" | grep -E '^[0-9a-fA-F:]+/' || true)
if [ "${#CF_V4[@]}" -eq 0 ]; then
    err "Could not retrieve Cloudflare IPv4 ranges from ${CF_V4_URL}. Check outbound connectivity."
    exit 1
fi
info "Retrieved ${BOLD}${#CF_V4[@]}${NC} IPv4 and ${BOLD}${#CF_V6[@]}${NC} IPv6 Cloudflare ranges."

# ==============================================================================
# 2. Identify this EC2 instance via IMDSv2 (overridable)
# ==============================================================================
imds() {
    local path="$1" token
    token=$(curl -sS --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 120" 2>/dev/null) || return 1
    [ -n "$token" ] || return 1
    curl -sS --max-time 3 -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null
}

info "Reading this instance's identity (IMDSv2)..."
INSTANCE_ID="${INSTANCE_OVERRIDE:-$(imds instance-id || true)}"
REGION="${REGION_OVERRIDE:-$(imds placement/region || true)}"
MAC=$(imds mac || true)
VPC_ID="${VPC_OVERRIDE:-$(imds "network/interfaces/macs/${MAC}/vpc-id" || true)}"
PUBLIC_IP=$(imds public-ipv4 || true)

: "${INSTANCE_ID:=<INSTANCE_ID>}"
: "${REGION:=<REGION>}"
: "${VPC_ID:=<VPC_ID>}"
MISSING=false
for v in "$INSTANCE_ID" "$REGION" "$VPC_ID"; do [[ "$v" == \<* ]] && MISSING=true; done
$MISSING && warn "Some instance details could not be auto-detected (run this ON the target EC2, or pass --instance-id/--vpc-id/--region). Placeholders are left in the output for you to fill in."

echo -e "  Instance: ${BOLD}${INSTANCE_ID}${NC}   Region: ${BOLD}${REGION}${NC}   VPC: ${BOLD}${VPC_ID}${NC}   Public IP: ${BOLD}${PUBLIC_IP:-none}${NC}"

# Resolve SSH source.
SSH_SOURCE=""
case "$SSH_CIDR" in
    none) SSH_SOURCE="";;
    auto) if [ -n "$PUBLIC_IP" ]; then SSH_SOURCE="${PUBLIC_IP}/32"
          else warn "No public IP detected; no SSH rule will be generated (existing SGs keep your access)."; fi;;
    *)    SSH_SOURCE="$SSH_CIDR";;
esac

# ==============================================================================
# 3. Custom prompts / port set
# ==============================================================================
if [ "$MODE" = "custom" ]; then
    hr; echo -e "${BOLD}Custom mode${NC} (Enter accepts the shown default)."
    read -rp "Open 80/tcp (HTTP→HTTPS redirect)? [Y/n]: " a < /dev/tty; case "${a:-y}" in [Nn]*) OPEN_HTTP=false;; *) OPEN_HTTP=true;; esac
    read -rp "Open 443/udp (HTTP/3 QUIC)? [Y/n]: " a < /dev/tty; case "${a:-y}" in [Nn]*) OPEN_QUIC=false;; *) OPEN_QUIC=true;; esac
    read -rp "Web source — [c]loudflare only or [p]ublic 0.0.0.0/0? [C/p]: " a < /dev/tty; case "${a:-c}" in [Pp]*) MODE=public;; *) MODE=cloudflare;; esac
fi

# ==============================================================================
# 4. Generate the command script
# ==============================================================================
CF4_ENTRIES=""; for c in "${CF_V4[@]}"; do CF4_ENTRIES+="Cidr=$c "; done
CF6_ENTRIES=""; for c in "${CF_V6[@]}"; do CF6_ENTRIES+="Cidr=$c "; done
V4_MAXENT=$(( ${#CF_V4[@]} + 10 ))
V6_MAXENT=$(( ${#CF_V6[@]} + 10 ))
GEN_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUT_BASE=$(basename "$OUTPUT_FILE")

# Header (values interpolated now) ...
{
cat <<EOF
#!/usr/bin/env bash
# ==============================================================================
# AWS CLI commands to restrict EC2 ingress to Cloudflare — GENERATED ARTIFACT
# Generated by configure-security-group.sh on ${GEN_DATE}
# Instance ${INSTANCE_ID} / VPC ${VPC_ID} / region ${REGION}
#
# REVIEW, then run where AWS credentials with EC2 permissions are active:
#     aws sts get-caller-identity        # confirm the right account/role
#     bash ${OUT_BASE}
# Idempotent: reuses an existing prefix list / SG of the same name.
# ==============================================================================
set -euo pipefail
export AWS_PAGER=""

REGION="${REGION}"
VPC_ID="${VPC_ID}"
INSTANCE_ID="${INSTANCE_ID}"
SG_NAME="${SG_NAME}"
PL4_NAME="${PL4_NAME}"
PL6_NAME="${PL6_NAME}"
MODE="${MODE}"
SSH_SOURCE="${SSH_SOURCE}"
OPEN_HTTP="${OPEN_HTTP}"
OPEN_QUIC="${OPEN_QUIC}"
V4_MAXENT="${V4_MAXENT}"
V6_MAXENT="${V6_MAXENT}"
CF_V4_ENTRIES="${CF4_ENTRIES}"
CF_V6_ENTRIES="${CF6_ENTRIES}"
EOF

# Static body (NOT interpolated — quoted heredoc).
cat <<'EOS'

AWS=(aws --region "$REGION")
find_pl(){ "${AWS[@]}" ec2 describe-managed-prefix-lists --filters "Name=prefix-list-name,Values=$1" --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null || echo None; }

PL4=""; PL6=""
if [ "$MODE" = "cloudflare" ]; then
  PL4=$(find_pl "$PL4_NAME")
  if [ "$PL4" = "None" ] || [ -z "$PL4" ]; then
    # shellcheck disable=SC2086
    PL4=$("${AWS[@]}" ec2 create-managed-prefix-list --prefix-list-name "$PL4_NAME" \
      --address-family IPv4 --max-entries "$V4_MAXENT" --entries $CF_V4_ENTRIES \
      --query 'PrefixList.PrefixListId' --output text)
    echo "Created IPv4 prefix list $PL4_NAME = $PL4"
  else echo "Reusing IPv4 prefix list $PL4_NAME = $PL4"; fi
  if [ -n "${CF_V6_ENTRIES// }" ]; then
    PL6=$(find_pl "$PL6_NAME")
    if [ "$PL6" = "None" ] || [ -z "$PL6" ]; then
      # shellcheck disable=SC2086
      PL6=$("${AWS[@]}" ec2 create-managed-prefix-list --prefix-list-name "$PL6_NAME" \
        --address-family IPv6 --max-entries "$V6_MAXENT" --entries $CF_V6_ENTRIES \
        --query 'PrefixList.PrefixListId' --output text)
      echo "Created IPv6 prefix list $PL6_NAME = $PL6"
    else echo "Reusing IPv6 prefix list $PL6_NAME = $PL6"; fi
  fi
fi

SG_ID=$("${AWS[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$("${AWS[@]}" ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "SafeCloud.PRO Cloudflare edge ingress" --query 'GroupId' --output text)
  echo "Created Security Group $SG_NAME = $SG_ID"
else echo "Reusing Security Group $SG_NAME = $SG_ID"; fi

web_src(){
  if [ "$MODE" = "cloudflare" ]; then
    local s="PrefixListIds=[{PrefixListId=$PL4}"
    [ -n "$PL6" ] && s="$s,{PrefixListId=$PL6}"
    echo "$s]"
  else
    echo 'IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]'
  fi
}
WS=$(web_src)
add_rule(){ # proto port source
  if "${AWS[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --ip-permissions "IpProtocol=$1,FromPort=$2,ToPort=$2,$3" >/dev/null 2>&1; then
    echo "  + authorized $1/$2"
  else
    echo "  = $1/$2 already present (or skipped)"
  fi
}

[ "$OPEN_HTTP" = "true" ] && add_rule tcp 80  "$WS"
add_rule tcp 443 "$WS"
[ "$OPEN_QUIC" = "true" ] && add_rule udp 443 "$WS"
[ -n "$SSH_SOURCE" ] && add_rule tcp 22 "IpRanges=[{CidrIp=$SSH_SOURCE,Description=admin-ssh}]"

# Attach our SG ALONGSIDE the instance's existing groups (never replace them).
EXISTING=$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)
UNION=$(printf '%s %s\n' "$EXISTING" "$SG_ID" | tr ' \t' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
# shellcheck disable=SC2086
"${AWS[@]}" ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --groups $UNION
echo "Attached SG set to $INSTANCE_ID: $UNION"
echo "DONE. Verify SSH still works in a SEPARATE session before closing this one."
EOS
} > "$OUTPUT_FILE"
chmod +x "$OUTPUT_FILE" 2>/dev/null || true

# ==============================================================================
# 5. Summarise + instruct
# ==============================================================================
if [ "$MODE" = "cloudflare" ]; then src_label="Cloudflare prefix lists (${#CF_V4[@]} v4 + ${#CF_V6[@]} v6)"; else src_label="0.0.0.0/0 and ::/0 (PUBLIC)"; fi
echo
echo -e "${BLUE}Planned inbound rules (encoded in the generated commands):${NC}"
hr
$OPEN_HTTP && printf "  %-4s %-4s from %s\n" "TCP" "80"  "$src_label"
printf   "  %-4s %-4s from %s\n" "TCP" "443" "$src_label"
$OPEN_QUIC && printf "  %-4s %-4s from %s\n" "UDP" "443" "$src_label"
[ -n "$SSH_SOURCE" ] && printf "  %-4s %-4s from %s\n" "TCP" "22" "$SSH_SOURCE"
hr
[ "$MODE" = "public" ] && warn "PUBLIC mode exposes the origin directly — only use it if you are NOT fronting with Cloudflare."

info "Wrote AWS CLI commands to: ${BOLD}${OUTPUT_FILE}${NC}"
echo
echo -e "${BOLD}Next steps${NC} — run these where AWS credentials with EC2 permissions are active"
echo -e "(an SSM session on this instance under an IAM role, your laptop with a profile,"
echo -e "or CloudShell). The commands do NOT run automatically:"
echo
echo -e "    ${BOLD}aws sts get-caller-identity${NC}      # confirm the right account/role"
echo -e "    ${BOLD}less ${OUTPUT_FILE}${NC}   # review what it will do"
echo -e "    ${BOLD}bash ${OUTPUT_FILE}${NC}"
echo
echo -e "${YELLOW}After running, confirm SSH still works from a second session before closing this one.${NC}"
if [ "$MODE" = "cloudflare" ]; then
    echo -e "${YELLOW}Re-run this generator whenever Cloudflare changes its ranges, then re-run the output.${NC}"
fi
