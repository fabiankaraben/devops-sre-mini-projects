# ==============================================================================
# Dev Environment - outputs.tf
# ==============================================================================

output "vpc_id" {
  description = "The ID of the Dev VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "The CIDR block of the Dev VPC"
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the Dev public subnets"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the Dev private subnets"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of the Dev public subnets"
  value       = module.vpc.public_subnet_cidrs
}

output "private_subnet_cidrs" {
  description = "CIDR blocks of the Dev private subnets"
  value       = module.vpc.private_subnet_cidrs
}

output "nat_gateway_ips" {
  description = "Public IPs of the NAT Gateways in Dev"
  value       = module.vpc.nat_gateway_ips
}

output "igw_id" {
  description = "The ID of the Internet Gateway in Dev"
  value       = module.vpc.igw_id
}

output "availability_zones" {
  description = "Availability Zones used in Dev"
  value       = module.vpc.availability_zones
}
