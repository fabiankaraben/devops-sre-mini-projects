# ==============================================================================
# Outputs - Cloud Cost Governance and Tag Compliance Engine
# ==============================================================================

output "lambda_function_name" {
  description = "Name of the FinOps Tag Compliance Auditor Lambda function"
  value       = aws_lambda_function.auditor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the FinOps Tag Compliance Auditor Lambda function"
  value       = aws_lambda_function.auditor.arn
}

output "audit_s3_bucket" {
  description = "S3 Bucket storing JSON and HTML compliance audit logs"
  value       = aws_s3_bucket.audit_logs.id
}

output "sns_alerts_topic_arn" {
  description = "ARN of the SNS topic for FinOps non-compliance notifications"
  value       = aws_sns_topic.alerts.arn
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule scheduling daily tag audits"
  value       = aws_cloudwatch_event_rule.daily_schedule.name
}

output "architecture_summary" {
  description = "Summary of configured FinOps governance parameters"
  value = {
    mandatory_tags          = var.mandatory_tags
    allowed_environments    = var.allowed_environments
    grace_period_days       = var.grace_period_days
    enable_auto_remediation = var.enable_auto_remediation
    cron_schedule           = var.compliance_schedule_cron
  }
}
