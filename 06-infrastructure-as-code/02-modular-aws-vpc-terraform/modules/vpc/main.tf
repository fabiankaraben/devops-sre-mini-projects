# ==============================================================================
# Modular High-Availability AWS VPC - main.tf
# ==============================================================================

locals {
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.availability_zones)) : 0

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "modules/vpc"
    },
    var.tags
  )
}

# ------------------------------------------------------------------------------
# 1. Virtual Private Cloud (VPC)
# ------------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-vpc"
    }
  )
}

# ------------------------------------------------------------------------------
# 2. Internet Gateway (IGW)
# ------------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-igw"
    }
  )
}

# ------------------------------------------------------------------------------
# 3. Public Subnets (Across Availability Zones)
# ------------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = element(var.availability_zones, count.index)
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-public-${element(var.availability_zones, count.index)}"
      Tier = "public"
    }
  )
}

# ------------------------------------------------------------------------------
# 4. Private Subnets (Across Availability Zones)
# ------------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count                   = length(var.private_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = element(var.availability_zones, count.index)
  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-private-${element(var.availability_zones, count.index)}"
      Tier = "private"
    }
  )
}

# ------------------------------------------------------------------------------
# 5. Elastic IPs for NAT Gateways
# ------------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-nat-eip-${count.index + 1}"
    }
  )

  depends_on = [aws_internet_gateway.this]
}

# ------------------------------------------------------------------------------
# 6. NAT Gateways (Single for Dev vs Multi-AZ HA for Prod)
# ------------------------------------------------------------------------------
resource "aws_nat_gateway" "this" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-nat-gw-${element(var.availability_zones, count.index)}"
    }
  )

  depends_on = [aws_internet_gateway.this]
}

# ------------------------------------------------------------------------------
# 7. Public Route Table & Internet Gateway Route
# ------------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-public-rt"
      Tier = "public"
    }
  )
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------------------------
# 8. Private Route Tables & NAT Gateway Routes
# ------------------------------------------------------------------------------
resource "aws_route_table" "private" {
  count  = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.availability_zones)) : 1
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = var.single_nat_gateway ? "${var.project_name}-${var.environment}-private-rt" : "${var.project_name}-${var.environment}-private-rt-${element(var.availability_zones, count.index)}"
      Tier = "private"
    }
  )
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat_gateway ? 0 : count.index].id
}

# ------------------------------------------------------------------------------
# 9. Default Security Group Hardening (CIS Benchmark)
# ------------------------------------------------------------------------------
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${var.environment}-default-sg-hardened"
    }
  )
}
