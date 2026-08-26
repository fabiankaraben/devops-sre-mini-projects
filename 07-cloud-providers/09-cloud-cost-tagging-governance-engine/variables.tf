# ==============================================================================
# Input Variables - Cloud Cost Governance and Tag Compliance Engine
# ==============================================================================

variable "aws_region" {
  description = "AWS region for deploying FinOps governance infrastructure"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name identifier used in resource naming and tags"
  type        = string
  default     = "cost-governance"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase alphanumeric characters and hyphens."
  }
}

variable "mandatory_tags" {
  description = "List of required billing and allocation tags enforced by the governance engine"
  type        = list(string)
  default     = ["Environment", "Owner", "CostCenter", "Project"]
}

variable "allowed_environments" {
  description = "Allowed enum values for the Environment tag"
  type        = list(string)
  default     = ["production", "staging", "development", "sandbox"]
}

variable "compliance_schedule_cron" {
  description = "EventBridge cron expression for running daily compliance audits (default: 08:00 UTC daily)"
  type        = string
  default     = "cron(0 8 * * ? *)"
}

variable "grace_period_days" {
  description = "Grace period in days before non-compliant resources are subject to automated remediation/termination"
  type        = number
  default     = 7

  validation {
    condition     = var.grace_period_days >= 1 && var.grace_period_days <= 30
    error_message = "Grace period must be between 1 and 30 days."
  }
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for publishing daily compliance digests (leave empty for mock/simulation)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "alert_email" {
  description = "Email address for SNS compliance alert notifications (optional)"
  type        = string
  default     = ""
}

variable "enable_auto_remediation" {
  description = "Enable automated tagging remediation and marking for deletion on non-compliant resources"
  type        = bool
  default     = true
}
