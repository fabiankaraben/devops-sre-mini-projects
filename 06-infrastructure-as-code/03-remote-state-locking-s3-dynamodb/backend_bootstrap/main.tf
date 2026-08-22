# ==============================================================================
# Backend Bootstrap Infrastructure: S3 State Bucket & DynamoDB Lock Table
# ==============================================================================

locals {
  bucket_name = "${var.state_bucket_prefix}-${random_string.suffix.result}"
  common_tags = merge(
    var.extra_tags,
    {
      Environment = var.environment
      Purpose     = "TerraformRemoteState"
    }
  )
}

# ------------------------------------------------------------------------------
# 1. Random Suffix for Global S3 Bucket Uniqueness
# ------------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# ------------------------------------------------------------------------------
# 2. S3 Bucket for Terraform Remote State
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = true # Enables clean teardown for lab/demo environments

  tags = merge(local.common_tags, {
    Name = local.bucket_name
  })
}

# ------------------------------------------------------------------------------
# 3. S3 Bucket Versioning (Preserves State History & Enables Rollback)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ------------------------------------------------------------------------------
# 4. S3 Server-Side Encryption (Protects Sensitive State & Secrets at Rest)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ------------------------------------------------------------------------------
# 5. S3 Public Access Block (Strict Defense-in-Depth against Public Leaks)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# 6. DynamoDB Table for Distributed State Locking
# ------------------------------------------------------------------------------
# Terraform requires a partition key named 'LockID' of type String ('S').
# ------------------------------------------------------------------------------
resource "aws_dynamodb_table" "locks" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = false
  }

  tags = merge(local.common_tags, {
    Name = var.dynamodb_table_name
  })
}
