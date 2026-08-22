# ==============================================================================
# Input Variables for Event-Driven Serverless Pipeline with Lambda and SQS
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region for deploying serverless infrastructure."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for LocalStack emulator testing. Leave empty for real AWS Cloud."
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Naming prefix for SQS queues, Lambda functions, and CloudWatch alarms."
  default     = "serverless-order-pipeline"

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

variable "sqs_visibility_timeout_seconds" {
  type        = number
  description = "Visibility timeout for primary SQS queue in seconds (must be >= 6x Lambda timeout)."
  default     = 30
}

variable "dlq_max_receive_count" {
  type        = number
  description = "Maximum number of failed processing attempts before message routes to Dead Letter Queue."
  default     = 3
}

variable "batch_size" {
  type        = number
  description = "Maximum number of messages delivered to Lambda in a single batch invocation (1-10000)."
  default     = 10
}

variable "batch_window_seconds" {
  type        = number
  description = "Maximum batching window in seconds before invoking Lambda with accumulated messages (0-300)."
  default     = 5
}

variable "lambda_timeout_seconds" {
  type        = number
  description = "Maximum execution timeout for the Lambda function in seconds."
  default     = 5
}

variable "lambda_memory_mb" {
  type        = number
  description = "Memory allocated to the Lambda function in megabytes."
  default     = 256
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied across all created AWS resources."
  default = {
    Project      = "serverless-order-pipeline"
    Environment  = "demo"
    ManagedBy    = "Terraform"
    Architecture = "EventDriven-SQS-Lambda"
  }
}
