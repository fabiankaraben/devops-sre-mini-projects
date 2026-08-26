#!/usr/bin/env bash
# ==============================================================================
# Security Auditor Node Entrypoint Script
# ==============================================================================
set -euo pipefail

echo "=========================================================="
echo " Starting Security Auditor Container"
echo "=========================================================="
echo "[+] Tools available: nmap, hping3, curl, bash, python3"
echo "[+] Ready for security audit execution."

# Keep container running for on-demand test execution
exec tail -f /dev/null
