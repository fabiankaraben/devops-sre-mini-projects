# ==============================================================================
# VPC Module - variables.tf
# ==============================================================================

variable "vpc_cidr" {
  description = "The IPv4 CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "The vpc_cidr must be a valid IPv4 CIDR block (e.g., 10.0.0.0/16)."
  }
}

variable "availability_zones" {
  description = "List of Availability Zones to deploy subnets into"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 Availability Zones are required for High Availability."
  }
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets (must match length of availability_zones)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "At least 2 public subnet CIDRs are required."
  }
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets (must match length of availability_zones)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "At least 2 private subnet CIDRs are required."
  }
}

variable "enable_nat_gateway" {
  description = "Whether to provision NAT Gateways for private subnet outbound internet access"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Whether to provision a single shared NAT Gateway across all AZs (cost-effective for Dev) or one per AZ (High Availability for Prod)"
  type        = bool
  default     = false
}

variable "environment" {
  description = "Target deployment environment (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project or workload name for resource naming and tagging"
  type        = string
  default     = "modular-aws-vpc"
}

variable "tags" {
  description = "Additional tags to merge into all provisioned AWS resources"
  type        = map(string)
  default     = {}
}
