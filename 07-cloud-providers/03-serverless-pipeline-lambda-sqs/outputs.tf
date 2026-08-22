# ==============================================================================
# Output Values for Event-Driven Serverless Pipeline
# ==============================================================================

output "primary_queue_url" {
  description = "URL of the primary SQS FIFO Queue receiving orders"
  value       = aws_sqs_queue.orders_primary.url
}

output "primary_queue_arn" {
  description = "ARN of the primary SQS FIFO Queue"
  value       = aws_sqs_queue.orders_primary.arn
}

output "primary_queue_name" {
  description = "Name of the primary SQS FIFO Queue"
  value       = aws_sqs_queue.orders_primary.name
}

output "dlq_url" {
  description = "URL of the Dead Letter Queue (DLQ) storing failed/poisoned messages"
  value       = aws_sqs_queue.orders_dlq.url
}

output "dlq_arn" {
  description = "ARN of the Dead Letter Queue (DLQ)"
  value       = aws_sqs_queue.orders_dlq.arn
}

output "dlq_name" {
  description = "Name of the Dead Letter Queue (DLQ)"
  value       = aws_sqs_queue.orders_dlq.name
}

output "lambda_function_name" {
  description = "Name of the Lambda order batch processing function"
  value       = aws_lambda_function.order_processor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda order batch processing function"
  value       = aws_lambda_function.order_processor.arn
}

output "event_source_mapping_id" {
  description = "Identifier of the SQS-to-Lambda event source mapping"
  value       = aws_lambda_event_source_mapping.sqs_trigger.id
}

output "dlq_alarm_arn" {
  description = "ARN of the CloudWatch alarm monitoring Dead Letter Queue messages"
  value       = aws_cloudwatch_metric_alarm.dlq_messages_visible.arn
}
