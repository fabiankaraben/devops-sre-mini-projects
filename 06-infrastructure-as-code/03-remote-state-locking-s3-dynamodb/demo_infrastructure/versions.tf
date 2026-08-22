# ==============================================================================
# Terraform Engine & Remote S3 Backend Configuration
# ==============================================================================
# Uses partial backend configuration for the S3 backend. Backend parameters
# (bucket, key, region, dynamodb_table, endpoint) are supplied dynamically
# at `init` time via `-backend-config=<file>` or command-line flags.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  # Partial S3 backend configuration
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 6.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0, < 1.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }
  }
}
