# ==============================================================================
# root.hcl - Root Terragrunt Architecture Configuration
# ==============================================================================
# Centralizes remote state backend generation, provider generation with dynamic
# tags and AssumeRole parameters, and global input inheritance.
# ==============================================================================

locals {
  # Automatically load account, environment, and region configurations
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  # Extract common variables for cleaner referencing
  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
  environment  = local.env_vars.locals.environment
  aws_region   = local.region_vars.locals.aws_region

  # LocalStack zero-cost local emulation settings
  use_localstack      = get_env("USE_LOCALSTACK", "true") == "true"
  localstack_endpoint = get_env("LOCALSTACK_ENDPOINT", "http://127.0.0.1:4566")
}

# ------------------------------------------------------------------------------
# 1. GENERATE PROVIDER: Dynamically creates provider.tf for all child modules
# ------------------------------------------------------------------------------
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  # Real AWS multi-account IAM role assumption:
  # assume_role {
  #   role_arn = "arn:aws:iam::${local.account_id}:role/OrganizationAccountAccessRole"
  # }

%{if local.use_localstack}
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    apigateway     = "${local.localstack_endpoint}"
    cloudformation = "${local.localstack_endpoint}"
    cloudwatch     = "${local.localstack_endpoint}"
    dynamodb       = "${local.localstack_endpoint}"
    ec2            = "${local.localstack_endpoint}"
    iam            = "${local.localstack_endpoint}"
    kms            = "${local.localstack_endpoint}"
    s3             = "${local.localstack_endpoint}"
    sts            = "${local.localstack_endpoint}"
  }
%{endif}

  default_tags {
    tags = {
      Account     = "${local.account_name}"
      Environment = "${local.environment}"
      Region      = "${local.aws_region}"
      ManagedBy   = "Terragrunt"
      Project     = "DevOps-SRE-Terragrunt-Fleet"
    }
  }
}
EOF
}

# ------------------------------------------------------------------------------
# 2. REMOTE STATE: Dynamically configures S3 backend and DynamoDB lock tables
# ------------------------------------------------------------------------------
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = merge(
    {
      encrypt        = true
      bucket         = "terragrunt-state-${local.account_name}-${local.aws_region}"
      key            = "${path_relative_to_include()}/terraform.tfstate"
      region         = local.aws_region
      dynamodb_table = "terragrunt-locks-${local.account_name}"
    },
    local.use_localstack ? {
      endpoint                    = local.localstack_endpoint
      dynamodb_endpoint           = local.localstack_endpoint
      skip_credentials_validation = true
      skip_metadata_api_check     = true
      skip_region_validation      = true
      skip_requesting_account_id  = true
      skip_bucket_ssencryption    = true
      skip_bucket_versioning      = true
      skip_bucket_root_access     = true
      skip_bucket_enforced_tls    = true
      use_path_style              = true
    } : {}
  )
}

# ------------------------------------------------------------------------------
# 3. GLOBAL INPUTS: Merges inherited metadata tags into child module variables
# ------------------------------------------------------------------------------
inputs = merge(
  local.account_vars.locals,
  local.env_vars.locals,
  local.region_vars.locals,
  {
    tags = {
      Account     = local.account_name
      Environment = local.environment
      Region      = local.aws_region
      ManagedBy   = "Terragrunt"
    }
  }
)
