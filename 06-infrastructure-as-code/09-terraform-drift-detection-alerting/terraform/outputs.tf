# ==============================================================================
# terraform/outputs.tf - Stack Outputs for Verification
# ==============================================================================

output "vpc_id" {
  description = "The ID of the provisioned VPC"
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "The ID of the provisioned public subnet"
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "The ID of the firewall security group"
  value       = aws_security_group.web_sg.id
}

output "s3_bucket_id" {
  description = "The name/ID of the S3 storage bucket"
  value       = aws_s3_bucket.storage.id
}

output "s3_bucket_arn" {
  description = "The ARN of the S3 storage bucket"
  value       = aws_s3_bucket.storage.arn
}
