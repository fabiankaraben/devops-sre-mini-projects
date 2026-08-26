# ==============================================================================
# templates/web-app/main.tf - Ephemeral Web Application Cloud Infrastructure
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
      SandboxId = var.sandbox_id
      Owner     = var.developer_email
      ManagedBy = "IDP-Sandbox-Portal"
      Ephemeral = "true"
    }
  }
}

# ------------------------------------------------------------------------------
# Isolated Network Topology
# ------------------------------------------------------------------------------
resource "aws_vpc" "sandbox_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.sandbox_id}-vpc"
  }
}

resource "aws_subnet" "sandbox_subnet" {
  vpc_id                  = aws_vpc.sandbox_vpc.id
  cidr_block              = var.subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.sandbox_id}-public-subnet"
  }
}

# ------------------------------------------------------------------------------
# Ingress & Egress Security Controls
# ------------------------------------------------------------------------------
resource "aws_security_group" "sandbox_sg" {
  name        = "${var.sandbox_id}-web-sg"
  description = "Ephemeral security group for sandbox ${var.sandbox_id}"
  vpc_id      = aws_vpc.sandbox_vpc.id

  ingress {
    description = "HTTP application traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS secure traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Development server port"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound connections"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.sandbox_id}-sg"
  }
}

# ------------------------------------------------------------------------------
# Ephemeral Object Storage
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "sandbox_bucket" {
  bucket = "${var.sandbox_id}-storage"

  tags = {
    Name = "${var.sandbox_id}-storage"
  }
}
