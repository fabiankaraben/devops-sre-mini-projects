# ==============================================================================
# Production Environment (prod.tfvars)
# ==============================================================================
# High-availability, scaled compute, strict backup retention, deletion protection.
# ==============================================================================

environment                = "prod"
app_name                   = "cloud-app"
instance_count             = 4
instance_type              = "t3.large"
enable_detailed_monitoring = true
log_retention_days         = 90
backup_retention_days      = 30
enable_deletion_protection = true

extra_tags = {
  CostCenter  = "Production-Core"
  Compliance  = "SOC2-HIPAA"
  Criticality = "Tier-1"
}
