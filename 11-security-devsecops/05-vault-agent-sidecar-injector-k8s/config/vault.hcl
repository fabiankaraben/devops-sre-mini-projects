# ==============================================================================
# vault.hcl - HashiCorp Vault Server Configuration
# ==============================================================================

ui = true
disable_mlock = true

storage "inmem" {}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

default_lease_ttl = "1h"
max_lease_ttl     = "24h"
