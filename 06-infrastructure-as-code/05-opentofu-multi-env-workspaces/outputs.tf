# ==============================================================================
# Outputs for Multi-Environment OpenTofu Workspaces
# ==============================================================================

output "workspace_name" {
  value       = terraform.workspace
  description = "Active OpenTofu workspace name."
}

output "environment" {
  value       = var.environment
  description = "Environment identifier configured via tfvars."
}

output "s3_storage_bucket_name" {
  value       = aws_s3_bucket.app_storage.id
  description = "Name of the workspace-specific S3 storage bucket."
}

output "s3_storage_bucket_arn" {
  value       = aws_s3_bucket.app_storage.arn
  description = "ARN of the workspace-specific S3 storage bucket."
}

output "security_group_id" {
  value       = aws_security_group.app_sg.id
  description = "ID of the workspace security group."
}

output "security_group_name" {
  value       = aws_security_group.app_sg.name
  description = "Name of the workspace security group."
}

output "cloudwatch_log_group" {
  value       = aws_cloudwatch_log_group.app_logs.name
  description = "CloudWatch log group path for this environment."
}

output "log_retention_days" {
  value       = aws_cloudwatch_log_group.app_logs.retention_in_days
  description = "Log retention period in days."
}

output "instance_count" {
  value       = var.instance_count
  description = "Number of compute instances allocated."
}

output "instance_type" {
  value       = var.instance_type
  description = "EC2 instance size assigned to this environment."
}

output "is_production" {
  value       = local.is_production
  description = "Boolean flag indicating if active workspace is production."
}

output "environment_summary" {
  value = {
    workspace           = terraform.workspace
    environment         = var.environment
    instance_count      = var.instance_count
    instance_type       = var.instance_type
    detailed_monitoring = var.enable_detailed_monitoring
    log_retention_days  = var.log_retention_days
    backup_retention    = var.backup_retention_days
    deletion_protection = var.enable_deletion_protection
  }
  description = "Summary manifest of environment specifications."
}
