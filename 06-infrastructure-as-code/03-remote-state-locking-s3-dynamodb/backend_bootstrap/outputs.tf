# ==============================================================================
# Outputs for Backend Bootstrap Infrastructure
# ==============================================================================

output "s3_bucket_name" {
  value       = aws_s3_bucket.state.id
  description = "The globally unique name of the S3 bucket hosting Terraform state."
}

output "s3_bucket_arn" {
  value       = aws_s3_bucket.state.arn
  description = "The ARN of the S3 bucket hosting Terraform state."
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.locks.id
  description = "The name of the DynamoDB table used for distributed state locking."
}

output "dynamodb_table_arn" {
  value       = aws_dynamodb_table.locks.arn
  description = "The ARN of the DynamoDB table used for distributed state locking."
}

output "aws_region" {
  value       = var.aws_region
  description = "The AWS region where the backend infrastructure was provisioned."
}

output "backend_config_snippet" {
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "workloads/terraform.tfstate"
        region         = "${var.aws_region}"
        dynamodb_table = "${aws_dynamodb_table.locks.id}"
        encrypt        = true
      }
    }
  EOT
  description = "Sample backend configuration block to paste into consuming root modules."
}
