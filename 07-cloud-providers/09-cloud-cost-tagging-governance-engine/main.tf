# ==============================================================================
# Main Infrastructure - Cloud Cost Governance and Tag Compliance Engine
# ==============================================================================

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  name_prefix   = "${var.project_name}-${random_string.suffix.result}"
  audit_bucket  = "${local.name_prefix}-audit-logs"
  lambda_name   = "${local.name_prefix}-auditor"
  sns_topic     = "${local.name_prefix}-alerts"
  schedule_name = "${local.name_prefix}-daily-audit"
}

# ------------------------------------------------------------------------------
# 1. S3 Audit Log Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "audit_logs" {
  bucket        = local.audit_bucket
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket                  = aws_s3_bucket.audit_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# 2. Amazon SNS Alerts Topic
# ------------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = local.sns_topic
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ------------------------------------------------------------------------------
# 3. IAM Role & Policy for FinOps Lambda Auditor
# ------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "${local.name_prefix}-policy"
  description = "Least privilege permissions for Cloud Cost Governance and Tag Compliance"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Logging
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      # Resource Tag Querying & Management
      {
        Sid    = "ResourceGroupsTaggingAPI"
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "tag:GetTagKeys",
          "tag:GetTagValues",
          "tag:TagResources",
          "tag:UntagResources"
        ]
        Resource = "*"
      },
      # EC2 & EBS Read/Tag
      {
        Sid    = "EC2TagAuditing"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "ec2:DescribeTags",
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "*"
      },
      # S3 Tag Auditing
      {
        Sid    = "S3TagAuditing"
        Effect = "Allow"
        Action = [
          "s3:ListAllMyBuckets",
          "s3:GetBucketLocation",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging"
        ]
        Resource = "*"
      },
      # RDS Tag Auditing
      {
        Sid    = "RDSTagAuditing"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:DescribeDBClusters",
          "rds:ListTagsForResource",
          "rds:AddTagsToResource",
          "rds:RemoveTagsFromResource"
        ]
        Resource = "*"
      },
      # S3 Audit Archive Write
      {
        Sid    = "S3AuditLogsWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.audit_logs.arn}/*"
      },
      # SNS Alerts
      {
        Sid      = "SNSPublishAlerts"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# ------------------------------------------------------------------------------
# 4. Packaging & Deploying AWS Lambda Function
# ------------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/engine/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "auditor" {
  function_name    = local.lambda_name
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  timeout          = 180
  memory_size      = 256

  environment {
    variables = {
      MANDATORY_TAGS          = join(",", var.mandatory_tags)
      ALLOWED_ENVIRONMENTS    = join(",", var.allowed_environments)
      AUDIT_BUCKET_NAME       = aws_s3_bucket.audit_logs.id
      SNS_TOPIC_ARN           = aws_sns_topic.alerts.arn
      SLACK_WEBHOOK_URL       = var.slack_webhook_url
      GRACE_PERIOD_DAYS       = tostring(var.grace_period_days)
      ENABLE_AUTO_REMEDIATION = tostring(var.enable_auto_remediation)
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.auditor.function_name}"
  retention_in_days = 14
}

# ------------------------------------------------------------------------------
# 5. Amazon EventBridge Scheduled Daily Audit Rule
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "daily_schedule" {
  name                = local.schedule_name
  description         = "Daily scheduled trigger for FinOps Cloud Cost Governance Auditor"
  schedule_expression = var.compliance_schedule_cron
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_schedule.name
  target_id = "TriggerFinOpsAuditorLambda"
  arn       = aws_lambda_function.auditor.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auditor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_schedule.arn
}
