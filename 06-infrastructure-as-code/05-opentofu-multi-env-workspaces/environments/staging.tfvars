# ==============================================================================
# Staging Environment (staging.tfvars)
# ==============================================================================
# Pre-production environment for QA, integration testing, and load validation.
# ==============================================================================

environment                = "staging"
app_name                   = "cloud-app"
instance_count             = 2
instance_type              = "t3.small"
enable_detailed_monitoring = true
log_retention_days         = 14
backup_retention_days      = 7
enable_deletion_protection = false

extra_tags = {
  CostCenter = "QA-Staging"
  AutoStop   = "false"
}
