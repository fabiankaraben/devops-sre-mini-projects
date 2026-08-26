# ==============================================================================
# templates/web-app/outputs.tf - Exported Sandbox Attributes
# ==============================================================================

output "sandbox_id" {
  description = "Unique identifier of this sandbox"
  value       = var.sandbox_id
}

output "vpc_id" {
  description = "Provisioned VPC ID"
  value       = aws_vpc.sandbox_vpc.id
}

output "subnet_id" {
  description = "Provisioned Subnet ID"
  value       = aws_subnet.sandbox_subnet.id
}

output "security_group_id" {
  description = "Provisioned Security Group ID"
  value       = aws_security_group.sandbox_sg.id
}

output "s3_bucket_name" {
  description = "Provisioned S3 Bucket Name"
  value       = aws_s3_bucket.sandbox_bucket.id
}

output "endpoint_url" {
  description = "Simulated Web Application Access URL"
  value       = "http://${var.sandbox_id}.dev-sandbox.internal:8080"
}
