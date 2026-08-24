#!/usr/bin/env bash
# ==============================================================================
# vault_bootstrap.sh - Automated HashiCorp Vault Initializer & Provisioner
# ==============================================================================
# Initializes and unseals Vault, enables KV v2 and Dynamic Database engines,
# configures AppRole authentication with least-privilege policies, and exports
# client credentials for application usage.
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
KEYS_FILE="$SCRIPT_DIR/vault_init_keys.json"
CREDS_FILE="$SCRIPT_DIR/app/config/approle_creds.json"
mkdir -p "$SCRIPT_DIR/app/config"

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🔐 HASHICORP VAULT SECRETS ENGINE BOOTSTRAPPER"
echo "======================================================================${CLR_RESET}"
echo -e " Vault Endpoint   : ${CLR_BOLD}${VAULT_ADDR}${CLR_RESET}"
echo -e " Output Key File  : ${CLR_GRAY}${KEYS_FILE}${CLR_RESET}"
echo -e " AppRole Creds    : ${CLR_GRAY}${CREDS_FILE}${CLR_RESET}"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Wait for Vault API to be accessible
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [1/6] Checking Vault service readiness...${CLR_RESET}"

MAX_RETRIES=20
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if curl -s "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1 || curl -s "${VAULT_ADDR}/v1/sys/init" >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault API is responsive."
        break
    fi
    COUNT=$((COUNT + 1))
    echo -e "  [${CLR_GRAY}WAIT${CLR_RESET}] Waiting for Vault at ${VAULT_ADDR} ($COUNT/$MAX_RETRIES)..."
    sleep 2
done

if [ $COUNT -ge $MAX_RETRIES ]; then
    echo -e "${CLR_RED}Error: Vault service is not reachable at ${VAULT_ADDR}.${CLR_RESET}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Initialize & Unseal Vault
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/6] Initializing & Unsealing Vault storage...${CLR_RESET}"

INIT_STATUS=$(curl -s "${VAULT_ADDR}/v1/sys/init" | python3 -c "import sys, json; print(json.load(sys.stdin).get('initialized', False))")

if [ "$INIT_STATUS" != "True" ]; then
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Initializing Vault with 1 Shamir key share (Demo configuration)..."
    INIT_RESP=$(curl -s -X POST "${VAULT_ADDR}/v1/sys/init" \
        -d '{"secret_shares": 1, "secret_threshold": 1}')
    
    echo "$INIT_RESP" > "$KEYS_FILE"
    chmod 600 "$KEYS_FILE"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault initialized. Keys stored in ${KEYS_FILE}"
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault is already initialized."
fi

UNSEAL_KEY=$(python3 -c "import json; data=json.load(open('$KEYS_FILE')); print(data.get('keys', data.get('keys_base64', ['']))[0])")
ROOT_TOKEN=$(python3 -c "import json; data=json.load(open('$KEYS_FILE')); print(data.get('root_token', ''))")

# Check seal status
SEAL_STATUS=$(curl -s "${VAULT_ADDR}/v1/sys/seal-status" | python3 -c "import sys, json; print(json.load(sys.stdin).get('sealed', True))")

if [ "$SEAL_STATUS" == "True" ]; then
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Unsealing Vault using key share..."
    curl -s -X POST "${VAULT_ADDR}/v1/sys/unseal" \
        -d "{\"key\": \"${UNSEAL_KEY}\"}" >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault successfully unsealed."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault is already unsealed and active."
fi

# ------------------------------------------------------------------------------
# 3. Mount KV v2 Secrets Engine & Write Static Secrets
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/6] Configuring KV v2 Secrets Engine (secret/)...${CLR_RESET}"

# Enable KV v2 at secret/ if not already mounted
MOUNTS_JSON=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/sys/mounts")
if ! echo "$MOUNTS_JSON" | grep -q '"secret/"'; then
    curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/sys/mounts/secret" \
        -d '{"type": "kv", "options": {"version": "2"}, "description": "Payment Service Versioned KV Secrets"}' >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] KV v2 secrets engine enabled at 'secret/'."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] KV v2 secrets engine already mounted at 'secret/'."
fi

# Write static payment application secrets
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/secret/data/payment-service/config" \
    -d '{
        "data": {
            "stripe_api_key": "sk_live_51MOCKStripeProductionKey99281X",
            "jwt_signing_key": "super-secret-jwt-hmac-sha256-signing-token-2026",
            "encryption_salt": "c4ca4238a0b923820dcc509a6f75849b",
            "environment": "production"
        }
    }' >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Static secrets written to 'secret/data/payment-service/config'."

# ------------------------------------------------------------------------------
# 4. Upload Least-Privilege Policies & Configure AppRole Authentication
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/6] Configuring AppRole Authentication & Policies...${CLR_RESET}"

# Upload payment-app-policy.hcl
POLICY_CONTENT=$(cat "$SCRIPT_DIR/policies/payment-app-policy.hcl")
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/payment-app-policy" \
    -d "{\"policy\": $(echo "$POLICY_CONTENT" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))')}" >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Security policy 'payment-app-policy' created."

# Enable AppRole Auth if not present
AUTH_JSON=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth")
if ! echo "$AUTH_JSON" | grep -q '"approle/"'; then
    curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/sys/auth/approle" \
        -d '{"type": "approle", "description": "Machine-to-machine authentication"}' >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] AppRole authentication enabled at 'auth/approle'."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] AppRole authentication already enabled."
fi

# Configure payment-service-role AppRole
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/auth/approle/role/payment-service-role" \
    -d '{
        "token_policies": ["payment-app-policy"],
        "token_ttl": "10m",
        "token_max_ttl": "1h",
        "secret_id_ttl": "24h",
        "token_num_uses": 0
    }' >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] AppRole 'payment-service-role' configured with 10m TTL."

# Fetch RoleID and generate SecretID
ROLE_ID=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/auth/approle/role/payment-service-role/role-id" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['role_id'])")
SECRET_ID=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/auth/approle/role/payment-service-role/secret-id" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['secret_id'])")

cat <<EOF > "$CREDS_FILE"
{
  "vault_addr": "${VAULT_ADDR}",
  "role_name": "payment-service-role",
  "role_id": "${ROLE_ID}",
  "secret_id": "${SECRET_ID}"
}
EOF
chmod 600 "$CREDS_FILE"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] AppRole credentials exported to: ${CREDS_FILE}"

# ------------------------------------------------------------------------------
# 5. Enable Dynamic Database Secrets Engine (PostgreSQL)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/6] Configuring Dynamic PostgreSQL Database Secrets Engine...${CLR_RESET}"

if ! echo "$MOUNTS_JSON" | grep -q '"database/"'; then
    curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/sys/mounts/database" \
        -d '{"type": "database", "description": "Dynamic PostgreSQL Database Secrets Engine"}' >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Database secrets engine enabled at 'database/'."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Database secrets engine already mounted."
fi

# Initialize database tables in PostgreSQL container if available
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "vault-postgres-db"; then
    docker exec -i vault-postgres-db psql -U vaultadmin -d payment_db < "$SCRIPT_DIR/app/sql/init.sql" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Initialized PostgreSQL customer & transaction schema."
fi

# Configure PostgreSQL connection plugin
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/database/config/postgresql-payment-db" \
    -d '{
        "plugin_name": "postgresql-database-plugin",
        "allowed_roles": "payment-role",
        "connection_url": "postgresql://{{username}}:{{password}}@postgres:5432/payment_db?sslmode=disable",
        "username": "vaultadmin",
        "password": "VaultAdminSecretPass2026!"
    }' >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] PostgreSQL database connection configured ('postgresql-payment-db')."

# Configure dynamic database role
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/database/roles/payment-role" \
    -d '{
        "db_name": "postgresql-payment-db",
        "creation_statements": [
            "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\'';",
            "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
        ],
        "default_ttl": "15m",
        "max_ttl": "1h"
    }' >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Dynamic role 'payment-role' created (15-minute lease TTL)."

# ------------------------------------------------------------------------------
# 6. Final Summary & Output
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  ✅ HASHICORP VAULT BOOTSTRAP COMPLETE"
echo "======================================================================${CLR_RESET}"
echo -e " • KV v2 Secret Path    : ${CLR_GREEN}secret/data/payment-service/config${CLR_RESET}"
echo -e " • AppRole Name         : ${CLR_GREEN}payment-service-role${CLR_RESET}"
echo -e " • Dynamic DB Role      : ${CLR_GREEN}database/creds/payment-role${CLR_RESET}"
echo -e " • AppRole Role ID      : ${CLR_YELLOW}${ROLE_ID}${CLR_RESET}"
echo -e " • AppRole Secret ID    : ${CLR_GRAY}${SECRET_ID:0:8}...${CLR_RESET}"
echo "======================================================================\n"
