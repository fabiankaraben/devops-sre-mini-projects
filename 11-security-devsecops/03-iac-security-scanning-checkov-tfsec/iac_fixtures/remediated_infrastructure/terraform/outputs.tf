output "s3_bucket_arn" {
  description = "ARN of the secure S3 bucket"
  value       = aws_s3_bucket.secure_customer_data.arn
}

output "security_group_id" {
  description = "ID of the hardened Security Group"
  value       = aws_security_group.hardened_app_sg.id
}

output "kms_key_arn" {
  description = "ARN of the customer managed KMS key"
  value       = aws_kms_key.infrastructure_key.arn
}
