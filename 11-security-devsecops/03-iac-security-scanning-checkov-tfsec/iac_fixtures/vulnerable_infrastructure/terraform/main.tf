# ==============================================================================
# main.tf - Vulnerable Terraform Infrastructure Manifest (Security Anti-Patterns)
# ==============================================================================
# Contains intentional AWS security misconfigurations for Checkov & tfsec auditing:
# 1. CKV_AWS_19, CKV_AWS_21, CKV_AWS_53: Public S3 bucket without encryption/versioning
# 2. CKV_AWS_24, CKV_AWS_260: Insecure Security Group with 0.0.0.0/0 SSH ingress
# 3. CKV_AWS_3: Unencrypted EBS volume
# 4. CKV_AWS_16, CKV_AWS_17, CKV_AWS_157: Unencrypted public RDS without backups
# 5. CKV_AWS_1, CKV_AWS_62: Overly permissive IAM Policy with Action: * and Resource: *
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------------------
# 1. Vulnerability: Unencrypted, Publicly Accessible S3 Storage Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "insecure_customer_data" {
  bucket        = "corporate-customer-raw-backups-insecure"
  force_destroy = true

  tags = {
    Environment = var.environment
    Compliance  = "Non-Compliant"
  }
}

# Insecure public bucket ACL
resource "aws_s3_bucket_acl" "insecure_acl" {
  bucket = aws_s3_bucket.insecure_customer_data.id
  acl    = "public-read"
}

# ------------------------------------------------------------------------------
# 2. Vulnerability: Wide-Open Security Group (0.0.0.0/0 SSH Ingress)
# ------------------------------------------------------------------------------
resource "aws_security_group" "insecure_bastion_sg" {
  name        = "insecure-bastion-sg"
  description = "Security group with open public SSH access"
  vpc_id      = "vpc-12345678"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Violation: Open to entire internet
  }

  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Violation: Open RDP
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------------------------
# 3. Vulnerability: Unencrypted Elastic Block Store (EBS) Storage Volume
# ------------------------------------------------------------------------------
resource "aws_ebs_volume" "insecure_database_volume" {
  availability_zone = "us-east-1a"
  size              = 100
  encrypted         = false # Violation: Plaintext disk storage

  tags = {
    Name = "unencrypted-production-db-disk"
  }
}

# ------------------------------------------------------------------------------
# 4. Vulnerability: Publicly Accessible RDS Database Without Encryption
# ------------------------------------------------------------------------------
resource "aws_db_instance" "insecure_postgres" {
  identifier             = "insecure-production-database"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "14"
  instance_class         = "db.t3.micro"
  username               = "dbadmin"
  password               = "HardcodedPlaintextPassword123!" # Violation: Hardcoded secret
  publicly_accessible    = true                             # Violation: Exposed to public internet
  storage_encrypted      = false                            # Violation: Unencrypted storage
  backup_retention_period = 0                               # Violation: Backups disabled
  skip_final_snapshot    = true

  tags = {
    Environment = var.environment
  }
}

# ------------------------------------------------------------------------------
# 5. Vulnerability: Overly Permissive Wildcard IAM Policy
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "wildcard_admin_access" {
  name        = "insecure-wildcard-administrator-policy"
  description = "Excessive permissions policy violating least-privilege"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*" # Violation: Full admin permissions
        Resource = "*" # Violation: Unscoped resource targeting
      }
    ]
  })
}
