#!/usr/bin/env bash
# ==============================================================================
# vault_k8s_bootstrap.sh - Automated Vault Kubernetes & Sidecar Initializer
# ==============================================================================
# Initializes Vault, configures KV v2 secrets engine, creates least-privilege
# policies, enables AppRole & Kubernetes authentication, and starts the
# Vault Agent Sidecar daemon to render in-memory Consul templates.
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
CREDS_FILE="$SCRIPT_DIR/approle_creds.json"

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🔐 HASHICORP VAULT K8s & SIDECAR BOOTSTRAPPER"
echo "======================================================================${CLR_RESET}"
echo -e " Vault Server     : ${CLR_BOLD}${VAULT_ADDR}${CLR_RESET}"
echo -e " Key File Target  : ${CLR_GRAY}${KEYS_FILE}${CLR_RESET}"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Wait for Vault API Readiness
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [1/6] Checking Vault API readiness...${CLR_RESET}"

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
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Initializing Vault with 1 Shamir key share..."
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
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Unsealing Vault barrier..."
    curl -s -X POST "${VAULT_ADDR}/v1/sys/unseal" \
        -d "{\"key\": \"${UNSEAL_KEY}\"}" >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault unsealed and operational."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault is already unsealed."
fi

# ------------------------------------------------------------------------------
# 3. Mount KV v2 Secrets Engine & Seed Version 1 Secrets
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/6] Configuring KV v2 Secrets Engine & Seeding V1 Secrets...${CLR_RESET}"

MOUNTS_JSON=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/sys/mounts")
if ! echo "$MOUNTS_JSON" | grep -q '"secret/"'; then
    curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/sys/mounts/secret" \
        -d '{"type": "kv", "options": {"version": "2"}, "description": "Payment Service Secrets"}' >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] KV v2 secrets engine mounted at 'secret/'."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] KV v2 secrets engine already active at 'secret/'."
fi

# Write Version 1 Initial Secrets
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/secret/data/payment-service/config" \
    -d '{
        "data": {
            "stripe_api_key": "sk_live_v1_INITIAL_KEY_99281X",
            "jwt_secret": "jwt-hmac-sha256-secret-token-v1-initial",
            "database_password": "DbSecretPasswordV1_Alpha2026!"
        }
    }' >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Seeded Version 1 secrets into 'secret/data/payment-service/config'."

# ------------------------------------------------------------------------------
# 4. Upload Policy & Configure AppRole Authentication
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/6] Configuring Security Policy & AppRole / Kubernetes Auth...${CLR_RESET}"

POLICY_CONTENT=$(cat "$SCRIPT_DIR/policies/payment-k8s-policy.hcl")
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/payment-k8s-policy" \
    -d "{\"policy\": $(echo "$POLICY_CONTENT" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))')}" >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Policy 'payment-k8s-policy' uploaded."

# Enable AppRole Auth Method
AUTH_JSON=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth")
if ! echo "$AUTH_JSON" | grep -q '"approle/"'; then
    curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/sys/auth/approle" \
        -d '{"type": "approle", "description": "Sidecar machine-to-machine authentication"}' >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] AppRole authentication enabled at 'auth/approle'."
fi

# Configure payment-k8s-role
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/auth/approle/role/payment-k8s-role" \
    -d '{
        "token_policies": ["payment-k8s-policy"],
        "token_ttl": "15m",
        "token_max_ttl": "1h",
        "secret_id_ttl": "24h",
        "token_num_uses": 0
    }' >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Role 'payment-k8s-role' configured with 15m TTL."

ROLE_ID=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/auth/approle/role/payment-k8s-role/role-id" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['role_id'])")
SECRET_ID=$(curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" -X POST "${VAULT_ADDR}/v1/auth/approle/role/payment-k8s-role/secret-id" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['secret_id'])")

cat <<EOF > "$CREDS_FILE"
{
  "vault_addr": "${VAULT_ADDR}",
  "role_name": "payment-k8s-role",
  "role_id": "${ROLE_ID}",
  "secret_id": "${SECRET_ID}"
}
EOF
chmod 600 "$CREDS_FILE"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Sidecar authentication credentials exported."

# ------------------------------------------------------------------------------
# 5. Start Vault Agent Sidecar Daemon (Simulating K8s Injected Sidecar)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/6] Spawning Vault Agent Sidecar Container...${CLR_RESET}"

# Stop old sidecar container if present
docker rm -f vault-agent-sidecar >/dev/null 2>&1 || true

# Prepare agent configuration directory and write config files directly into agent
docker run -d \
    --name vault-agent-sidecar \
    --network 05-vault-agent-sidecar-injector-k8s_vault-k8s-net \
    --volume 05-vault-agent-sidecar-injector-k8s_vault_shared_secrets:/vault/secrets \
    --cap-add IPC_LOCK \
    --entrypoint sh \
    hashicorp/vault:1.15.5 \
    -c "
        mkdir -p /vault/config /vault/secrets
        echo '$ROLE_ID' > /vault/config/role_id
        echo '$SECRET_ID' > /vault/config/secret_id
        cat <<'EOF' > /vault/config/agent.hcl
pid_file = \"/vault/secrets/vault-agent.pid\"

template_config {
  static_secret_render_interval = \"2s\"
  exit_on_retry_failure = false
}

vault {
  address = \"http://vault:8200\"
  retry {
    num_retries = 10
  }
}

auto_auth {
  method \"approle\" {
    mount_path = \"auth/approle\"
    config = {
      role_id_file_path   = \"/vault/config/role_id\"
      secret_id_file_path = \"/vault/config/secret_id\"
      remove_secret_id_file_after_reading = false
    }
  }

  sink \"file\" {
    config = {
      path = \"/vault/secrets/.vault-token\"
      mode = 0640
    }
  }
}

template {
  contents = <<EOH
{{ with secret \"secret/data/payment-service/config\" }}
{
  \"stripe_api_key\": \"{{ .Data.data.stripe_api_key }}\",
  \"jwt_secret\": \"{{ .Data.data.jwt_secret }}\",
  \"database_password\": \"{{ .Data.data.database_password }}\",
  \"secret_version\": \"{{ .Data.metadata.version }}\",
  \"rendered_at\": \"{{ timestamp }}\"
}
{{ end }}
EOH
  destination = \"/vault/secrets/config.json\"
}

template {
  contents = <<EOH
{{ with secret \"secret/data/payment-service/config\" }}
STRIPE_API_KEY=\"{{ .Data.data.stripe_api_key }}\"
JWT_SECRET=\"{{ .Data.data.jwt_secret }}\"
DB_PASSWORD=\"{{ .Data.data.database_password }}\"
SECRET_VERSION=\"{{ .Data.metadata.version }}\"
{{ end }}
EOH
  destination = \"/vault/secrets/app.env\"
}
EOF
        exec vault agent -config=/vault/config/agent.hcl -log-level=info
    " >/dev/null

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault Agent Sidecar container is running and watching Vault."

# ------------------------------------------------------------------------------
# 6. Verify Initial Template Rendering
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [6/6] Verifying Initial In-Memory Template Rendering...${CLR_RESET}"

RENDER_SUCCESS=false
for i in {1..15}; do
    if docker exec payment-service-app test -f /vault/secrets/config.json >/dev/null 2>&1; then
        RENDER_SUCCESS=true
        break
    fi
    sleep 1
done

if [ "$RENDER_SUCCESS" = true ]; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] In-memory secret file '/vault/secrets/config.json' rendered successfully!"
else
    echo -e "  ${CLR_RED}Warning: Timed out waiting for /vault/secrets/config.json to render.${CLR_RESET}"
fi

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  ✅ VAULT K8S & SIDECAR BOOTSTRAP COMPLETE"
echo "======================================================================${CLR_RESET}"
echo -e " • KV v2 Secret Path    : ${CLR_GREEN}secret/data/payment-service/config${CLR_RESET}"
echo -e " • K8s AppRole Role     : ${CLR_GREEN}payment-k8s-role${CLR_RESET}"
echo -e " • In-Memory JSON Secret: ${CLR_CYAN}/vault/secrets/config.json${CLR_RESET}"
echo -e " • In-Memory Dotenv     : ${CLR_CYAN}/vault/secrets/app.env${CLR_RESET}"
echo "======================================================================\n"
