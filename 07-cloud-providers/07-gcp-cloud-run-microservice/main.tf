# ==============================================================================
# GCP Cloud Run Scalable Microservice - Infrastructure Manifest
# ==============================================================================

provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

# ------------------------------------------------------------------------------
# 1. Random Suffix for Global Resource Uniqueness
# ------------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  service_id = "${var.service_name}-${random_string.suffix.result}"
  sa_id      = "sa-run-${random_string.suffix.result}"
  secret_id  = "${var.service_name}-api-key-${random_string.suffix.result}"
}

# ------------------------------------------------------------------------------
# 2. Dedicated Least-Privilege IAM Service Account for Cloud Run Runtime
# ------------------------------------------------------------------------------
resource "google_service_account" "cloud_run_sa" {
  account_id   = local.sa_id
  display_name = "Cloud Run Microservice Runtime Service Account"
  description  = "Dedicated least-privilege service account used by the Cloud Run instance"
}

# ------------------------------------------------------------------------------
# 3. Google Secret Manager: Secure Secret Storage & Versioning
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret" "api_secret" {
  secret_id = local.secret_id

  replication {
    auto {}
  }

  labels = var.labels
}

resource "google_secret_manager_secret_version" "api_secret_v1" {
  secret      = google_secret_manager_secret.api_secret.id
  secret_data = var.secret_api_key_value
}

# Grant Cloud Run Service Account read permissions to Secret Manager
resource "google_secret_manager_secret_iam_member" "sa_secret_access" {
  secret_id = google_secret_manager_secret.api_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# ------------------------------------------------------------------------------
# 4. Google Cloud Run (v2 API): Scalable Serverless Microservice
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "service" {
  name     = local.service_id
  location = var.gcp_region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.cloud_run_sa.email

    # Execution Environment: Second Generation for full Linux kernel compatibility
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

    # Fine-grained Concurrency Tuning (parallel requests per container instance)
    max_instance_request_concurrency = var.max_concurrency

    scaling {
      min_instance_count = var.min_instance_count
      max_instance_count = var.max_instance_count
    }

    containers {
      image = var.container_image

      resources {
        limits = {
          cpu    = var.cpu_limit
          memory = var.memory_limit
        }
        cpu_idle          = true
        startup_cpu_boost = true # Accelerate container initialization for low cold starts
      }

      ports {
        container_port = 8080
      }

      env {
        name  = "ENVIRONMENT"
        value = "production"
      }

      env {
        name  = "CONCURRENCY_LIMIT"
        value = tostring(var.max_concurrency)
      }

      # Secret Manager Environment Variable Binding
      env {
        name = "API_SECRET_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.api_secret.secret_id
            version = "1"
          }
        }
      }

      startup_probe {
        timeout_seconds   = 5
        period_seconds    = 10
        failure_threshold = 3
        http_get {
          path = "/health"
          port = 8080
        }
      }

      liveness_probe {
        timeout_seconds   = 5
        period_seconds    = 15
        failure_threshold = 3
        http_get {
          path = "/health"
          port = 8080
        }
      }
    }

    labels = var.labels
  }

  labels = var.labels

  depends_on = [
    google_secret_manager_secret_version.api_secret_v1,
    google_secret_manager_secret_iam_member.sa_secret_access
  ]
}

# ------------------------------------------------------------------------------
# 5. Public Ingress Access: IAM Member for Unauthenticated Invocations
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service_iam_member" "public_access" {
  count = var.allow_unauthenticated ? 1 : 0

  name     = google_cloud_run_v2_service.service.name
  location = google_cloud_run_v2_service.service.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
