# ==============================================================================
# Workload Demonstration Infrastructure
# ==============================================================================
# Provisions resources using remote S3 state backend and DynamoDB state lock.
# Includes a configurable time_sleep to demonstrate real-time concurrency locking.
# ==============================================================================

resource "random_id" "app_suffix" {
  byte_length = 4
}

# ------------------------------------------------------------------------------
# 1. Artificial Delay (Used by Concurrency Test Suite)
# ------------------------------------------------------------------------------
resource "time_sleep" "concurrency_delay" {
  count           = var.apply_delay_seconds > 0 ? 1 : 0
  create_duration = "${var.apply_delay_seconds}s"
}

# ------------------------------------------------------------------------------
# 2. Application Configuration SSM Parameter
# ------------------------------------------------------------------------------
resource "aws_ssm_parameter" "app_version" {
  name  = "/${var.environment}/${var.app_name}/version"
  type  = "String"
  value = "v1.0.0"

  tags = {
    Name = "${var.app_name}-config"
  }

  depends_on = [time_sleep.concurrency_delay]
}

# ------------------------------------------------------------------------------
# 3. Application Data S3 Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "app_data" {
  bucket        = "${var.app_name}-${var.environment}-${random_id.app_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${var.app_name}-data"
  }

  depends_on = [time_sleep.concurrency_delay]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
