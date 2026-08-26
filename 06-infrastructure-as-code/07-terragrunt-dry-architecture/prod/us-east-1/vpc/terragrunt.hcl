# ==============================================================================
# prod/us-east-1/vpc/terragrunt.hcl - Production VPC Terragrunt Blueprint
# ==============================================================================

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/vpc.hcl"
}

inputs = {
  name            = "prod-us-east-1"
  cidr_block      = "10.20.0.0/16"
  public_subnets  = ["10.20.1.0/24", "10.20.2.0/24"]
  private_subnets = ["10.20.10.0/24", "10.20.20.0/24"]
  azs             = ["us-east-1a", "us-east-1b"]
}
