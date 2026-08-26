# ==============================================================================
# _envcommon/app.hcl - Canonical Terragrunt Base Configuration for App Module
# ==============================================================================

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/app"
}
