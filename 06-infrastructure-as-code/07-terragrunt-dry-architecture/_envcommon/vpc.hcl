# ==============================================================================
# _envcommon/vpc.hcl - Canonical Terragrunt Base Configuration for VPC Module
# ==============================================================================

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/vpc"
}
