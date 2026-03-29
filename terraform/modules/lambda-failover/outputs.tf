output "function_arn" { value = aws_lambda_function.failover.arn }
output "function_name" { value = aws_lambda_function.failover.function_name }
output "health_check_url" { value = aws_lambda_function_url.failover.function_url }
output "sns_topic_arn" { value = aws_sns_topic.failover_alerts.arn }
