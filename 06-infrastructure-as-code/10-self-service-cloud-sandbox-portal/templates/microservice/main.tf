# ==============================================================================
# templates/microservice/main.tf - Microservice Backend Cloud Infrastructure
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
      Template  = "microservice"
      ManagedBy = "IDP-Sandbox-Portal"
      Ephemeral = "true"
    }
  }
}

resource "aws_vpc" "ms_vpc" {
  cidr_block           = "10.200.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.sandbox_id}-ms-vpc"
  }
}

resource "aws_security_group" "ms_sg" {
  name        = "${var.sandbox_id}-ms-sg"
  description = "Microservice internal network security"
  vpc_id      = aws_vpc.ms_vpc.id

  ingress {
    description = "gRPC internal port"
    from_port   = 50051
    to_port     = 50051
    protocol    = "tcp"
    cidr_blocks = ["10.200.0.0/16"]
  }

  ingress {
    description = "REST API gateway"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.sandbox_id}-ms-sg"
  }
}

resource "aws_s3_bucket" "data_bucket" {
  bucket = "${var.sandbox_id}-data-store"

  tags = {
    Name = "${var.sandbox_id}-data-store"
  }
}
