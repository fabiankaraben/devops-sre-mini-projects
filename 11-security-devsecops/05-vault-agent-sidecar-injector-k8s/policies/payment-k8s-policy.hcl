# ==============================================================================
# payment-k8s-policy.hcl - Least-Privilege Policy for Injected Kubernetes Pod
# ==============================================================================
# Grants read access to versioned static secrets for the payment microservice.
# ==============================================================================

path "secret/data/payment-service/*" {
  capabilities = ["read"]
}

path "secret/metadata/payment-service/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
