# ==============================================================================
# templates/microservice/outputs.tf - Outputs
# ==============================================================================

output "sandbox_id" {
  value = var.sandbox_id
}

output "vpc_id" {
  value = aws_vpc.ms_vpc.id
}

output "security_group_id" {
  value = aws_security_group.ms_sg.id
}

output "s3_bucket_name" {
  value = aws_s3_bucket.data_bucket.id
}

output "endpoint_url" {
  value = "http://${var.sandbox_id}.microservice.internal:8000"
}
