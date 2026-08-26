# ==============================================================================
# Output Values for GCP Cloud Run Scalable Microservice
# ==============================================================================

output "service_url" {
  description = "Public HTTPS invocation endpoint for the Google Cloud Run microservice"
  value       = google_cloud_run_v2_service.service.uri
}

output "service_name" {
  description = "Unique identifier of the deployed Cloud Run service"
  value       = google_cloud_run_v2_service.service.name
}

output "service_location" {
  description = "Google Cloud region where the service is deployed"
  value       = google_cloud_run_v2_service.service.location
}

output "service_account_email" {
  description = "Email of the dedicated least-privilege IAM runtime Service Account"
  value       = google_service_account.cloud_run_sa.email
}

output "secret_id" {
  description = "Secret Manager secret identifier"
  value       = google_secret_manager_secret.api_secret.secret_id
}

output "concurrency_settings" {
  description = "Autoscaling and fine-grained concurrency configuration"
  value = {
    max_instance_request_concurrency = var.max_concurrency
    min_instance_count               = var.min_instance_count
    max_instance_count               = var.max_instance_count
    scale_to_zero_enabled            = var.min_instance_count == 0
  }
}

output "architecture_summary" {
  description = "High-level summary of the Serverless Microservice architecture"
  value = {
    platform            = "Google Cloud Run (v2)"
    runtime_environment = "EXECUTION_ENVIRONMENT_GEN2"
    secret_integration  = "Google Secret Manager (Direct Environment Variable Injection)"
    startup_boost       = "Enabled (Startup CPU Boost)"
    public_access       = var.allow_unauthenticated ? "Allowed (roles/run.invoker to allUsers)" : "Restricted"
  }
}
