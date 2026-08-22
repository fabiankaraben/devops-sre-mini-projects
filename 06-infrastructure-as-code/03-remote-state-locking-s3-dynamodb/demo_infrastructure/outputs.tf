# ==============================================================================
# Outputs for Workload Infrastructure
# ==============================================================================

output "ssm_parameter_name" {
  value       = aws_ssm_parameter.app_version.name
  description = "The name of the SSM parameter provisioned."
}

output "ssm_parameter_value" {
  value       = aws_ssm_parameter.app_version.value
  description = "The value stored in the SSM parameter."
  sensitive   = true
}

output "app_bucket_name" {
  value       = aws_s3_bucket.app_data.id
  description = "The name of the application data S3 bucket."
}

output "remote_state_backend" {
  value       = "s3://${var.app_name}/${var.environment}"
  description = "Identifier of the remote state location."
}
