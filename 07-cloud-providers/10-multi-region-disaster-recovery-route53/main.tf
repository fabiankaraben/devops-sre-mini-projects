# ==============================================================================
# Main Infrastructure - Multi-Region Disaster Recovery with Route 53 Failover
# ==============================================================================

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  name_prefix      = "${var.project_name}-${random_string.suffix.result}"
  primary_bucket   = "${local.name_prefix}-primary-${var.primary_region}"
  secondary_bucket = "${local.name_prefix}-secondary-${var.secondary_region}"
  fqdn             = "${var.subdomain}.${var.domain_name}"
}

# ------------------------------------------------------------------------------
# 1. IAM Role & Policy for S3 Cross-Region Replication (CRR)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "replication" {
  name = "${local.name_prefix}-s3-crr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "replication" {
  name        = "${local.name_prefix}-s3-crr-policy"
  description = "Allows S3 to replicate objects from Primary to Secondary region"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = [aws_s3_bucket.primary.arn]
      },
      {
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.primary.arn}/*"]
      },
      {
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.secondary.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "replication" {
  role       = aws_iam_role.replication.name
  policy_arn = aws_iam_policy.replication.arn
}

# ------------------------------------------------------------------------------
# 2. Secondary DR S3 Bucket (Target Region: us-west-2)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "secondary" {
  provider      = aws.secondary
  bucket        = local.secondary_bucket
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.secondary.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.secondary.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ------------------------------------------------------------------------------
# 3. Primary S3 Bucket with Cross-Region Replication (Source: us-east-1)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "primary" {
  provider      = aws.primary
  bucket        = local.primary_bucket
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "primary" {
  provider = aws.primary
  bucket   = aws_s3_bucket.primary.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "primary" {
  provider = aws.primary
  bucket   = aws_s3_bucket.primary.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "replication" {
  provider   = aws.primary
  count      = var.enable_s3_crr ? 1 : 0
  depends_on = [aws_s3_bucket_versioning.primary, aws_s3_bucket_versioning.secondary]

  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.primary.id

  rule {
    id     = "ReplicateAllObjectsToSecondary"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.secondary.arn
      storage_class = "STANDARD"
    }
  }
}

# ------------------------------------------------------------------------------
# 4. Multi-Region VPC & Networking
# ------------------------------------------------------------------------------
resource "aws_vpc" "primary" {
  provider             = aws.primary
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-primary-vpc"
  }
}

resource "aws_vpc" "secondary" {
  provider             = aws.secondary
  cidr_block           = "10.2.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-secondary-vpc"
  }
}

# ------------------------------------------------------------------------------
# 5. Route 53 Hosted Zone & Health Checks
# ------------------------------------------------------------------------------
resource "aws_route53_zone" "primary_zone" {
  name = var.domain_name

  vpc {
    vpc_id     = aws_vpc.primary.id
    vpc_region = var.primary_region
  }

  vpc {
    vpc_id     = aws_vpc.secondary.id
    vpc_region = var.secondary_region
  }
}

# Route 53 Health Check monitoring the Primary Region endpoint
resource "aws_route53_health_check" "primary" {
  ip_address        = "10.1.10.50"
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  request_interval  = var.health_check_interval
  failure_threshold = var.failure_threshold

  tags = {
    Name      = "${local.name_prefix}-primary-health-check"
    Monitored = "PrimaryRegion"
  }
}

# ------------------------------------------------------------------------------
# 6. Route 53 Failover DNS Routing Policies (Active-Passive)
# ------------------------------------------------------------------------------
# Primary Record (Active when Route 53 Health Check is Passing)
resource "aws_route53_record" "primary" {
  zone_id = aws_route53_zone.primary_zone.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 10

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary-region"
  health_check_id = aws_route53_health_check.primary.id
  records         = ["10.1.10.50"]
}

# Secondary DR Record (Activated automatically upon Primary outage)
resource "aws_route53_record" "secondary" {
  zone_id = aws_route53_zone.primary_zone.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 10

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier = "secondary-region"
  records        = ["10.2.10.50"]
}
