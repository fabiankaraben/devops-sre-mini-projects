# ==============================================================================
# Local Values & Dynamic Workspace Expressions
# ==============================================================================

locals {
  current_workspace = terraform.workspace
  resource_prefix   = "${var.app_name}-${terraform.workspace}"
  is_production     = terraform.workspace == "prod"
  is_staging        = terraform.workspace == "staging"
  is_dev            = terraform.workspace == "dev"

  # Workspace sizing defaults (used if not explicitly overridden by var-files)
  workspace_sizing = {
    dev = {
      instance_type       = "t3.micro"
      instance_count      = 1
      log_retention_days  = 3
      backup_retention    = 0
      deletion_protection = false
    }
    staging = {
      instance_type       = "t3.small"
      instance_count      = 2
      log_retention_days  = 14
      backup_retention    = 7
      deletion_protection = false
    }
    prod = {
      instance_type       = "t3.large"
      instance_count      = 4
      log_retention_days  = 90
      backup_retention    = 30
      deletion_protection = true
    }
    default = {
      instance_type       = "t3.micro"
      instance_count      = 1
      log_retention_days  = 1
      backup_retention    = 0
      deletion_protection = false
    }
  }

  active_sizing = lookup(local.workspace_sizing, terraform.workspace, local.workspace_sizing["default"])

  default_tags = {
    Project     = "DevOps-SRE-Mini-Projects"
    MiniProject = "05-opentofu-multi-env-workspaces"
    Environment = terraform.workspace
    ManagedBy   = "OpenTofu"
    Workspace   = terraform.workspace
  }

  merged_tags = merge(local.default_tags, var.extra_tags)
}
