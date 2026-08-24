# ==============================================================================
# payment-app-policy.hcl - Least-Privilege AppRole Policy for Payment Service
# ==============================================================================
# Grants read-only access to static KV v2 payment secrets and dynamic database credentials.
# ==============================================================================

# 1. Allow reading static versioned secrets in KV v2 engine
path "secret/data/payment-service/*" {
  capabilities = ["read"]
}

path "secret/metadata/payment-service/*" {
  capabilities = ["read", "list"]
}

# 2. Allow requesting short-lived dynamic PostgreSQL database credentials
path "database/creds/payment-role" {
  capabilities = ["read"]
}

# 3. Allow self token management (inspection, renewal, and revocation)
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
