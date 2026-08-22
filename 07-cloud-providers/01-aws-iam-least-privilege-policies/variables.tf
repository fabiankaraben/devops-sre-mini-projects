# ==============================================================================
# Input Variables for AWS IAM Least-Privilege & Role Boundaries
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region for deploying IAM and demo infrastructure."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for local emulator testing (e.g. http://127.0.0.1:4566 for LocalStack). Set empty for real AWS."
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Project naming prefix for created IAM roles, policies, and demo S3 buckets."
  default     = "iam-least-privilege"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, between 3 and 24 characters."
  }
}

variable "environment" {
  type        = string
  description = "Environment identifier (e.g. dev, demo, prod)."
  default     = "demo"
}

variable "allowed_regions" {
  type        = list(string)
  description = "List of approved AWS regions enforced by compliance boundaries and SCPs."
  default     = ["us-east-1", "us-east-2", "eu-west-1"]
}

variable "trusted_account_id" {
  type        = string
  description = "Trusted AWS Account ID for role assumption trust policies. Defaults to current caller account if empty."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied across all managed AWS resources."
  default = {
    Project     = "iam-least-privilege"
    ManagedBy   = "Terraform"
    Environment = "demo"
    Security    = "LeastPrivilege"
  }
}
