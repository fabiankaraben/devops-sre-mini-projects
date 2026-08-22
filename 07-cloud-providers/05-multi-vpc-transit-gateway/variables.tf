# ==============================================================================
# Input Variables for Multi-VPC Networking with Transit Gateway
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region for deploying multi-VPC network infrastructure."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for LocalStack emulator testing. Leave empty for real AWS Cloud."
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Naming prefix applied to all VPCs, subnets, route tables, and Transit Gateway resources."
  default     = "multi-vpc-hub-spoke"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,28}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, between 3 and 28 characters."
  }
}

variable "availability_zone" {
  type        = string
  description = "Target Availability Zone for deploying subnets."
  default     = "us-east-1a"
}

# ------------------------------------------------------------------------------
# CIDR Allocations (Non-Overlapping RFC 1918 Private Ranges)
# ------------------------------------------------------------------------------
variable "prod_vpc_cidr" {
  type        = string
  description = "CIDR block for the Production Spoke VPC."
  default     = "10.10.0.0/16"
}

variable "prod_app_subnet_cidr" {
  type        = string
  description = "CIDR block for the Production App tier subnet."
  default     = "10.10.1.0/24"
}

variable "prod_db_subnet_cidr" {
  type        = string
  description = "CIDR block for the Production Database tier subnet."
  default     = "10.10.2.0/24"
}

variable "staging_vpc_cidr" {
  type        = string
  description = "CIDR block for the Staging Spoke VPC."
  default     = "10.20.0.0/16"
}

variable "staging_app_subnet_cidr" {
  type        = string
  description = "CIDR block for the Staging App tier subnet."
  default     = "10.20.1.0/24"
}

variable "staging_db_subnet_cidr" {
  type        = string
  description = "CIDR block for the Staging Database tier subnet."
  default     = "10.20.2.0/24"
}

variable "shared_vpc_cidr" {
  type        = string
  description = "CIDR block for the Shared Services Hub VPC."
  default     = "10.30.0.0/16"
}

variable "shared_tools_subnet_cidr" {
  type        = string
  description = "CIDR block for the Shared Tooling & CI/CD subnet."
  default     = "10.30.1.0/24"
}

variable "shared_logging_subnet_cidr" {
  type        = string
  description = "CIDR block for the Central Logging & Monitoring subnet."
  default     = "10.30.2.0/24"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied across all created AWS networking resources."
  default = {
    Project      = "multi-vpc-hub-spoke"
    Environment  = "demo"
    ManagedBy    = "Terraform"
    Architecture = "MultiVPC-TransitGateway-HubSpoke"
  }
}
