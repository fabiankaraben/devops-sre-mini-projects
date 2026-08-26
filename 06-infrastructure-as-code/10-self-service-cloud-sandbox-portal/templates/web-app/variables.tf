# ==============================================================================
# templates/web-app/variables.tf - Sandbox Parameters
# ==============================================================================

variable "sandbox_id" {
  description = "Unique identifier for this ephemeral sandbox"
  type        = string
}

variable "developer_email" {
  description = "Email of the requesting developer"
  type        = string
  default     = "developer@company.local"
}

variable "aws_region" {
  description = "Target cloud region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.100.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR block"
  type        = string
  default     = "10.100.1.0/24"
}

variable "enable_localstack" {
  description = "Use LocalStack custom endpoint overrides"
  type        = bool
  default     = true
}

variable "localstack_endpoint" {
  description = "LocalStack endpoint URL"
  type        = string
  default     = "http://127.0.0.1:4566"
}
