#!/usr/bin/env bash
# ==============================================================================
# Certificate Generation Script for SSL/TLS Termination Mini-Project
# ==============================================================================
# Generates:
#   1. Local Root Certificate Authority (CA) key and self-signed certificate
#   2. Server private key (RSA 2048-bit) and Certificate Signing Request (CSR)
#   3. Signed server certificate with Subject Alternative Names (SAN):
#      - DNS: localhost, *.localhost, app.internal, *.internal, app.local
#      - IP: 127.0.0.1, ::1
#   4. Diffie-Hellman 2048-bit parameter file (dhparam.pem)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/certs"
VALIDITY_DAYS=365
FORCE=false

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

show_help() {
    echo "Usage: ./generate_certs.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --days <number>   Certificate validity in days (default: 365)"
    echo "  -f, --force           Overwrite existing certificates"
    echo "  -c, --clean           Remove all generated certificates and exit"
    echo "  -h, --help            Display this help message"
    echo ""
    echo "Examples:"
    echo "  ./generate_certs.sh"
    echo "  ./generate_certs.sh --force"
    echo "  ./generate_certs.sh --clean"
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--days)
            VALIDITY_DAYS="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -c|--clean)
            echo -e "${CLR_YELLOW}Cleaning up generated certificates in ${CERTS_DIR}...${CLR_RESET}"
            rm -rf "${CERTS_DIR}"
            echo -e "${CLR_GREEN}Certificates removed.${CLR_RESET}"
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔐 SSL/TLS Certificate Authority & Server Keypair Generator"
echo "======================================================================"
echo -e "${CLR_RESET}"

mkdir -p "${CERTS_DIR}"

if [[ -f "${CERTS_DIR}/server.crt" && -f "${CERTS_DIR}/server.key" && "$FORCE" = false ]]; then
    echo -e "${CLR_YELLOW}Certificates already exist in ${CERTS_DIR}.${CLR_RESET}"
    echo -e "Use ${CLR_BOLD}--force${CLR_RESET} to regenerate them.\n"
    exit 0
fi

# 1. Generate Root CA Key and Self-Signed CA Certificate
echo -e "${CLR_GRAY}[1/4] Generating Local Root Certificate Authority (CA)...${CLR_RESET}"
openssl req -x509 -new -nodes \
    -newkey rsa:2048 \
    -keyout "${CERTS_DIR}/ca.key" \
    -out "${CERTS_DIR}/ca.crt" \
    -days "${VALIDITY_DAYS}" \
    -subj "/C=US/ST=DevOps/L=LocalLab/O=DevOps Mini Projects/OU=Security/CN=DevOps Local Root CA" \
    2>/dev/null

# 2. Generate Server Private Key and CSR
echo -e "${CLR_GRAY}[2/4] Generating Server Private Key and CSR...${CLR_RESET}"
openssl req -new -nodes \
    -newkey rsa:2048 \
    -keyout "${CERTS_DIR}/server.key" \
    -out "${CERTS_DIR}/server.csr" \
    -subj "/C=US/ST=DevOps/L=LocalLab/O=DevOps Mini Projects/OU=ReverseProxy/CN=localhost" \
    2>/dev/null

# 3. Create OpenSSL SAN Extension Config & Sign Certificate with CA
echo -e "${CLR_GRAY}[3/4] Signing Server Certificate with SAN extensions...${CLR_RESET}"
EXT_CONFIG="${CERTS_DIR}/v3_san.ext"
cat << 'EOF' > "${EXT_CONFIG}"
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
DNS.3 = app.internal
DNS.4 = *.internal
DNS.5 = app.local
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl x509 -req \
    -in "${CERTS_DIR}/server.csr" \
    -CA "${CERTS_DIR}/ca.crt" \
    -CAkey "${CERTS_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERTS_DIR}/server.crt" \
    -days "${VALIDITY_DAYS}" \
    -extfile "${EXT_CONFIG}" \
    2>/dev/null

# 4. Generate Diffie-Hellman Parameters (Pre-computed for fast startup)
echo -e "${CLR_GRAY}[4/4] Generating Diffie-Hellman parameters (dhparam.pem)...${CLR_RESET}"
if [[ ! -f "${CERTS_DIR}/dhparam.pem" ]]; then
    # Generate 2048-bit DH parameters
    openssl dhparam -out "${CERTS_DIR}/dhparam.pem" 2048 2>/dev/null
fi

# Cleanup temporary CSR and ext files
rm -f "${CERTS_DIR}/server.csr" "${EXT_CONFIG}" "${CERTS_DIR}/ca.srl"
chmod 600 "${CERTS_DIR}"/*.key
chmod 644 "${CERTS_DIR}"/*.crt "${CERTS_DIR}"/*.pem

echo -e "\n${CLR_GREEN}${CLR_BOLD}✔ All certificates generated successfully in ${CERTS_DIR}:${CLR_RESET}"
echo -e "  - ${CLR_CYAN}ca.crt${CLR_RESET}      : Root CA Public Certificate"
echo -e "  - ${CLR_CYAN}ca.key${CLR_RESET}      : Root CA Private Key"
echo -e "  - ${CLR_CYAN}server.crt${CLR_RESET}  : Signed Server Certificate with SAN (localhost, 127.0.0.1, app.internal)"
echo -e "  - ${CLR_CYAN}server.key${CLR_RESET}  : Server Private Key (RSA 2048)"
echo -e "  - ${CLR_CYAN}dhparam.pem${CLR_RESET} : Diffie-Hellman 2048-bit Parameters\n"
