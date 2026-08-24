# ==============================================================================
# vault-agent-config.hcl - Vault Agent Sidecar Configuration
# ==============================================================================
# Configures Auto-Auth with Vault, token sink, and Consul Template rendering
# into the shared in-memory tmpfs volume at /vault/secrets/.
# ==============================================================================

pid_file = "/vault/secrets/vault-agent.pid"

template_config {
  static_secret_render_interval = "2s"
  exit_on_retry_failure = false
}

vault {
  address = "http://vault:8200"
  retry {
    num_retries = 10
  }
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path   = "/vault/config/role_id"
      secret_id_file_path = "/vault/config/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault/secrets/.vault-token"
      mode = 0640
    }
  }
}

# Template 1: Render JSON Configuration
template {
  contents = <<EOH
{{ with secret "secret/data/payment-service/config" }}
{
  "stripe_api_key": "{{ .Data.data.stripe_api_key }}",
  "jwt_secret": "{{ .Data.data.jwt_secret }}",
  "database_password": "{{ .Data.data.database_password }}",
  "secret_version": "{{ .Data.metadata.version }}",
  "rendered_at": "{{ timestamp }}"
}
{{ end }}
EOH
  destination = "/vault/secrets/config.json"
}

# Template 2: Render Dotenv Environment File
template {
  contents = <<EOH
{{ with secret "secret/data/payment-service/config" }}
STRIPE_API_KEY="{{ .Data.data.stripe_api_key }}"
JWT_SECRET="{{ .Data.data.jwt_secret }}"
DB_PASSWORD="{{ .Data.data.database_password }}"
SECRET_VERSION="{{ .Data.metadata.version }}"
{{ end }}
EOH
  destination = "/vault/secrets/app.env"
}
