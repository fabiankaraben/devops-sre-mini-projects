# ==============================================================================
# admin-policy.hcl - Administrative Management Policy
# ==============================================================================

# Manage secret engines
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage auth methods
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage policies
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Full access to KV v2 secret store
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Full access to database engine
path "database/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
