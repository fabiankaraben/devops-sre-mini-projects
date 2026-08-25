#!/usr/bin/env bash
# ==============================================================================
# generate_certificates.sh - Local PKI & TLS Certificate Generator
# ==============================================================================
# Generates a local Certificate Authority (CA) and SAN-enabled server certificates
# for the mock HTTPS endpoints (weak and hardened Nginx instances).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"
mkdir -p "$CERTS_DIR"

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔐 GENERATING LOCAL PKI & TLS SERVER CERTIFICATES"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Generate Root Certificate Authority (CA)
echo -e "${CLR_YELLOW}▶ [1/3] Generating local Root Certificate Authority (CA)...${CLR_RESET}"

cat <<EOF > "$CERTS_DIR/ca_ext.cnf"
[req]
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = US
ST = Security
L = Audit
O = DevSecOps-Local-CA
CN = Local-Audit-Root-CA

[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
    -keyout "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.crt" \
    -config "$CERTS_DIR/ca_ext.cnf" \
    -extensions v3_ca >/dev/null 2>&1

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Root CA created: ${CLR_GRAY}$CERTS_DIR/ca.crt${CLR_RESET}"

# 2. Generate Server Private Key & Certificate Signing Request (CSR)
echo -e "\n${CLR_YELLOW}▶ [2/3] Generating Server Private Key and CSR with SANs...${CLR_RESET}"
openssl genrsa -out "$CERTS_DIR/server.key" 2048 >/dev/null 2>&1

cat <<EOF > "$CERTS_DIR/openssl.cnf"
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = US
ST = Security
L = Audit
O = DevSecOps Lab
CN = localhost

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = weak-tls-server
DNS.3 = hardened-tls-server
IP.1 = 127.0.0.1
EOF

openssl req -new -key "$CERTS_DIR/server.key" \
    -out "$CERTS_DIR/server.csr" \
    -config "$CERTS_DIR/openssl.cnf" >/dev/null 2>&1

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Server CSR created: ${CLR_GRAY}$CERTS_DIR/server.csr${CLR_RESET}"

# 3. Sign Server Certificate with Local CA
echo -e "\n${CLR_YELLOW}▶ [3/3] Signing Server Certificate with Root CA...${CLR_RESET}"

cat <<EOF > "$CERTS_DIR/v3_ext.cnf"
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = weak-tls-server
DNS.3 = hardened-tls-server
IP.1 = 127.0.0.1
EOF

openssl x509 -req -in "$CERTS_DIR/server.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/server.crt" \
    -days 825 \
    -sha256 \
    -extfile "$CERTS_DIR/v3_ext.cnf" >/dev/null 2>&1

# Restrict permissions
chmod 600 "$CERTS_DIR"/*.key 2>/dev/null || true
chmod 644 "$CERTS_DIR"/*.crt 2>/dev/null || true
rm -f "$CERTS_DIR"/*.cnf "$CERTS_DIR"/*.csr "$CERTS_DIR"/*.srl

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Server Certificate issued: ${CLR_GRAY}$CERTS_DIR/server.crt${CLR_RESET}"

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================"
echo "  ✅ PKI & CERTIFICATES SUCCESSFULLY GENERATED"
echo "======================================================================${CLR_RESET}\n"
