# ==============================================================================
# Outputs - Multi-Region Disaster Recovery with Route 53 Failover
# ==============================================================================

output "route53_fqdn" {
  description = "Fully Qualified Domain Name for the failover application"
  value       = "${var.subdomain}.${var.domain_name}"
}

output "route53_zone_id" {
  description = "Hosted Zone ID for the multi-region domain"
  value       = aws_route53_zone.primary_zone.zone_id
}

output "route53_health_check_id" {
  description = "Health Check ID monitoring the Primary region endpoint"
  value       = aws_route53_health_check.primary.id
}

output "primary_s3_bucket" {
  description = "Primary Region S3 Bucket Name (Replication Source)"
  value       = aws_s3_bucket.primary.id
}

output "secondary_s3_bucket" {
  description = "Secondary DR Region S3 Bucket Name (Replication Target)"
  value       = aws_s3_bucket.secondary.id
}

output "s3_replication_role_arn" {
  description = "IAM Role ARN performing S3 Cross-Region Replication"
  value       = aws_iam_role.replication.arn
}

output "architecture_summary" {
  description = "Architectural summary of multi-region active-passive topology"
  value = {
    primary_region          = var.primary_region
    secondary_region        = var.secondary_region
    routing_policy          = "ACTIVE-PASSIVE FAILOVER"
    health_check_interval_s = var.health_check_interval
    failure_threshold       = var.failure_threshold
    calculated_failover_rto = "${var.health_check_interval * var.failure_threshold + 10} seconds"
    s3_crr_enabled          = var.enable_s3_crr
  }
}
