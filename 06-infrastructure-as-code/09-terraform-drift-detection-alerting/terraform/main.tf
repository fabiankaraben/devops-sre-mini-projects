# ==============================================================================
# terraform/main.tf - Core Managed Cloud Infrastructure
# ==============================================================================

provider "aws" {
  region = var.aws_region

  access_key                  = var.enable_localstack ? "test" : null
  secret_key                  = var.enable_localstack ? "test" : null
  skip_credentials_validation = var.enable_localstack
  skip_metadata_api_check     = var.enable_localstack
  skip_requesting_account_id  = var.enable_localstack
  s3_use_path_style           = var.enable_localstack

  dynamic "endpoints" {
    for_each = var.enable_localstack ? [1] : []
    content {
      ec2 = var.localstack_endpoint
      s3  = var.localstack_endpoint
      sts = var.localstack_endpoint
      iam = var.localstack_endpoint
    }
  }

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ------------------------------------------------------------------------------
# 1. Virtual Private Cloud (VPC) & Subnet
# ------------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name       = "${var.project_name}-vpc"
    Compliance = "Strict"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
    Tier = "Public"
  }
}

# ------------------------------------------------------------------------------
# 2. Application Firewall Security Group (Strict Ingress Rules)
# ------------------------------------------------------------------------------
resource "aws_security_group" "web_sg" {
  name        = "${var.project_name}-web-sg"
  description = "Authorized firewall rules for web workloads"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow inbound HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow inbound HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name         = "${var.project_name}-web-sg"
    SecurityTier = "Tier1"
  }
}

# ------------------------------------------------------------------------------
# 3. Secure S3 Assets Storage Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "storage" {
  bucket = "${var.project_name}-assets-bucket"

  tags = {
    Name               = "${var.project_name}-assets-bucket"
    DataClassification = "Internal"
  }
}
