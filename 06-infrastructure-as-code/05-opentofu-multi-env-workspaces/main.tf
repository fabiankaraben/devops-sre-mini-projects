# ==============================================================================
# OpenTofu Multi-Environment Infrastructure Resources
# ==============================================================================

# Workspace Safety Guardrail: Ensures active workspace matches variable input
check "workspace_environment_match" {
  assert {
    condition     = var.environment == terraform.workspace
    error_message = "Variable environment ('${var.environment}') does not match active OpenTofu workspace ('${terraform.workspace}'). Use 'tofu workspace select ${var.environment}' first."
  }
}

# Unique suffix for globally unique resources (e.g. S3 buckets)
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# ------------------------------------------------------------------------------
# 1. Workspace-Isolated Object Storage (S3)
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "app_storage" {
  bucket        = "${local.resource_prefix}-storage-${random_string.suffix.result}"
  force_destroy = true

  tags = {
    Name        = "${local.resource_prefix}-storage"
    Environment = terraform.workspace
  }
}

resource "aws_s3_bucket_versioning" "app_storage" {
  bucket = aws_s3_bucket.app_storage.id
  versioning_configuration {
    status = local.is_production || local.is_staging ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_storage" {
  bucket = aws_s3_bucket.app_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "app_storage" {
  bucket = aws_s3_bucket.app_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# 2. Centralized Environment Configuration (SSM Parameter Store)
# ------------------------------------------------------------------------------

resource "aws_ssm_parameter" "app_config" {
  name        = "/app/${terraform.workspace}/config"
  type        = "String"
  description = "Application configuration manifest for ${terraform.workspace} environment"
  value = jsonencode({
    environment                = terraform.workspace
    instance_count             = var.instance_count
    instance_type              = var.instance_type
    detailed_monitoring        = var.enable_detailed_monitoring
    log_retention_days         = var.log_retention_days
    backup_retention_days      = var.backup_retention_days
    deletion_protection_active = var.enable_deletion_protection
  })

  tags = {
    Name        = "/app/${terraform.workspace}/config"
    Environment = terraform.workspace
  }
}

resource "aws_ssm_parameter" "db_endpoint" {
  name        = "/app/${terraform.workspace}/db_endpoint"
  type        = "String"
  description = "Database connection endpoint for ${terraform.workspace}"
  value       = "${terraform.workspace}-db.internal.local:5432"

  tags = {
    Name        = "/app/${terraform.workspace}/db_endpoint"
    Environment = terraform.workspace
  }
}

# ------------------------------------------------------------------------------
# 3. Environment Security Group & Ingress Boundary
# ------------------------------------------------------------------------------

resource "aws_security_group" "app_sg" {
  name        = "${local.resource_prefix}-sg"
  description = "Security group for ${terraform.workspace} compute instances"

  ingress {
    description = "HTTP Traffic (Public for prod, Private for dev/staging)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = local.is_production ? ["0.0.0.0/0"] : ["10.0.0.0/8"]
  }

  ingress {
    description = "HTTPS Traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound traffic permitted"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.resource_prefix}-sg"
    Environment = terraform.workspace
  }
}

# ------------------------------------------------------------------------------
# 4. Observability & Logging (CloudWatch Log Group)
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/app/${terraform.workspace}"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "/aws/app/${terraform.workspace}"
    Environment = terraform.workspace
  }
}
