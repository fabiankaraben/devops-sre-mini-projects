# ==============================================================================
# Dev Environment - providers.tf
# ==============================================================================

provider "aws" {
  region                      = var.aws_region
  access_key                  = var.use_localstack ? "test" : null
  secret_key                  = var.use_localstack ? "test" : null
  s3_use_path_style           = var.use_localstack ? true : null
  skip_credentials_validation = var.use_localstack ? true : false
  skip_metadata_api_check     = var.use_localstack ? true : false
  skip_requesting_account_id  = var.use_localstack ? true : false

  dynamic "endpoints" {
    for_each = var.use_localstack ? [1] : []
    content {
      ec2 = var.localstack_endpoint
    }
  }

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "terraform"
      Repository  = "devops-sre-mini-projects"
    }
  }
}
