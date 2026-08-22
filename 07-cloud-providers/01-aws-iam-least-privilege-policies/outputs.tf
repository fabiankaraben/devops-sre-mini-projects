# ==============================================================================
# Output Values for AWS IAM Least-Privilege Infrastructure
# ==============================================================================

output "developer_role_arn" {
  description = "Amazon Resource Name (ARN) of the Developer IAM Role"
  value       = aws_iam_role.developer.arn
}

output "read_only_role_arn" {
  description = "Amazon Resource Name (ARN) of the Read-Only Auditor IAM Role"
  value       = aws_iam_role.read_only.arn
}

output "cicd_role_arn" {
  description = "Amazon Resource Name (ARN) of the CI/CD Pipeline IAM Role"
  value       = aws_iam_role.cicd.arn
}

output "developer_boundary_arn" {
  description = "ARN of the Developer Permissions Boundary"
  value       = aws_iam_policy.developer_boundary.arn
}

output "read_only_boundary_arn" {
  description = "ARN of the Read-Only Permissions Boundary"
  value       = aws_iam_policy.read_only_boundary.arn
}

output "cicd_boundary_arn" {
  description = "ARN of the CI/CD Permissions Boundary"
  value       = aws_iam_policy.cicd_boundary.arn
}

output "s3_dev_bucket" {
  description = "Name of the provisioned Development S3 Bucket"
  value       = aws_s3_bucket.dev.id
}

output "s3_prod_bucket" {
  description = "Name of the provisioned Production S3 Bucket"
  value       = aws_s3_bucket.prod.id
}

output "s3_artifacts_bucket" {
  description = "Name of the provisioned CI/CD Artifacts S3 Bucket"
  value       = aws_s3_bucket.artifacts.id
}

output "kms_cmk_arn" {
  description = "ARN of the Customer Managed KMS Key (CMK)"
  value       = aws_kms_key.demo.arn
}

output "kms_cmk_alias" {
  description = "Alias name of the Customer Managed KMS Key"
  value       = aws_kms_alias.demo.name
}
