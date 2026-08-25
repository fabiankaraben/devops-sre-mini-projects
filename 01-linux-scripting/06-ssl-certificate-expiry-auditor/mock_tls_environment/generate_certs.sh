#!/usr/bin/env bash
# ==============================================================================
# Script Name: generate_certs.sh
# Description: Generates self-signed Root CA and three mock TLS certificates
#              with distinct lifespans (valid: 90 days, expiring: 10 days,
#              expired: past dates) for testing the SSL/TLS Auditor.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

if [[ "${1:-}" == "--clean" ]]; then
    target_clean="${2:-${SCRIPT_DIR}/certs}"
    log_info "Cleaning existing mock certificates in ${target_clean}..."
    rm -rf "${target_clean}"
    log_success "Cleaned mock certificate directory."
    exit 0
fi

# Set output certs directory (default: ./certs relative to script)
CERTS_DIR="${1:-${SCRIPT_DIR}/certs}"
mkdir -p "${CERTS_DIR}"

log_info "Generating mock Certificate Authority (Root CA) in ${CERTS_DIR}..."
# Generate Root CA private key
openssl genrsa -out "${CERTS_DIR}/rootCA.key" 2048 2>/dev/null

# Generate Root CA certificate (valid for 10 years)
openssl req -x509 -new -nodes \
    -key "${CERTS_DIR}/rootCA.key" \
    -sha256 \
    -days 3650 \
    -out "${CERTS_DIR}/rootCA.crt" \
    -subj "/C=US/ST=DevOps/L=Lab/O=DevOps SRE/OU=Security/CN=MockRootCA" 2>/dev/null

# Prepare OpenSSL CA directory database
echo "01" > "${CERTS_DIR}/serial"
touch "${CERTS_DIR}/index.txt"

# OpenSSL CA Configuration
cat << EOF > "${CERTS_DIR}/ca.cnf"
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${CERTS_DIR}
certs             = ${CERTS_DIR}
new_certs_dir     = ${CERTS_DIR}
database          = ${CERTS_DIR}/index.txt
serial            = ${CERTS_DIR}/serial
certificate       = ${CERTS_DIR}/rootCA.crt
private_key       = ${CERTS_DIR}/rootCA.key
default_days      = 365
default_md        = sha256
policy            = policy_loose
copy_extensions   = copy

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256

[ req_distinguished_name ]

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

generate_cert() {
    local name="$1"
    local cn="$2"
    local days="$3"
    local start_date="${4:-}"
    local end_date="${5:-}"

    log_info "Generating certificate: ${name} (CN: ${cn})..."

    # Create OpenSSL config with custom SAN for this domain
    local domain_cnf="${CERTS_DIR}/${name}.cnf"
    cat << EOF > "${domain_cnf}"
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = US
ST = California
L  = San Francisco
O  = DevOps SRE Lab
OU = Infrastructure
CN = ${cn}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${cn}
DNS.2 = localhost
IP.1  = 127.0.0.1
EOF

    # Generate private key
    openssl genrsa -out "${CERTS_DIR}/${name}.key" 2048 2>/dev/null

    # Generate CSR (Certificate Signing Request)
    openssl req -new \
        -key "${CERTS_DIR}/${name}.key" \
        -out "${CERTS_DIR}/${name}.csr" \
        -config "${domain_cnf}" 2>/dev/null

    # Sign CSR with CA
    if [[ -n "$start_date" && -n "$end_date" ]]; then
        openssl ca -batch \
            -config "${CERTS_DIR}/ca.cnf" \
            -in "${CERTS_DIR}/${name}.csr" \
            -out "${CERTS_DIR}/${name}.crt" \
            -startdate "${start_date}" \
            -enddate "${end_date}" 2>/dev/null
    else
        openssl ca -batch \
            -config "${CERTS_DIR}/ca.cnf" \
            -in "${CERTS_DIR}/${name}.csr" \
            -out "${CERTS_DIR}/${name}.crt" \
            -days "${days}" 2>/dev/null
    fi

    # Cleanup temporary CSR and config
    rm -f "${domain_cnf}" "${CERTS_DIR}/${name}.csr" "${CERTS_DIR}"/*.pem 2>/dev/null || true
}

# 1. Valid Certificate: 90 days validity
generate_cert "valid.local" "valid.local" 90

# 2. Expiring Soon Certificate: 10 days validity
generate_cert "expiring.local" "expiring.local" 10

# 3. Expired Certificate: validity was from 2022-01-01 to 2022-01-15 (past date)
generate_cert "expired.local" "expired.local" 1 "20220101000000Z" "20220115000000Z"

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}        Generated Mock Certificates Summary           ${NC}"
echo -e "${BLUE}======================================================${NC}"

for cert in "valid.local" "expiring.local" "expired.local"; do
    crt_file="${CERTS_DIR}/${cert}.crt"
    if [[ -f "$crt_file" ]]; then
        dates=$(openssl x509 -in "$crt_file" -noout -dates)
        not_before=$(echo "$dates" | grep "notBefore=" | cut -d= -f2)
        not_after=$(echo "$dates" | grep "notAfter=" | cut -d= -f2)
        echo -e "  - ${GREEN}${cert}${NC}"
        echo -e "      Not Before: ${not_before}"
        echo -e "      Not After:  ${not_after}"
    fi
done

echo -e "${BLUE}======================================================${NC}\n"
log_success "All mock TLS certificates generated in ${CERTS_DIR}"
