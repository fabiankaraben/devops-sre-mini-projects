# ==============================================================================
# CloudWatch Alarms, Metric Filters & SNS Incident Routing
# ==============================================================================

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.aws_endpoint != "" ? true : false
  skip_metadata_api_check     = var.aws_endpoint != "" ? true : false
  skip_requesting_account_id  = false

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [1] : []
    content {
      cloudwatch = var.aws_endpoint
      logs       = var.aws_endpoint
      sns        = var.aws_endpoint
      iam        = var.aws_endpoint
      sts        = var.aws_endpoint
    }
  }

  default_tags {
    tags = var.tags
  }
}

# ------------------------------------------------------------------------------
# 1. Random Suffix for Global Resource Uniqueness
# ------------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  critical_topic_name  = "${var.project_name}-critical-incidents-${random_string.suffix.result}"
  warning_topic_name   = "${var.project_name}-warnings-${random_string.suffix.result}"
  log_group_name       = "/aws/application/${var.project_name}-api-${random_string.suffix.result}"
  composite_alarm_name = "${var.project_name}-composite-outage-${random_string.suffix.result}"
  cpu_alarm_name       = "${var.project_name}-high-cpu-${random_string.suffix.result}"
  error_5xx_alarm_name = "${var.project_name}-high-5xx-${random_string.suffix.result}"
  disk_alarm_name      = "${var.project_name}-disk-space-${random_string.suffix.result}"
}

# ------------------------------------------------------------------------------
# 2. Amazon SNS Topics: Critical (P1/P2) & Warnings (P3/P4)
# ------------------------------------------------------------------------------
resource "aws_sns_topic" "critical_incidents" {
  name         = local.critical_topic_name
  display_name = "P1/P2 Critical Incident Dispatcher"

  tags = {
    Severity = "Critical"
    Tier     = "P1-P2"
  }
}

resource "aws_sns_topic" "warning_alerts" {
  name         = local.warning_topic_name
  display_name = "P3/P4 Warning Alerts Dispatcher"

  tags = {
    Severity = "Warning"
    Tier     = "P3-P4"
  }
}

# ------------------------------------------------------------------------------
# 3. SNS Topic Policies (Permit CloudWatch Service to Publish Alarms)
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "sns_cloudwatch_publish" {
  statement {
    sid    = "AllowCloudWatchAlarmsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions = ["sns:Publish"]

    resources = [
      aws_sns_topic.critical_incidents.arn,
      aws_sns_topic.warning_alerts.arn
    ]
  }
}

resource "aws_sns_topic_policy" "critical_topic_policy" {
  arn    = aws_sns_topic.critical_incidents.arn
  policy = data.aws_iam_policy_document.sns_cloudwatch_publish.json
}

resource "aws_sns_topic_policy" "warning_topic_policy" {
  arn    = aws_sns_topic.warning_alerts.arn
  policy = data.aws_iam_policy_document.sns_cloudwatch_publish.json
}

# ------------------------------------------------------------------------------
# 4. Optional Subscriptions: Webhook and Email
# ------------------------------------------------------------------------------
resource "aws_sns_topic_subscription" "webhook_critical_subscription" {
  count                  = var.webhook_endpoint_url != "" ? 1 : 0
  topic_arn              = aws_sns_topic.critical_incidents.arn
  protocol               = startswith(var.webhook_endpoint_url, "https") ? "https" : "http"
  endpoint               = var.webhook_endpoint_url
  endpoint_auto_confirms = true
}

resource "aws_sns_topic_subscription" "webhook_warning_subscription" {
  count                  = var.webhook_endpoint_url != "" ? 1 : 0
  topic_arn              = aws_sns_topic.warning_alerts.arn
  protocol               = startswith(var.webhook_endpoint_url, "https") ? "https" : "http"
  endpoint               = var.webhook_endpoint_url
  endpoint_auto_confirms = true
}

resource "aws_sns_topic_subscription" "email_critical_subscription" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.critical_incidents.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ------------------------------------------------------------------------------
# 5. CloudWatch Log Group & Metric Filter for Application 5xx Errors
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "application_logs" {
  name              = local.log_group_name
  retention_in_days = 7

  tags = {
    Application = "ProductionAPI"
  }
}

resource "aws_cloudwatch_log_metric_filter" "http_5xx_filter" {
  name           = "HTTP5xxErrorMetricFilter"
  pattern        = "{ $.status >= 500 }"
  log_group_name = aws_cloudwatch_log_group.application_logs.name

  metric_transformation {
    name          = "5xxErrorCount"
    namespace     = "CustomApp/Production"
    value         = "1"
    default_value = 0
    unit          = "Count"
  }
}

# ------------------------------------------------------------------------------
# 6. Individual Metric Alarms
# ------------------------------------------------------------------------------
# Alarm 1: High CPU Utilization
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = local.cpu_alarm_name
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_utilization_threshold
  alarm_description   = "Triggered when average EC2 CPU utilization exceeds ${var.cpu_utilization_threshold}% for 2 consecutive minutes."
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = "production-app-asg"
  }

  alarm_actions = [aws_sns_topic.warning_alerts.arn]
  ok_actions    = [aws_sns_topic.warning_alerts.arn]
}

# Alarm 2: HTTP 5xx Error Rate Spike
resource "aws_cloudwatch_metric_alarm" "high_5xx_rate" {
  alarm_name          = local.error_5xx_alarm_name
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5xxErrorCount"
  namespace           = "CustomApp/Production"
  period              = 60
  statistic           = "Sum"
  threshold           = var.error_5xx_rate_threshold
  alarm_description   = "Triggered when HTTP 5xx error occurrences exceed ${var.error_5xx_rate_threshold} within a 1-minute window."
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.warning_alerts.arn]
  ok_actions    = [aws_sns_topic.warning_alerts.arn]
}

# Alarm 3: Disk Space Low
resource "aws_cloudwatch_metric_alarm" "disk_space_low" {
  alarm_name          = local.disk_alarm_name
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DiskSpaceUtilization"
  namespace           = "System/Linux"
  period              = 60
  statistic           = "Average"
  threshold           = var.disk_space_utilization_threshold
  alarm_description   = "Triggered when disk space utilization exceeds ${var.disk_space_utilization_threshold}%."
  treat_missing_data  = "notBreaching"

  dimensions = {
    Filesystem = "/dev/xvda1"
    MountPath  = "/"
  }

  alarm_actions = [aws_sns_topic.warning_alerts.arn]
  ok_actions    = [aws_sns_topic.warning_alerts.arn]
}

# ------------------------------------------------------------------------------
# 7. Composite CloudWatch Alarm: Critical Infrastructure Outage
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_composite_alarm" "critical_outage" {
  alarm_name        = local.composite_alarm_name
  alarm_description = "CRITICAL P1 OUTAGE: High CPU utilization correlated with high HTTP 5xx error responses. Runbook: https://runbooks.internal/incident-p1-outage"

  # Boolean composite alarm rule evaluating two underlying metric alarms
  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.high_cpu.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.high_5xx_rate.alarm_name})"

  alarm_actions = [aws_sns_topic.critical_incidents.arn]
  ok_actions    = [aws_sns_topic.critical_incidents.arn]

  tags = {
    Severity = "Critical"
    Tier     = "P1"
  }
}
