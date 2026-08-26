# ==============================================================================
# Input Variables for GCP Cloud Run Scalable Microservice
# ==============================================================================

variable "project_id" {
  type        = string
  description = "Google Cloud Platform (GCP) Project ID."
  default     = "demo-cloud-run-project"
}

variable "gcp_region" {
  type        = string
  description = "Target GCP region for Cloud Run and Secret Manager deployment."
  default     = "us-central1"
}

variable "service_name" {
  type        = string
  description = "Name of the Cloud Run microservice."
  default     = "scalable-microservice"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.service_name))
    error_message = "service_name must be lowercase alphanumeric with hyphens, between 3 and 30 characters."
  }
}

variable "container_image" {
  type        = string
  description = "Container image URL to deploy to Cloud Run."
  default     = "us-docker.pkg.dev/cloudrun/container/hello:latest"
}

variable "min_instance_count" {
  type        = number
  description = "Minimum number of container instances (0 enables true serverless Scale-to-Zero)."
  default     = 0

  validation {
    condition     = var.min_instance_count >= 0
    error_message = "min_instance_count must be greater than or equal to 0."
  }
}

variable "max_instance_count" {
  type        = number
  description = "Maximum number of container instances for autoscaling upper boundary."
  default     = 10

  validation {
    condition     = var.max_instance_count >= 1 && var.max_instance_count <= 100
    error_message = "max_instance_count must be between 1 and 100."
  }
}

variable "max_concurrency" {
  type        = number
  description = "Maximum number of concurrent requests routed to a single container instance."
  default     = 80

  validation {
    condition     = var.max_concurrency >= 1 && var.max_concurrency <= 1000
    error_message = "max_concurrency must be between 1 and 1000."
  }
}

variable "cpu_limit" {
  type        = string
  description = "CPU allocated to each Cloud Run container instance (e.g. 1000m = 1 vCPU)."
  default     = "1000m"
}

variable "memory_limit" {
  type        = string
  description = "Memory allocated to each Cloud Run container instance (e.g. 512Mi, 1Gi)."
  default     = "512Mi"
}

variable "allow_unauthenticated" {
  type        = bool
  description = "Whether to allow public unauthenticated invocations (allUsers)."
  default     = true
}

variable "secret_api_key_value" {
  type        = string
  description = "Secret value stored securely in Google Secret Manager and injected into Cloud Run."
  default     = "sk-live-cloudrun-secret-key-2026"
  sensitive   = true
}

variable "labels" {
  type        = map(string)
  description = "Resource labels applied across all GCP resources."
  default = {
    project      = "gcp-cloud-run-microservice"
    environment  = "demo"
    managed_by   = "terraform"
    architecture = "serverless-knative-container"
  }
}
