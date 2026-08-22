# ==============================================================================
# Development Environment (dev.tfvars)
# ==============================================================================
# Cost-optimized, single replica, minimal retention for rapid developer iteration.
# ==============================================================================

environment                = "dev"
app_name                   = "cloud-app"
instance_count             = 1
instance_type              = "t3.micro"
enable_detailed_monitoring = false
log_retention_days         = 3
backup_retention_days      = 0
enable_deletion_protection = false

extra_tags = {
  CostCenter = "Engineering-Dev"
  AutoStop   = "true"
}
