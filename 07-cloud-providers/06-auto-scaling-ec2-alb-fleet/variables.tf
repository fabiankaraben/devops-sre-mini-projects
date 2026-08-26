# ==============================================================================
# Input Variables for High-Availability Auto Scaling EC2 Fleet behind ALB
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Target AWS region for deploying the multi-AZ infrastructure."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint URL for LocalStack emulator testing. Leave empty for real AWS."
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Naming prefix applied to all VPC, ALB, Target Group, Launch Template, and ASG resources."
  default     = "asg-alb-fleet"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,28}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, between 3 and 28 characters."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the dedicated Virtual Private Cloud (VPC)."
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "List of CIDR blocks for multi-AZ public subnets hosting ALB and EC2 instances."
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "At least 2 public subnet CIDRs are required for High Availability across multiple Availability Zones."
  }
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the Auto Scaling Group fleet (AWS Free Tier eligible: t2.micro or t3.micro)."
  default     = "t3.micro"
}

variable "asg_min_size" {
  type        = number
  description = "Minimum number of instances running in the Auto Scaling Group."
  default     = 1

  validation {
    condition     = var.asg_min_size >= 1
    error_message = "asg_min_size must be at least 1."
  }
}

variable "asg_desired_capacity" {
  type        = number
  description = "Initial desired number of instances in the Auto Scaling Group."
  default     = 2

  validation {
    condition     = var.asg_desired_capacity >= 1
    error_message = "asg_desired_capacity must be at least 1."
  }
}

variable "asg_max_size" {
  type        = number
  description = "Maximum number of instances to which the Auto Scaling Group can scale out."
  default     = 4

  validation {
    condition     = var.asg_max_size >= var.asg_desired_capacity
    error_message = "asg_max_size must be greater than or equal to asg_desired_capacity."
  }
}

variable "target_cpu_utilization" {
  type        = number
  description = "Target average CPU utilization percentage for dynamic Target Tracking scaling policy."
  default     = 50.0

  validation {
    condition     = var.target_cpu_utilization > 0.0 && var.target_cpu_utilization <= 100.0
    error_message = "target_cpu_utilization must be between 1.0 and 100.0 percent."
  }
}

variable "health_check_grace_period" {
  type        = number
  description = "Grace period (in seconds) after instance launch before ELB health checks determine replacement."
  default     = 180
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied across all provisioned AWS resources."
  default = {
    Project      = "asg-alb-fleet"
    Environment  = "demo"
    ManagedBy    = "Terraform"
    Architecture = "HighAvailability-ALB-ASG"
  }
}
