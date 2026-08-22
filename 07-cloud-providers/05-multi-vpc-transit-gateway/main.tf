# ==============================================================================
# Multi-VPC Networking with Transit Gateway (Hub-and-Spoke Topology)
# ==============================================================================

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.aws_endpoint != "" ? true : false
  skip_metadata_api_check     = var.aws_endpoint != "" ? true : false
  skip_requesting_account_id  = false

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [1] : []
    content {
      ec2 = var.aws_endpoint
      sts = var.aws_endpoint
    }
  }

  default_tags {
    tags = var.tags
  }
}

# ==============================================================================
# 1. Production Spoke VPC (10.10.0.0/16)
# ==============================================================================
resource "aws_vpc" "prod" {
  cidr_block           = var.prod_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-prod-vpc"
    Environment = "production"
    Tier        = "Spoke"
  }
}

resource "aws_subnet" "prod_app" {
  vpc_id            = aws_vpc.prod.id
  cidr_block        = var.prod_app_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-prod-app-subnet"
    Tier = "App"
  }
}

resource "aws_subnet" "prod_db" {
  vpc_id            = aws_vpc.prod.id
  cidr_block        = var.prod_db_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-prod-db-subnet"
    Tier = "Database"
  }
}

resource "aws_route_table" "prod" {
  vpc_id = aws_vpc.prod.id

  tags = {
    Name = "${var.project_name}-prod-rt"
  }
}

resource "aws_route_table_association" "prod_app" {
  subnet_id      = aws_subnet.prod_app.id
  route_table_id = aws_route_table.prod.id
}

resource "aws_route_table_association" "prod_db" {
  subnet_id      = aws_subnet.prod_db.id
  route_table_id = aws_route_table.prod.id
}

resource "aws_security_group" "prod_app_sg" {
  name        = "${var.project_name}-prod-app-sg"
  description = "Security Group for Prod App tier (Allows Shared Services, Denies Staging)"
  vpc_id      = aws_vpc.prod.id

  ingress {
    description = "Allow HTTPS from Shared Services Hub"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.shared_vpc_cidr]
  }

  ingress {
    description = "Allow SSH from Shared Bastion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.shared_tools_subnet_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-prod-app-sg"
  }
}

# ==============================================================================
# 2. Staging Spoke VPC (10.20.0.0/16)
# ==============================================================================
resource "aws_vpc" "staging" {
  cidr_block           = var.staging_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-staging-vpc"
    Environment = "staging"
    Tier        = "Spoke"
  }
}

resource "aws_subnet" "staging_app" {
  vpc_id            = aws_vpc.staging.id
  cidr_block        = var.staging_app_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-staging-app-subnet"
    Tier = "App"
  }
}

resource "aws_subnet" "staging_db" {
  vpc_id            = aws_vpc.staging.id
  cidr_block        = var.staging_db_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-staging-db-subnet"
    Tier = "Database"
  }
}

resource "aws_route_table" "staging" {
  vpc_id = aws_vpc.staging.id

  tags = {
    Name = "${var.project_name}-staging-rt"
  }
}

resource "aws_route_table_association" "staging_app" {
  subnet_id      = aws_subnet.staging_app.id
  route_table_id = aws_route_table.staging.id
}

resource "aws_route_table_association" "staging_db" {
  subnet_id      = aws_subnet.staging_db.id
  route_table_id = aws_route_table.staging.id
}

resource "aws_security_group" "staging_app_sg" {
  name        = "${var.project_name}-staging-app-sg"
  description = "Security Group for Staging App tier (Allows Shared Services, Denies Prod)"
  vpc_id      = aws_vpc.staging.id

  ingress {
    description = "Allow HTTP/HTTPS from Shared Services Hub"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.shared_vpc_cidr]
  }

  ingress {
    description = "Allow SSH from Shared Bastion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.shared_tools_subnet_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-staging-app-sg"
  }
}

# ==============================================================================
# 3. Shared Services Hub VPC (10.30.0.0/16)
# ==============================================================================
resource "aws_vpc" "shared" {
  cidr_block           = var.shared_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-shared-vpc"
    Environment = "shared-services"
    Tier        = "Hub"
  }
}

resource "aws_subnet" "shared_tools" {
  vpc_id            = aws_vpc.shared.id
  cidr_block        = var.shared_tools_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-shared-tools-subnet"
    Tier = "Tools"
  }
}

resource "aws_subnet" "shared_logging" {
  vpc_id            = aws_vpc.shared.id
  cidr_block        = var.shared_logging_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-shared-logging-subnet"
    Tier = "Logging"
  }
}

resource "aws_route_table" "shared" {
  vpc_id = aws_vpc.shared.id

  tags = {
    Name = "${var.project_name}-shared-rt"
  }
}

resource "aws_route_table_association" "shared_tools" {
  subnet_id      = aws_subnet.shared_tools.id
  route_table_id = aws_route_table.shared.id
}

resource "aws_route_table_association" "shared_logging" {
  subnet_id      = aws_subnet.shared_logging.id
  route_table_id = aws_route_table.shared.id
}

resource "aws_security_group" "shared_tools_sg" {
  name        = "${var.project_name}-shared-tools-sg"
  description = "Security Group for Shared Tools (Allows ingress from Prod and Staging)"
  vpc_id      = aws_vpc.shared.id

  ingress {
    description = "Allow CI/CD and Artifactory access from Prod"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.prod_vpc_cidr]
  }

  ingress {
    description = "Allow CI/CD and Artifactory access from Staging"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.staging_vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-shared-tools-sg"
  }
}

# ==============================================================================
# 4. AWS Transit Gateway (TGW) Core Topology
# ==============================================================================
resource "aws_ec2_transit_gateway" "tgw" {
  description                     = "Central Hub-and-Spoke Transit Gateway with Route Segmentation"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = {
    Name = "${var.project_name}-tgw"
  }
}

# ------------------------------------------------------------------------------
# TGW VPC Attachments
# ------------------------------------------------------------------------------
resource "aws_ec2_transit_gateway_vpc_attachment" "prod" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.prod.id
  subnet_ids         = [aws_subnet.prod_app.id]

  tags = {
    Name = "${var.project_name}-prod-tgw-attachment"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "staging" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.staging.id
  subnet_ids         = [aws_subnet.staging_app.id]

  tags = {
    Name = "${var.project_name}-staging-tgw-attachment"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "shared" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.shared.id
  subnet_ids         = [aws_subnet.shared_tools.id]

  tags = {
    Name = "${var.project_name}-shared-tgw-attachment"
  }
}

# ------------------------------------------------------------------------------
# TGW Route Tables: Spoke Route Table (Prod + Staging Isolation)
# ------------------------------------------------------------------------------
resource "aws_ec2_transit_gateway_route_table" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id

  tags = {
    Name = "${var.project_name}-spoke-tgw-rt"
    Role = "SpokeRouteDomain"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "prod_spoke" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

resource "aws_ec2_transit_gateway_route_table_association" "staging_spoke" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.staging.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

# Spoke Route: Only routes to Shared Services Hub (10.30.0.0/16)
# No route exists to other spoke VPCs (Strict Spoke-to-Spoke Isolation)
resource "aws_ec2_transit_gateway_route" "spoke_to_shared" {
  destination_cidr_block         = var.shared_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.shared.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

# ------------------------------------------------------------------------------
# TGW Route Tables: Hub Route Table (Shared Services)
# ------------------------------------------------------------------------------
resource "aws_ec2_transit_gateway_route_table" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id

  tags = {
    Name = "${var.project_name}-hub-tgw-rt"
    Role = "HubRouteDomain"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "shared_hub" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.shared.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

# Hub Routes: Can reach both Production and Staging Spokes
resource "aws_ec2_transit_gateway_route" "hub_to_prod" {
  destination_cidr_block         = var.prod_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route" "hub_to_staging" {
  destination_cidr_block         = var.staging_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.staging.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

# ==============================================================================
# 5. VPC Route Table Entries (Pointing to Transit Gateway)
# ==============================================================================
resource "aws_route" "prod_to_shared" {
  route_table_id         = aws_route_table.prod.id
  destination_cidr_block = var.shared_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
}

resource "aws_route" "staging_to_shared" {
  route_table_id         = aws_route_table.staging.id
  destination_cidr_block = var.shared_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
}

resource "aws_route" "shared_to_prod" {
  route_table_id         = aws_route_table.shared.id
  destination_cidr_block = var.prod_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
}

resource "aws_route" "shared_to_staging" {
  route_table_id         = aws_route_table.shared.id
  destination_cidr_block = var.staging_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
}
