terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

# Default Provider (Primary Region)
provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Environment = "production"
      Project     = "multi-region-dr"
      ManagedBy   = "Terraform"
      Tier        = "disaster-recovery"
    }
  }
}

# Explicit Primary Region Alias
provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = {
      Environment = "production"
      Project     = "multi-region-dr"
      RegionRole  = "Primary"
      ManagedBy   = "Terraform"
    }
  }
}

# Explicit Secondary DR Region Alias
provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = {
      Environment = "production"
      Project     = "multi-region-dr"
      RegionRole  = "SecondaryDR"
      ManagedBy   = "Terraform"
    }
  }
}
