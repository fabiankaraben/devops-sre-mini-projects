# ==============================================================================
# AWS Provider Configuration for Workload Infrastructure
# ==============================================================================

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.aws_endpoint != ""
  skip_metadata_api_check     = var.aws_endpoint != ""
  skip_requesting_account_id  = var.aws_endpoint != ""
  s3_use_path_style           = var.aws_endpoint != ""

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [1] : []
    content {
      s3       = var.aws_endpoint
      dynamodb = var.aws_endpoint
      ssm      = var.aws_endpoint
      sts      = var.aws_endpoint
    }
  }

  default_tags {
    tags = {
      Project     = "remote-state-locking"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "devops-sre-mini-projects"
      Workload    = var.app_name
    }
  }
}
