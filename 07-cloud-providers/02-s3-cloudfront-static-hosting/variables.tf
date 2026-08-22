# ==============================================================================
# Input Variables for Secure S3 & CloudFront Static Web Hosting
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "AWS region for S3 bucket. (CloudFront functions and distributions operate globally via us-east-1)."
  default     = "us-east-1"
}

variable "aws_endpoint" {
  type        = string
  description = "Custom AWS endpoint for local emulator testing (leave empty for real AWS Cloud)."
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Naming prefix for S3 bucket, CloudFront distribution, and OAC resources."
  default     = "s3-cloudfront-secure-site"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, between 3 and 32 characters."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment identifier (e.g. dev, demo, prod)."
  default     = "demo"
}

variable "price_class" {
  type        = string
  description = "CloudFront price class determining edge location coverage (PriceClass_100, PriceClass_200, PriceClass_All)."
  default     = "PriceClass_100"
}

variable "default_root_object" {
  type        = string
  description = "Default object served when requesting the root URL."
  default     = "index.html"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied across all created AWS resources."
  default = {
    Project     = "s3-cloudfront-secure-site"
    Environment = "demo"
    ManagedBy   = "Terraform"
    Security    = "OAC-Protected"
  }
}
