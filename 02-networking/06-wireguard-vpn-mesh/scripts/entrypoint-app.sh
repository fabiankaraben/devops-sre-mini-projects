#!/usr/bin/env bash
# ==============================================================================
# Site App Service Entrypoint Script
# ==============================================================================
set -euo pipefail

SITE_NAME="${SITE_NAME:-Site-Unknown}"
GATEWAY_IP="${GATEWAY_IP:-}"

echo "=========================================================="
echo " Starting Application Node: ${SITE_NAME}"
echo "=========================================================="

# Configure static route for inter-site VPN traffic via local Site Gateway
if [ -n "${GATEWAY_IP}" ]; then
  echo "[+] Adding routing rule for VPN subnets (10.0.0.0/8) via Gateway ${GATEWAY_IP}..."
  # Add specific routes for cross-site networks
  ip route add 10.0.0.0/8 via "${GATEWAY_IP}" || true
fi

echo "[+] Current IP Routing Table:"
ip route

echo "[+] Starting Python REST API & Dashboard on port ${PORT:-8080}..."
exec python3 /app/app.py
