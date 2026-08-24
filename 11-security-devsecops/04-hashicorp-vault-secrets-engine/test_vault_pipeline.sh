#!/usr/bin/env bash
# ==============================================================================
# test_vault_pipeline.sh - Automated Verification Suite for HashiCorp Vault
# ==============================================================================
# Executes end-to-end testing of Vault deployment, Shamir unsealing, KV v2
# secret management, AppRole authentication, dynamic PostgreSQL credentials,
# and token lifecycle management.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    local test_name="$1"
    local status="$2"
    local details="${3:-}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$status" -eq 0 ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${test_name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${test_name} (Exit Code: ${status}) ${details}"
    fi
}

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🧪 STARTING HASHICORP VAULT SECRETS ENGINE TEST SUITE"
echo "======================================================================${CLR_RESET}"

# ------------------------------------------------------------------------------
# Step 0: Validate Prerequisites
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 0/6] Validating environment dependencies...${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    record_result "Docker CLI is available" 0
else
    record_result "Docker CLI is available" 1 "Docker is required"
fi

if command -v python3 >/dev/null 2>&1; then
    record_result "Python 3 is available" 0
else
    record_result "Python 3 is available" 1
fi

if command -v curl >/dev/null 2>&1; then
    record_result "curl CLI is available" 0
else
    record_result "curl CLI is available" 1
fi

# ------------------------------------------------------------------------------
# Step 1: Launch Vault & PostgreSQL Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 1/6] Starting Vault and PostgreSQL containers...${CLR_RESET}"

docker compose up -d

# Wait for containers to become healthy
echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Waiting for Vault and PostgreSQL services to be healthy..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s "http://127.0.0.1:8200/v1/sys/init" >/dev/null 2>&1; then
        break
    fi
    WAITED=$((WAITED + 2))
    sleep 2
done

if [ $WAITED -ge $MAX_WAIT ]; then
    record_result "Vault server container reached healthy state" 1 "Timeout waiting for Vault"
else
    record_result "Vault server container reached healthy state" 0
fi

# ------------------------------------------------------------------------------
# Step 2: Bootstrap Vault Storage, Engines & Policies
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 2/6] Running automated vault_bootstrap.sh...${CLR_RESET}"

set +e
./vault_bootstrap.sh >/dev/null 2>&1
BOOTSTRAP_STATUS=$?
set -e

if [ "$BOOTSTRAP_STATUS" -eq 0 ]; then
    record_result "vault_bootstrap.sh executed successfully" 0
else
    record_result "vault_bootstrap.sh executed successfully" 1 "Bootstrap failed"
fi

if [ -f "vault_init_keys.json" ] && [ -s "vault_init_keys.json" ]; then
    record_result "Vault unseal keys & root token generated" 0
else
    record_result "Vault unseal keys & root token generated" 1
fi

if [ -f "app/config/approle_creds.json" ] && [ -s "app/config/approle_creds.json" ]; then
    record_result "AppRole credentials exported to app/config/approle_creds.json" 0
else
    record_result "AppRole credentials exported to app/config/approle_creds.json" 1
fi

# ------------------------------------------------------------------------------
# Step 3: Test Python Application Client Execution
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 3/6] Testing Python Application Client workflow...${CLR_RESET}"

set +e
python3 app_vault_client.py >/dev/null 2>&1
CLIENT_STATUS=$?
set -e

if [ "$CLIENT_STATUS" -eq 0 ]; then
    record_result "app_vault_client.py completed full AppRole & Dynamic DB workflow" 0
else
    record_result "app_vault_client.py completed full AppRole & Dynamic DB workflow" 1
fi

# ------------------------------------------------------------------------------
# Step 4: Verify KV v2 Secret Retrieval Directly via REST
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 4/6] Verifying KV v2 Secret Data via Vault REST API...${CLR_RESET}"

ROLE_ID=$(python3 -c "import json; print(json.load(open('app/config/approle_creds.json'))['role_id'])")
SECRET_ID=$(python3 -c "import json; print(json.load(open('app/config/approle_creds.json'))['secret_id'])")

LOGIN_RESP=$(curl -s -X POST "http://127.0.0.1:8200/v1/auth/approle/login" \
    -d "{\"role_id\": \"${ROLE_ID}\", \"secret_id\": \"${SECRET_ID}\"}")
CLIENT_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('auth', {}).get('client_token', ''))")

if [ -n "$CLIENT_TOKEN" ]; then
    record_result "AppRole login via REST API returned valid client token" 0
else
    record_result "AppRole login via REST API returned valid client token" 1
fi

SECRET_RESP=$(curl -s -H "X-Vault-Token: ${CLIENT_TOKEN}" "http://127.0.0.1:8200/v1/secret/data/payment-service/config")
STRIPE_KEY=$(echo "$SECRET_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data', {}).get('data', {}).get('stripe_api_key', ''))")

if [[ "$STRIPE_KEY" == *"sk_live_"* ]]; then
    record_result "KV v2 secret 'stripe_api_key' decrypted and verified" 0
else
    record_result "KV v2 secret 'stripe_api_key' decrypted and verified" 1
fi

# ------------------------------------------------------------------------------
# Step 5: Verify Dynamic Database Credentials & Lease Expiration
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 5/6] Verifying Dynamic Database Credentials & Lease Metadata...${CLR_RESET}"

DB_CREDS_RESP=$(curl -s -H "X-Vault-Token: ${CLIENT_TOKEN}" "http://127.0.0.1:8200/v1/database/creds/payment-role")
DB_USER=$(echo "$DB_CREDS_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data', {}).get('username', ''))")
DB_LEASE_ID=$(echo "$DB_CREDS_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('lease_id', ''))")

if [[ "$DB_USER" == "v-approle-payment-"* ]]; then
    record_result "Dynamic database user generated with 'v-approle-payment-' prefix" 0
else
    record_result "Dynamic database user generated with 'v-approle-payment-' prefix" 1
fi

if [ -n "$DB_LEASE_ID" ]; then
    record_result "Vault lease identifier assigned for dynamic database user" 0
else
    record_result "Vault lease identifier assigned for dynamic database user" 1
fi

# ------------------------------------------------------------------------------
# Step 6: Negative Security Tests (Invalid Auth & Revoked Token Blocking)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 6/6] Executing Negative Security Tests (Invalid Auth & Revocation)...${CLR_RESET}"

# Test 1: Invalid SecretID should fail authentication
INVALID_LOGIN=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:8200/v1/auth/approle/login" \
    -d "{\"role_id\": \"${ROLE_ID}\", \"secret_id\": \"invalid-fake-secret-id-12345\"}")

if [ "$INVALID_LOGIN" -eq 400 ] || [ "$INVALID_LOGIN" -eq 401 ]; then
    record_result "Vault blocks invalid AppRole SecretID with HTTP 400/401" 0
else
    record_result "Vault blocks invalid AppRole SecretID" 1 "Got HTTP $INVALID_LOGIN"
fi

# Test 2: Revoke token and assert access is denied
curl -s -H "X-Vault-Token: ${CLIENT_TOKEN}" -X POST "http://127.0.0.1:8200/v1/auth/token/revoke-self" >/dev/null

POST_REVOKE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Vault-Token: ${CLIENT_TOKEN}" "http://127.0.0.1:8200/v1/secret/data/payment-service/config")

if [ "$POST_REVOKE_CODE" -eq 403 ] || [ "$POST_REVOKE_CODE" -eq 401 ]; then
    record_result "Vault rejects revoked token with HTTP 403/401 Forbidden" 0
else
    record_result "Vault rejects revoked token" 1 "Got HTTP $POST_REVOKE_CODE"
fi

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  📊 TEST SUITE SUMMARY"
echo "======================================================================${CLR_RESET}"
echo -e "  Total Tests Evaluated : ${TOTAL_TESTS}"
echo -e "  Passed                : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed                : ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL HASHICORP VAULT SECRETS ENGINE TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. REVIEW LOGS ABOVE.${CLR_RESET}\n"
    exit 1
fi
