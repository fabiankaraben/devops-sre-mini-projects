# ==============================================================================
# Output Values for CloudWatch Alarms & SNS Incident Routing
# ==============================================================================

output "critical_incidents_topic_arn" {
  description = "ARN of the P1/P2 Critical Incident SNS Topic"
  value       = aws_sns_topic.critical_incidents.arn
}

output "critical_incidents_topic_name" {
  description = "Name of the P1/P2 Critical Incident SNS Topic"
  value       = aws_sns_topic.critical_incidents.name
}

output "warning_alerts_topic_arn" {
  description = "ARN of the P3/P4 Warning Alerts SNS Topic"
  value       = aws_sns_topic.warning_alerts.arn
}

output "warning_alerts_topic_name" {
  description = "Name of the P3/P4 Warning Alerts SNS Topic"
  value       = aws_sns_topic.warning_alerts.name
}

output "log_group_name" {
  description = "Name of the CloudWatch Log Group capturing application logs"
  value       = aws_cloudwatch_log_group.application_logs.name
}

output "metric_filter_name" {
  description = "Name of the CloudWatch Metric Filter parsing HTTP 5xx errors"
  value       = aws_cloudwatch_log_metric_filter.http_5xx_filter.name
}

output "high_cpu_alarm_name" {
  description = "Name of the High CPU Utilization Metric Alarm"
  value       = aws_cloudwatch_metric_alarm.high_cpu.alarm_name
}

output "high_5xx_alarm_name" {
  description = "Name of the High 5xx Error Rate Metric Alarm"
  value       = aws_cloudwatch_metric_alarm.high_5xx_rate.alarm_name
}

output "disk_space_alarm_name" {
  description = "Name of the Low Disk Space Metric Alarm"
  value       = aws_cloudwatch_metric_alarm.disk_space_low.alarm_name
}

output "composite_outage_alarm_name" {
  description = "Name of the Composite Outage CloudWatch Alarm"
  value       = aws_cloudwatch_composite_alarm.critical_outage.alarm_name
}

output "composite_alarm_rule" {
  description = "Boolean logic rule evaluated by the Composite CloudWatch Alarm"
  value       = aws_cloudwatch_composite_alarm.critical_outage.alarm_rule
}
