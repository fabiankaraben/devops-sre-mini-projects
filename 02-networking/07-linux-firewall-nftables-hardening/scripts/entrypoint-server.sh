#!/usr/bin/env bash
# ==============================================================================
# Hardened Target Server Entrypoint Script
# ==============================================================================
set -euo pipefail

NFT_CONF="/etc/nftables.conf"
CONFIG_SRC="/config/nftables.conf"

echo "=========================================================="
echo " Starting Hardened Linux Server with nftables"
echo "=========================================================="

if [ -f "${CONFIG_SRC}" ]; then
  mkdir -p /etc
  cp "${CONFIG_SRC}" "${NFT_CONF}"
  chmod 600 "${NFT_CONF}"
fi

echo "[+] Loading nftables ruleset from ${NFT_CONF}..."
nft -f "${NFT_CONF}"

echo "[+] Current nftables ruleset loaded successfully:"
nft list ruleset

echo "[+] Starting background services (Web :8080, HTTP :80, SSH :22)..."
exec python3 /app/server.py
