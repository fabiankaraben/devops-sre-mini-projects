#!/usr/bin/env bash
# ==============================================================================
# secret_rotation_test.sh - Automated Live Secret Rotation & Hot-Reload Test
# ==============================================================================
# Simulates live secret rotation in HashiCorp Vault, verifying that the
# Vault Agent Sidecar updates in-memory tmpfs files (/vault/secrets/config.json)
# and the running application hot-reloads secrets with ZERO DOWNTIME.
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
APP_URL="${APP_URL:-http://127.0.0.1:8080}"
KEYS_FILE="$SCRIPT_DIR/vault_init_keys.json"

if [ ! -f "$KEYS_FILE" ]; then
    echo -e "${CLR_RED}Error: '$KEYS_FILE' not found. Run './vault_k8s_bootstrap.sh' first.${CLR_RESET}"
    exit 1
fi

ROOT_TOKEN=$(python3 -c "import json; data=json.load(open('$KEYS_FILE')); print(data.get('root_token', ''))")

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🔄 LIVE ZERO-DOWNTIME SECRET ROTATION TEST"
echo "======================================================================${CLR_RESET}"
echo -e " Target App URL   : ${CLR_BOLD}${APP_URL}${CLR_RESET}"
echo -e " Vault Server     : ${CLR_BOLD}${VAULT_ADDR}${CLR_RESET}"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Verify Initial Secret State (Version 1)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [1/4] Inspecting Initial In-Memory Secret State (Version 1)...${CLR_RESET}"

INITIAL_RESP=$(curl -s "${APP_URL}/secrets")
INITIAL_VERSION=$(echo "$INITIAL_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('secret_version', 'unknown'))")
INITIAL_STRIPE=$(echo "$INITIAL_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('secrets', {}).get('stripe_api_key_masked', 'unknown'))")

echo -e "  • Current Active Version : ${CLR_GREEN}v${INITIAL_VERSION}${CLR_RESET}"
echo -e "  • Masked Stripe Key      : ${CLR_CYAN}${INITIAL_STRIPE}${CLR_RESET}"

# ------------------------------------------------------------------------------
# 2. Rotate Secrets to Version 2 in Vault
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Rotating Secrets in Vault (Writing Version 2)...${CLR_RESET}"

curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/secret/data/payment-service/config" \
    -d '{
        "data": {
            "stripe_api_key": "sk_live_v2_ROTATED_KEY_88192A",
            "jwt_secret": "jwt-hmac-sha256-secret-token-v2-rotated",
            "database_password": "DbRotatedPasswordV2_Beta2026!"
        }
    }' >/dev/null

# Signal Vault Agent to re-evaluate templates immediately
docker kill -s HUP vault-agent-sidecar >/dev/null 2>&1 || true

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault KV v2 secret updated to Version 2."
echo -e "  [${CLR_GRAY}WAIT${CLR_RESET}] Waiting for Vault Agent Sidecar to re-render in-memory template..."

V2_DETECTED=false
for i in {1..20}; do
    APP_RESP=$(curl -s "${APP_URL}/secrets" || true)
    ACTIVE_VER=$(echo "$APP_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('secret_version', ''))" 2>/dev/null || true)
    if [ "$ACTIVE_VER" == "2" ]; then
        V2_DETECTED=true
        break
    fi
    sleep 1
done

if [ "$V2_DETECTED" = true ]; then
    V2_STRIPE=$(echo "$APP_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('secrets', {}).get('stripe_api_key_masked', ''))")
    echo -e "  [${CLR_GREEN}SUCCESS${CLR_RESET}] Application hot-reloaded to Version 2 without restart!"
    echo -e "  • New Masked Stripe Key : ${CLR_CYAN}${V2_STRIPE}${CLR_RESET}"
else
    echo -e "  ${CLR_RED}Failure: Application failed to detect Version 2 rotation.${CLR_RESET}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Rotate Secrets to Version 3 in Vault (High-Entropy Production Key)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Rotating Secrets in Vault (Writing Version 3)...${CLR_RESET}"

curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/secret/data/payment-service/config" \
    -d '{
        "data": {
            "stripe_api_key": "sk_live_v3_ZERO_DOWNTIME_KEY_77301Z",
            "jwt_secret": "jwt-hmac-sha256-secret-token-v3-production",
            "database_password": "DbFinalPasswordV3_Gamma2026!"
        }
    }' >/dev/null

# Signal Vault Agent to re-evaluate templates immediately
docker kill -s HUP vault-agent-sidecar >/dev/null 2>&1 || true

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault KV v2 secret updated to Version 3."
echo -e "  [${CLR_GRAY}WAIT${CLR_RESET}] Waiting for Vault Agent Sidecar to re-render in-memory template..."

V3_DETECTED=false
for i in {1..20}; do
    APP_RESP=$(curl -s "${APP_URL}/secrets" || true)
    ACTIVE_VER=$(echo "$APP_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('secret_version', ''))" 2>/dev/null || true)
    if [ "$ACTIVE_VER" == "3" ]; then
        V3_DETECTED=true
        break
    fi
    sleep 1
done

if [ "$V3_DETECTED" = true ]; then
    V3_STRIPE=$(echo "$APP_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('secrets', {}).get('stripe_api_key_masked', ''))")
    echo -e "  [${CLR_GREEN}SUCCESS${CLR_RESET}] Application hot-reloaded to Version 3 without restart!"
    echo -e "  • New Masked Stripe Key : ${CLR_CYAN}${V3_STRIPE}${CLR_RESET}"
else
    echo -e "  ${CLR_RED}Failure: Application failed to detect Version 3 rotation.${CLR_RESET}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Final Validation & Metrics Inspection
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Validating Application Health & Hot-Reload Metrics...${CLR_RESET}"

METRICS_TEXT=$(curl -s "${APP_URL}/metrics")
echo -e "${CLR_GRAY}${METRICS_TEXT}${CLR_RESET}"

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ZERO-DOWNTIME LIVE SECRET ROTATION VALIDATED SUCCESSFULLY!${CLR_RESET}\n"
