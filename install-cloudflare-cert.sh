#!/usr/bin/env bash
# ==============================================================================
# Title: install-cloudflare-cert.sh
# Purpose: Install a Cloudflare Origin Certificate (or any cert + key) for a
#          domain and wire nginx to serve it.
#            1. Prompt for the domain.
#            2. Paste the certificate, then the private key.
#            3. Validate both with openssl and confirm they match.
#            4. Install to /etc/nginx/certs with safe permissions.
#            5. Point the nginx site's ssl_certificate / ssl_certificate_key at
#               them, test the config, and reload (rolling back on failure).
#
# Run as root:  sudo ./install-cloudflare-cert.sh
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

# ----- config -----------------------------------------------------------------
CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/wordpress}"

# ----- must be root -----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (sudo) to write /etc/nginx and reload nginx."
    exit 1
fi
command -v openssl >/dev/null 2>&1 || { err "openssl is required but not installed."; exit 1; }

# Read a PEM block from the terminal, line by line, until the END marker (given
# as an extended-regex) is seen. Strips CR so pasted Windows content is clean.
# Second arg "1" hides input: echo is disabled for the WHOLE phase via stty (not
# per-line read -s, which would let the gaps between lines of a multi-line paste
# echo the key), and one '*' is printed per line as feedback.
read_pem_block(){
    local end_re="$1" hidden="${2:-0}" line block="" saved=""
    if [ "$hidden" = "1" ]; then
        saved="$(stty -g < /dev/tty 2>/dev/null || true)"
        stty -echo < /dev/tty 2>/dev/null || true
    fi
    while IFS= read -r line < /dev/tty; do
        line="${line%$'\r'}"
        block+="$line"$'\n'
        [ "$hidden" = "1" ] && printf '*' > /dev/tty
        [[ "$line" =~ $end_re ]] && break
    done
    if [ "$hidden" = "1" ]; then
        if [ -n "$saved" ]; then stty "$saved" < /dev/tty 2>/dev/null || true
        else stty echo < /dev/tty 2>/dev/null || true; fi
        printf '\n' > /dev/tty
    fi
    printf '%s' "$block"
}

echo -e "${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}CLOUDFLARE ORIGIN CERTIFICATE INSTALLER${NC}"
echo -e "${CYAN}======================================================================${NC}"

# ----- 1. domain --------------------------------------------------------------
DOMAIN=""
while true; do
    read -rp "Domain this certificate is for (e.g. example.com): " DOMAIN < /dev/tty
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] && break
    err "Enter a bare hostname like example.com (letters, digits, dots, hyphens)."
done
CERT_FILE="${CERT_DIR}/${DOMAIN}.pem"
KEY_FILE="${CERT_DIR}/${DOMAIN}.key"

# ----- 2. paste cert then key -------------------------------------------------
echo
echo -e "${BOLD}Paste the CERTIFICATE${NC} (the 'origin certificate' block from Cloudflare),"
echo    "including the -----BEGIN CERTIFICATE----- and -----END CERTIFICATE----- lines:"
CERT_CONTENT="$(read_pem_block '^-+END CERTIFICATE-+$')"

echo
echo -e "${BOLD}Paste the PRIVATE KEY${NC} (the 'private key' block from Cloudflare),"
echo    "including the -----BEGIN ... PRIVATE KEY----- and -----END ... PRIVATE KEY----- lines."
echo -e "${YELLOW}Input is hidden${NC} — you'll see one '*' per line, not the key text:"
KEY_CONTENT="$(read_pem_block '^-+END .*PRIVATE KEY-+$' 1)"

# ----- 3. validate ------------------------------------------------------------
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Trailing '\n' guarantees a terminating newline (command substitution strips it).
printf '%s\n' "$CERT_CONTENT" > "$TMP/cert.pem"
printf '%s\n' "$KEY_CONTENT"  > "$TMP/key.pem"

info "Validating the certificate..."
if ! openssl x509 -in "$TMP/cert.pem" -noout 2>/dev/null; then
    err "That does not parse as a valid X.509 certificate. Nothing was changed."
    exit 1
fi

info "Validating the private key..."
if ! openssl pkey -in "$TMP/key.pem" -noout 2>/dev/null; then
    err "That does not parse as a valid private key. Nothing was changed."
    exit 1
fi

info "Checking that the key matches the certificate..."
CERT_PUB="$(openssl x509 -in "$TMP/cert.pem" -noout -pubkey 2>/dev/null | openssl md5)"
KEY_PUB="$(openssl pkey -in "$TMP/key.pem" -pubout 2>/dev/null | openssl md5)"
if [ "$CERT_PUB" != "$KEY_PUB" ] || [ -z "$CERT_PUB" ]; then
    err "The private key does NOT match the certificate. Nothing was changed."
    exit 1
fi

# Informational: show subject + expiry so the user can eyeball it.
SUBJECT="$(openssl x509 -in "$TMP/cert.pem" -noout -subject 2>/dev/null | sed 's/^subject=//')"
ENDDATE="$(openssl x509 -in "$TMP/cert.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
info "Certificate looks valid and matches the key."
echo -e "    Subject: ${BOLD}${SUBJECT}${NC}"
echo -e "    Expires: ${BOLD}${ENDDATE}${NC}"

# ----- 4. install -------------------------------------------------------------
mkdir -p "$CERT_DIR"
chmod 755 "$CERT_DIR"
install -o root -g root -m 644 "$TMP/cert.pem" "$CERT_FILE"
install -o root -g root -m 600 "$TMP/key.pem"  "$KEY_FILE"
info "Installed certificate -> ${CERT_FILE} (644)"
info "Installed private key -> ${KEY_FILE} (600)"

# ----- 5. wire up nginx and reload -------------------------------------------
if [ ! -f "$SITE_CONF" ]; then
    warn "nginx site config not found at ${SITE_CONF}."
    warn "Certificate is installed; add these two lines to your server block manually:"
    echo "    ssl_certificate     ${CERT_FILE};"
    echo "    ssl_certificate_key ${KEY_FILE};"
    exit 0
fi

BK="${SITE_CONF}.bak.$(date +%s)"
cp -a "$SITE_CONF" "$BK"
info "Backed up ${SITE_CONF} -> ${BK}"

# Repoint the existing directives (anchored so ssl_certificate_key isn't caught
# by the ssl_certificate rule). Optionally set server_name to the domain.
sed -i -E \
    -e "s#^([[:space:]]*)ssl_certificate[[:space:]]+\S+;#\1ssl_certificate ${CERT_FILE};#" \
    -e "s#^([[:space:]]*)ssl_certificate_key[[:space:]]+\S+;#\1ssl_certificate_key ${KEY_FILE};#" \
    -e "s#^([[:space:]]*)server_name[[:space:]]+_;#\1server_name ${DOMAIN};#" \
    "$SITE_CONF"

if ! grep -q "ssl_certificate ${CERT_FILE};" "$SITE_CONF"; then
    warn "Could not find an ssl_certificate line to update in ${SITE_CONF}."
    warn "Add manually inside the 'listen 443' server block:"
    echo "    ssl_certificate     ${CERT_FILE};"
    echo "    ssl_certificate_key ${KEY_FILE};"
fi

info "Testing nginx configuration..."
if nginx -t 2>/dev/null; then
    systemctl reload nginx && info "nginx reloaded — ${DOMAIN} is now served with the new certificate."
else
    err "nginx -t failed with the new certificate paths. Rolling back."
    nginx -t 2>&1 | sed 's/^/    /'
    cp -a "$BK" "$SITE_CONF"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    err "Reverted ${SITE_CONF} from backup. The cert files are installed but not wired in."
    exit 1
fi

echo -e "${CYAN}----------------------------------------------------------------------${NC}"
echo -e "${GREEN}${BOLD}Done.${NC} With a valid origin certificate in place you can set Cloudflare's"
echo -e "SSL/TLS mode to ${BOLD}Full (strict)${NC}."
