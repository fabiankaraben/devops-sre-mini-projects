# ==============================================================================
# Output Values for High-Availability Auto Scaling EC2 Fleet behind ALB
# ==============================================================================

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer (Access URL for application)"
  value       = "http://${aws_lb.app.dns_name}"
}

output "alb_arn" {
  description = "Amazon Resource Name (ARN) of the Application Load Balancer"
  value       = aws_lb.app.arn
}

output "target_group_arn" {
  description = "Amazon Resource Name (ARN) of the ALB Target Group"
  value       = aws_lb_target_group.app.arn
}

output "asg_name" {
  description = "Identifier of the Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "asg_arn" {
  description = "Amazon Resource Name (ARN) of the Auto Scaling Group"
  value       = aws_autoscaling_group.app.arn
}

output "vpc_id" {
  description = "Identifier of the dedicated Virtual Private Cloud"
  value       = aws_vpc.main.id
}

output "public_subnets" {
  description = "Identifiers of the multi-AZ public subnets"
  value       = aws_subnet.public[*].id
}

output "alb_security_group_id" {
  description = "Security Group ID protecting the Application Load Balancer"
  value       = aws_security_group.alb.id
}

output "ec2_security_group_id" {
  description = "Security Group ID protecting the EC2 instances (chained to ALB SG)"
  value       = aws_security_group.ec2.id
}

output "fleet_summary" {
  description = "High-level summary of the Auto Scaling and Load Balancing topology"
  value = {
    alb_endpoint       = "http://${aws_lb.app.dns_name}"
    health_check_path  = "/health"
    asg_min_size       = var.asg_min_size
    asg_desired_size   = var.asg_desired_capacity
    asg_max_size       = var.asg_max_size
    scaling_policy     = "TargetTracking (Average CPU: ${var.target_cpu_utilization}%)"
    availability_zones = slice(data.aws_availability_zones.available.names, 0, length(var.public_subnet_cidrs))
    health_check_type  = "ELB (Automatic unhealthy instance termination)"
  }
}
