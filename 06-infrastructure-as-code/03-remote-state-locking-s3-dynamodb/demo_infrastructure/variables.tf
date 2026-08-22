# ==============================================================================
# Input Variables for Workload Infrastructure
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for local emulator testing. Set empty for real AWS."
  default     = "http://127.0.0.1:4566"
}

variable "environment" {
  type        = string
  description = "Deployment environment (e.g. dev, staging, prod)."
  default     = "dev"
}

variable "app_name" {
  type        = string
  description = "Application name for demo workload resources."
  default     = "order-processing-service"
}

variable "apply_delay_seconds" {
  type        = number
  description = "Artificial sleep duration in seconds during apply to demonstrate concurrent lock acquisition."
  default     = 0
}
