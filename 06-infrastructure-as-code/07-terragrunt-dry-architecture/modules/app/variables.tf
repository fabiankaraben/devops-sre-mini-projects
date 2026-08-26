# ==============================================================================
# variables.tf - Input Variables for App Module
# ==============================================================================

variable "name" {
  description = "Application name prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the application security group and resources are deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of Subnet IDs where application compute instances are deployed"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance size / class"
  type        = string
  default     = "t3.micro"
}

variable "instance_count" {
  description = "Number of application instance replicas to provision"
  type        = number
  default     = 1
}

variable "app_port" {
  description = "TCP port exposed by the application"
  type        = number
  default     = 8080
}

variable "ami_id" {
  description = "AMI ID to use for application instances (defaults to Amazon Linux 2 / LocalStack mock)"
  type        = string
  default     = "ami-12345678"
}

variable "tags" {
  description = "Tags to apply to application resources"
  type        = map(string)
  default     = {}
}
