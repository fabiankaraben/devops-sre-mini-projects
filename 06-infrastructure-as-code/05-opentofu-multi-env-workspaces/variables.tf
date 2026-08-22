# ==============================================================================
# Input Variables for Multi-Environment OpenTofu Workspaces
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region for infrastructure provisioning."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for local emulator testing (leave empty for real AWS Cloud)."
  default     = "http://127.0.0.1:4566"
}

variable "environment" {
  type        = string
  description = "Deployment environment name (must match active workspace: dev, staging, prod)."
  validation {
    condition     = contains(["dev", "staging", "prod", "default"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, default."
  }
}

variable "app_name" {
  type        = string
  description = "Base application identifier used in resource naming."
  default     = "cloud-app"
}

variable "instance_count" {
  type        = number
  description = "Number of compute instances / replicas to provision."
  default     = 1
}

variable "instance_type" {
  type        = string
  description = "EC2 instance size for compute tier."
  default     = "t3.micro"
}

variable "enable_detailed_monitoring" {
  type        = bool
  description = "Enable 1-minute detailed CloudWatch metric collection."
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "Retention period (in days) for CloudWatch log groups."
  default     = 3
}

variable "backup_retention_days" {
  type        = number
  description = "Automated snapshot retention window (in days)."
  default     = 0
}

variable "enable_deletion_protection" {
  type        = bool
  description = "Prevent accidental destruction of stateful storage resources."
  default     = false
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional metadata tags to attach to all resources."
  default     = {}
}
