# ==============================================================================
# VPC Module - outputs.tf
# ==============================================================================

output "vpc_id" {
  description = "The ID of the provisioned VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "The primary IPv4 CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "public_subnet_cidrs" {
  description = "List of IPv4 CIDR blocks of the public subnets"
  value       = aws_subnet.public[*].cidr_block
}

output "private_subnet_cidrs" {
  description = "List of IPv4 CIDR blocks of the private subnets"
  value       = aws_subnet.private[*].cidr_block
}

output "nat_gateway_ips" {
  description = "List of public Elastic IP addresses allocated for NAT Gateways"
  value       = aws_eip.nat[*].public_ip
}

output "igw_id" {
  description = "The ID of the Internet Gateway attached to the VPC"
  value       = aws_internet_gateway.this.id
}

output "availability_zones" {
  description = "List of Availability Zones utilized by the subnets"
  value       = var.availability_zones
}

output "default_security_group_id" {
  description = "The ID of the adopted and hardened default security group"
  value       = aws_default_security_group.default.id
}
