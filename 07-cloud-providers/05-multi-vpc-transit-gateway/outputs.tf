# ==============================================================================
# Output Values for Multi-VPC Networking with Transit Gateway
# ==============================================================================

output "prod_vpc_id" {
  description = "Identifier of the Production Spoke VPC"
  value       = aws_vpc.prod.id
}

output "prod_vpc_cidr" {
  description = "CIDR block of the Production Spoke VPC"
  value       = aws_vpc.prod.cidr_block
}

output "staging_vpc_id" {
  description = "Identifier of the Staging Spoke VPC"
  value       = aws_vpc.staging.id
}

output "staging_vpc_cidr" {
  description = "CIDR block of the Staging Spoke VPC"
  value       = aws_vpc.staging.cidr_block
}

output "shared_vpc_id" {
  description = "Identifier of the Shared Services Hub VPC"
  value       = aws_vpc.shared.id
}

output "shared_vpc_cidr" {
  description = "CIDR block of the Shared Services Hub VPC"
  value       = aws_vpc.shared.cidr_block
}

output "transit_gateway_id" {
  description = "Identifier of the Central AWS Transit Gateway"
  value       = aws_ec2_transit_gateway.tgw.id
}

output "transit_gateway_arn" {
  description = "ARN of the Central AWS Transit Gateway"
  value       = aws_ec2_transit_gateway.tgw.arn
}

output "spoke_route_table_id" {
  description = "ID of the TGW Spoke Route Table (Enforces Prod <-> Staging isolation)"
  value       = aws_ec2_transit_gateway_route_table.spoke.id
}

output "hub_route_table_id" {
  description = "ID of the TGW Hub Route Table (Allows Shared Services to reach all spokes)"
  value       = aws_ec2_transit_gateway_route_table.hub.id
}

output "network_topology_summary" {
  description = "Summary of the multi-VPC Hub-and-Spoke routing topology"
  value = {
    Hub_VPC           = "Shared Services (${var.shared_vpc_cidr})"
    Spoke_1_VPC       = "Production (${var.prod_vpc_cidr})"
    Spoke_2_VPC       = "Staging (${var.staging_vpc_cidr})"
    Prod_to_Shared    = "ALLOWED"
    Staging_to_Shared = "ALLOWED"
    Prod_to_Staging   = "BLOCKED (Isolated Spoke Domains)"
  }
}
