<!-- markdownlint-disable MD013 MD033 -->
# Reusable Modular AWS VPC Module

> Reusable Terraform & OpenTofu module provisioning a multi-tier, High-Availability AWS VPC across 2 or 3 Availability Zones.

---

## Architecture Overview

```text
               Internet Gateway (0.0.0.0/0)
                           │
       ┌───────────────────┼───────────────────┐
       ▼                   ▼                   ▼
Public Subnet 1     Public Subnet 2     Public Subnet 3
(10.0.1.0/24)       (10.0.2.0/24)       (10.0.3.0/24)
 [NAT Gateway 1]     [NAT Gateway 2]     [NAT Gateway 3]
       │                   │                   │
       ▼                   ▼                   ▼
Private Subnet 1    Private Subnet 2    Private Subnet 3
(10.0.11.0/24)      (10.0.12.0/24)      (10.0.13.0/24)
```

---

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_default_security_group.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_availability_zones"></a> [availability\_zones](#input\_availability\_zones) | List of Availability Zones to deploy subnets into | `list(string)` | <pre>[<br/>  "us-east-1a",<br/>  "us-east-1b",<br/>  "us-east-1c"<br/>]</pre> | no |
| <a name="input_enable_nat_gateway"></a> [enable\_nat\_gateway](#input\_enable\_nat\_gateway) | Whether to provision NAT Gateways for private subnet outbound internet access | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Target deployment environment (e.g. dev, staging, prod) | `string` | `"dev"` | no |
| <a name="input_private_subnet_cidrs"></a> [private\_subnet\_cidrs](#input\_private\_subnet\_cidrs) | List of CIDR blocks for private subnets (must match length of availability\_zones) | `list(string)` | <pre>[<br/>  "10.0.11.0/24",<br/>  "10.0.12.0/24",<br/>  "10.0.13.0/24"<br/>]</pre> | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project or workload name for resource naming and tagging | `string` | `"modular-aws-vpc"` | no |
| <a name="input_public_subnet_cidrs"></a> [public\_subnet\_cidrs](#input\_public\_subnet\_cidrs) | List of CIDR blocks for public subnets (must match length of availability\_zones) | `list(string)` | <pre>[<br/>  "10.0.1.0/24",<br/>  "10.0.2.0/24",<br/>  "10.0.3.0/24"<br/>]</pre> | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | Whether to provision a single shared NAT Gateway across all AZs (cost-effective for Dev) or one per AZ (High Availability for Prod) | `bool` | `false` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags to merge into all provisioned AWS resources | `map(string)` | `{}` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | The IPv4 CIDR block for the VPC | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_availability_zones"></a> [availability\_zones](#output\_availability\_zones) | List of Availability Zones utilized by the subnets |
| <a name="output_default_security_group_id"></a> [default\_security\_group\_id](#output\_default\_security\_group\_id) | The ID of the adopted and hardened default security group |
| <a name="output_igw_id"></a> [igw\_id](#output\_igw\_id) | The ID of the Internet Gateway attached to the VPC |
| <a name="output_nat_gateway_ips"></a> [nat\_gateway\_ips](#output\_nat\_gateway\_ips) | List of public Elastic IP addresses allocated for NAT Gateways |
| <a name="output_private_subnet_cidrs"></a> [private\_subnet\_cidrs](#output\_private\_subnet\_cidrs) | List of IPv4 CIDR blocks of the private subnets |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | List of IDs of the private subnets |
| <a name="output_public_subnet_cidrs"></a> [public\_subnet\_cidrs](#output\_public\_subnet\_cidrs) | List of IPv4 CIDR blocks of the public subnets |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | List of IDs of the public subnets |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | The primary IPv4 CIDR block of the VPC |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | The ID of the provisioned VPC |
