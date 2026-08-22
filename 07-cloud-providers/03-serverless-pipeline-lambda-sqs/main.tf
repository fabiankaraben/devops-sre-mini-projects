# ==============================================================================
# Event-Driven Serverless Pipeline: Lambda + SQS FIFO + DLQ
# ==============================================================================

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.aws_endpoint != "" ? true : false
  skip_metadata_api_check     = var.aws_endpoint != "" ? true : false
  skip_requesting_account_id  = false

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [1] : []
    content {
      sqs        = var.aws_endpoint
      lambda     = var.aws_endpoint
      iam        = var.aws_endpoint
      sts        = var.aws_endpoint
      cloudwatch = var.aws_endpoint
      logs       = var.aws_endpoint
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
  primary_queue_name = "${var.project_name}-orders-${random_string.suffix.result}.fifo"
  dlq_queue_name     = "${var.project_name}-dlq-${random_string.suffix.result}.fifo"
  lambda_name        = "${var.project_name}-processor-${random_string.suffix.result}"
}

# ------------------------------------------------------------------------------
# 2. Dead Letter Queue (DLQ) for Poison Pill & Failed Messages
# ------------------------------------------------------------------------------
resource "aws_sqs_queue" "orders_dlq" {
  name                        = local.dlq_queue_name
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600 # 14 days retention for inspection and replay

  tags = {
    Name     = local.dlq_queue_name
    Role     = "DeadLetterQueue"
    Pipeline = "OrderProcessing"
  }
}

# ------------------------------------------------------------------------------
# 3. Primary SQS FIFO Queue with Redrive Policy
# ------------------------------------------------------------------------------
resource "aws_sqs_queue" "orders_primary" {
  name                        = local.primary_queue_name
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = var.sqs_visibility_timeout_seconds
  message_retention_seconds   = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = var.dlq_max_receive_count
  })

  tags = {
    Name     = local.primary_queue_name
    Role     = "PrimaryQueue"
    Pipeline = "OrderProcessing"
  }
}

# ------------------------------------------------------------------------------
# 4. Package Lambda Handler Code into Zip Archive
# ------------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.tmp_lambda_payload.zip"
}

# ------------------------------------------------------------------------------
# 5. IAM Role and Least-Privilege Execution Policies for Lambda
# ------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaServiceAssume"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_sqs_and_logs" {
  name        = "${var.project_name}-lambda-policy-${random_string.suffix.result}"
  description = "Least privilege permissions for Lambda to process SQS FIFO queue and write CloudWatch logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchLogging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "AllowPrimarySQSProcessing"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.orders_primary.arn
      },
      {
        Sid    = "AllowDLQInspectionAndWrite"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.orders_dlq.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_sqs_and_logs.arn
}

# ------------------------------------------------------------------------------
# 6. AWS Lambda Function: Order Batch Processor
# ------------------------------------------------------------------------------
resource "aws_lambda_function" "order_processor" {
  function_name    = local.lambda_name
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb
  role             = aws_iam_role.lambda_exec.arn

  environment {
    variables = {
      ENVIRONMENT = var.environment
      LOG_LEVEL   = "INFO"
      DLQ_URL     = aws_sqs_queue.orders_dlq.url
    }
  }

  tags = {
    Name     = local.lambda_name
    Role     = "BatchProcessor"
    Pipeline = "OrderProcessing"
  }
}

# ------------------------------------------------------------------------------
# 7. SQS to Lambda Event Source Mapping (ReportBatchItemFailures)
# ------------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = aws_sqs_queue.orders_primary.arn
  function_name                      = aws_lambda_function.order_processor.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = var.batch_window_seconds
  enabled                            = true

  # Enables granular partial batch failures without reprocessing valid items
  function_response_types = ["ReportBatchItemFailures"]
}

# ------------------------------------------------------------------------------
# 8. CloudWatch Alarms: DLQ Message Detection & Lambda Error Rate
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dlq_messages_visible" {
  alarm_name          = "${var.project_name}-dlq-alarm-${random_string.suffix.result}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggered when poisoned or unprocessable messages enter the Dead Letter Queue (DLQ)."

  dimensions = {
    QueueName = aws_sqs_queue.orders_dlq.name
  }

  tags = {
    Severity = "High"
    Pipeline = "OrderProcessing"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors-${random_string.suffix.result}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Triggered when Lambda execution encounters fatal unhandled exceptions."

  dimensions = {
    FunctionName = aws_lambda_function.order_processor.function_name
  }

  tags = {
    Severity = "Medium"
    Pipeline = "OrderProcessing"
  }
}
