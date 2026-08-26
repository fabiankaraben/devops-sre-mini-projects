# ==============================================================================
# staging/us-east-1/app/terragrunt.hcl - Staging Application Blueprint
# ==============================================================================

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/app.hcl"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id            = "vpc-mock-111122223333"
    public_subnet_ids = ["subnet-mock-01", "subnet-mock-02"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name           = "staging-frontend"
  vpc_id         = dependency.vpc.outputs.vpc_id
  subnet_ids     = dependency.vpc.outputs.public_subnet_ids
  instance_type  = "t3.micro"
  instance_count = 1
  app_port       = 8080
}
