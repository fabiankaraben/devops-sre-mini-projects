# ==============================================================================
# outputs.tf - Output Values for App Module
# ==============================================================================

output "security_group_id" {
  description = "ID of the application security group"
  value       = aws_security_group.app.id
}

output "instance_ids" {
  description = "List of IDs of created EC2 instances"
  value       = aws_instance.app[*].id
}

output "instance_private_ips" {
  description = "List of private IP addresses of created instances"
  value       = aws_instance.app[*].private_ip
}

output "instance_type" {
  description = "The EC2 instance size deployed"
  value       = var.instance_type
}

output "instance_count" {
  description = "The number of application replicas deployed"
  value       = var.instance_count
}
