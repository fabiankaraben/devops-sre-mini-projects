# ==============================================================================
# terraform/variables.tf - Infrastructure Parameters
# ==============================================================================

variable "aws_region" {
  description = "AWS region for infrastructure deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Target environment name"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "Project name identifier"
  type        = string
  default     = "drift-detection-fleet"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "enable_localstack" {
  description = "Enable LocalStack custom endpoint overrides"
  type        = bool
  default     = true
}

variable "localstack_endpoint" {
  description = "LocalStack API endpoint URL"
  type        = string
  default     = "http://127.0.0.1:4566"
}
