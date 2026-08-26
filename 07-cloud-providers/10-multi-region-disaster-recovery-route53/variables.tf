# ==============================================================================
# Input Variables - Multi-Region Disaster Recovery with Route 53 Failover
# ==============================================================================

variable "primary_region" {
  description = "Primary active AWS region"
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Secondary disaster recovery (DR) standby AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Unique project prefix for naming multi-region resources"
  type        = string
  default     = "mr-dr-app"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase alphanumeric characters and hyphens."
  }
}

variable "domain_name" {
  description = "Domain name for Route 53 hosted zone and failover DNS records"
  type        = string
  default     = "cloud-dr.internal"
}

variable "subdomain" {
  description = "Subdomain prefix for the active-passive application"
  type        = string
  default     = "app"
}

variable "health_check_interval" {
  description = "Route 53 health check request interval in seconds (10 for Fast, 30 for Standard)"
  type        = number
  default     = 10

  validation {
    condition     = contains([10, 30], var.health_check_interval)
    error_message = "Health check interval must be either 10 (Fast) or 30 (Standard) seconds."
  }
}

variable "failure_threshold" {
  description = "Number of consecutive health check failures before Route 53 triggers failover"
  type        = number
  default     = 3

  validation {
    condition     = var.failure_threshold >= 1 && var.failure_threshold <= 10
    error_message = "Failure threshold must be between 1 and 10."
  }
}

variable "enable_s3_crr" {
  description = "Enable S3 Cross-Region Replication between Primary and Secondary buckets"
  type        = bool
  default     = true
}
