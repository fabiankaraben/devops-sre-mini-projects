#!/bin/sh
set -eu

# Generate certificates if they do not exist
if [ ! -f /etc/nginx/certs/valid.local.crt ]; then
    echo "[MOCK-TLS] Generating TLS certificates in /etc/nginx/certs..."
    /usr/local/bin/generate_certs.sh /etc/nginx/certs
fi

echo "[MOCK-TLS] Starting Nginx TLS mock server on ports 8443, 8444, 8445..."
exec nginx -g "daemon off;"
