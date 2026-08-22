# ==============================================================================
# AWS IAM Least-Privilege & Role Boundaries Infrastructure
# ==============================================================================

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.aws_endpoint != "" ? true : false
  skip_metadata_api_check     = var.aws_endpoint != "" ? true : false
  skip_requesting_account_id  = false
  s3_use_path_style           = var.aws_endpoint != "" ? true : false

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [1] : []
    content {
      iam        = var.aws_endpoint
      sts        = var.aws_endpoint
      s3         = var.aws_endpoint
      kms        = var.aws_endpoint
      ec2        = var.aws_endpoint
      cloudwatch = var.aws_endpoint
      logs       = var.aws_endpoint
    }
  }

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = coalesce(var.trusted_account_id, data.aws_caller_identity.current.account_id)

  s3_dev_bucket_name       = "${var.project_name}-dev-${random_string.suffix.result}"
  s3_prod_bucket_name      = "${var.project_name}-prod-${random_string.suffix.result}"
  s3_artifacts_bucket_name = "${var.project_name}-artifacts-${random_string.suffix.result}"
}

# ------------------------------------------------------------------------------
# 1. Random Suffix for Global Resource Uniqueness
# ------------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# ------------------------------------------------------------------------------
# 2. Demo S3 Buckets: Development, Production, CI/CD Artifacts
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "dev" {
  bucket        = local.s3_dev_bucket_name
  force_destroy = true

  tags = {
    Name        = local.s3_dev_bucket_name
    Environment = "development"
    DataClass   = "internal"
  }
}

resource "aws_s3_bucket_versioning" "dev" {
  bucket = aws_s3_bucket.dev.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dev" {
  bucket = aws_s3_bucket.dev.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "dev" {
  bucket = aws_s3_bucket.dev.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "prod" {
  bucket        = local.s3_prod_bucket_name
  force_destroy = true

  tags = {
    Name        = local.s3_prod_bucket_name
    Environment = "production"
    DataClass   = "confidential"
  }
}

resource "aws_s3_bucket_versioning" "prod" {
  bucket = aws_s3_bucket.prod.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "prod" {
  bucket = aws_s3_bucket.prod.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "prod" {
  bucket = aws_s3_bucket.prod.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.s3_artifacts_bucket_name
  force_destroy = true

  tags = {
    Name        = local.s3_artifacts_bucket_name
    Environment = "cicd"
    DataClass   = "build-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# 3. KMS Customer Managed Key (CMK) with Least-Privilege Key Policy
# ------------------------------------------------------------------------------
resource "aws_kms_key" "demo" {
  description             = "Customer Managed Key for Least-Privilege IAM demo encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "LeastPrivilegeKMSPolicy"
    Statement = [
      {
        Sid    = "EnableRootAccountAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowDeveloperAndCICDCryptographicOperations"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::${local.account_id}:root"
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-cmk"
  }
}

resource "aws_kms_alias" "demo" {
  name          = "alias/${var.project_name}-cmk"
  target_key_id = aws_kms_key.demo.key_id
}

# ------------------------------------------------------------------------------
# 4. IAM Permissions Boundaries (Prevent Privilege Escalation)
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "developer_boundary" {
  name        = "${var.project_name}-developer-boundary"
  description = "Permissions boundary defining maximum allowable permissions for developer roles"
  policy      = file("${path.module}/policies/permissions-boundaries/developer-boundary.json")
}

resource "aws_iam_policy" "read_only_boundary" {
  name        = "${var.project_name}-read-only-boundary"
  description = "Permissions boundary ensuring read-only roles cannot execute mutating actions"
  policy      = file("${path.module}/policies/permissions-boundaries/read-only-boundary.json")
}

resource "aws_iam_policy" "cicd_boundary" {
  name        = "${var.project_name}-cicd-boundary"
  description = "Permissions boundary restricting CI/CD pipeline automation to deployment scopes"
  policy      = file("${path.module}/policies/permissions-boundaries/cicd-boundary.json")
}

# ------------------------------------------------------------------------------
# 5. IAM Managed Identity Policies
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "developer_policy" {
  name        = "${var.project_name}-developer-policy"
  description = "Least-privilege policy for engineers allowing Dev S3/EC2/KMS actions with explicit Prod Deny"
  policy      = file("${path.module}/policies/identity-policies/developer-policy.json")
}

resource "aws_iam_policy" "read_only_policy" {
  name        = "${var.project_name}-read-only-policy"
  description = "Broad read-only auditor policy with explicit denies against all state mutating actions"
  policy      = file("${path.module}/policies/identity-policies/read-only-policy.json")
}

resource "aws_iam_policy" "cicd_policy" {
  name        = "${var.project_name}-cicd-policy"
  description = "CI/CD deployment policy with artifact upload rights and strict IAM modification denies"
  policy      = file("${path.module}/policies/identity-policies/cicd-policy.json")
}

resource "aws_iam_policy" "mfa_enforced_policy" {
  name        = "${var.project_name}-mfa-enforced-policy"
  description = "Policy denying high-risk destructive actions unless authenticated with active MFA"
  policy      = file("${path.module}/policies/identity-policies/mfa-enforced-policy.json")
}

# ------------------------------------------------------------------------------
# 6. IAM Roles with Attached Boundaries & Least-Privilege Policies
# ------------------------------------------------------------------------------

# 6.1 Developer Role (MFA Enforced, Boundary Protected)
resource "aws_iam_role" "developer" {
  name                 = "${var.project_name}-developer-role"
  description          = "Role assumed by software engineers for development workload operations"
  permissions_boundary = aws_iam_policy.developer_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeRoleWithMFA"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    RoleType = "Developer"
  }
}

resource "aws_iam_role_policy_attachment" "developer_policy_attach" {
  role       = aws_iam_role.developer.name
  policy_arn = aws_iam_policy.developer_policy.arn
}

resource "aws_iam_role_policy_attachment" "developer_mfa_attach" {
  role       = aws_iam_role.developer.name
  policy_arn = aws_iam_policy.mfa_enforced_policy.arn
}

# 6.2 Read-Only Auditor Role (Boundary Protected)
resource "aws_iam_role" "read_only" {
  name                 = "${var.project_name}-read-only-role"
  description          = "Role assumed by security auditors and view-only dashboard operators"
  permissions_boundary = aws_iam_policy.read_only_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeRoleReadOnly"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    RoleType = "Auditor"
  }
}

resource "aws_iam_role_policy_attachment" "read_only_policy_attach" {
  role       = aws_iam_role.read_only.name
  policy_arn = aws_iam_policy.read_only_policy.arn
}

# 6.3 CI/CD Pipeline Role (Boundary Protected)
resource "aws_iam_role" "cicd" {
  name                 = "${var.project_name}-cicd-role"
  description          = "Role assumed by automated CI/CD runners and deployment pipelines"
  permissions_boundary = aws_iam_policy.cicd_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeRoleCICD"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    RoleType = "Automation"
  }
}

resource "aws_iam_role_policy_attachment" "cicd_policy_attach" {
  role       = aws_iam_role.cicd.name
  policy_arn = aws_iam_policy.cicd_policy.arn
}
