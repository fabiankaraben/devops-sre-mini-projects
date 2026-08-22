# ==============================================================================
# Input Variables for CloudWatch Alarms & SNS Incident Routing
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region for deploying monitoring and notification infrastructure."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for LocalStack emulator testing. Leave empty for real AWS Cloud."
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Naming prefix for CloudWatch alarms, log groups, and SNS topics."
  default     = "cloud-incident-routing"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,28}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, between 3 and 28 characters."
  }
}

variable "environment" {
  type        = string
  description = "Environment identifier (e.g. dev, demo, prod)."
  default     = "demo"
}

variable "cpu_utilization_threshold" {
  type        = number
  description = "CPU utilization percentage threshold that triggers High CPU Alarm (0-100)."
  default     = 80
}

variable "error_5xx_rate_threshold" {
  type        = number
  description = "Number of HTTP 5xx error log occurrences in 60 seconds that triggers High 5xx Alarm."
  default     = 10
}

variable "disk_space_utilization_threshold" {
  type        = number
  description = "Disk space utilization percentage threshold that triggers Disk Space Low Alarm (0-100)."
  default     = 85
}

variable "webhook_endpoint_url" {
  type        = string
  description = "HTTPS/HTTP Webhook URL for SNS notifications (e.g. incident response listener, Slack, PagerDuty)."
  default     = ""
}

variable "notification_email" {
  type        = string
  description = "Optional email address to subscribe to the critical incident SNS topic."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied across all created AWS resources."
  default = {
    Project      = "cloud-incident-routing"
    Environment  = "demo"
    ManagedBy    = "Terraform"
    Architecture = "CloudWatch-CompositeAlarms-SNS"
  }
}
