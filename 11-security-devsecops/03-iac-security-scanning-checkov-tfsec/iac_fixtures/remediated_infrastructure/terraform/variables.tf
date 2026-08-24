variable "aws_region" {
  type        = string
  description = "AWS deployment region"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment identifier"
  default     = "production"
}

variable "vpc_id" {
  type        = string
  description = "VPC Identifier for Security Group association"
  default     = "vpc-0a1b2c3d4e5f67890"
}
