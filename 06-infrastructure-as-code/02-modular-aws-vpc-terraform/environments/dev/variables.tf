# ==============================================================================
# Dev Environment - variables.tf
# ==============================================================================

variable "aws_region" {
  description = "Target AWS region"
  type        = string
  default     = "us-east-1"
}

variable "use_localstack" {
  description = "Whether to route AWS API requests to local LocalStack emulator"
  type        = bool
  default     = true
}

variable "localstack_endpoint" {
  description = "Endpoint URL for LocalStack"
  type        = string
  default     = "http://127.0.0.1:4566"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "modular-aws-vpc"
}

variable "vpc_cidr" {
  description = "The IPv4 CIDR block for the Dev VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "availability_zones" {
  description = "List of Availability Zones for Dev subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDR blocks for Dev"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDR blocks for Dev"
  type        = list(string)
  default     = ["10.10.11.0/24", "10.10.12.0/24", "10.10.13.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to provision NAT Gateway in Dev"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Whether to use a single shared NAT Gateway for cost optimization in Dev"
  type        = bool
  default     = true
}
