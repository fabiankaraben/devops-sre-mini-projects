# ==============================================================================
# Input Variables for Backend Bootstrap
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region for backend infrastructure."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for local emulator testing (e.g. http://127.0.0.1:4566). Set empty for real AWS."
  default     = "http://127.0.0.1:4566"
}

variable "state_bucket_prefix" {
  type        = string
  description = "Prefix for the S3 bucket storing remote state files."
  default     = "devops-tfstate"

  validation {
    condition     = can(regex("^[a-z0-9.-]{3,37}$", var.state_bucket_prefix))
    error_message = "Bucket prefix must be lowercase alphanumeric and between 3 and 37 characters."
  }
}

variable "dynamodb_table_name" {
  type        = string
  description = "Name of the DynamoDB table used for Terraform state locking."
  default     = "devops-tflocks"
}

variable "environment" {
  type        = string
  description = "Environment identifier (e.g., shared, dev, prod)."
  default     = "shared"
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags to apply to all bootstrap resources."
  default     = {}
}
