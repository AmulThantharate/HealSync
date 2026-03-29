resource "aws_iam_role" "lambda" {
  name = "healsync-lambda-failover-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow"; Action = "sts:AssumeRole"; Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy" "lambda" {
  name = "healsync-lambda-failover-policy"; role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow"; Action = ["ec2:CreateNetworkInterface","ec2:DescribeNetworkInterfaces","ec2:DeleteNetworkInterface"]; Resource = "*" },
      { Effect = "Allow"; Action = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"]; Resource = "arn:aws:logs:*:*:*" },
      { Effect = "Allow"; Action = ["route53:ChangeResourceRecordSets","route53:ListResourceRecordSets"]; Resource = "*" },
      { Effect = "Allow"; Action = ["rds:DescribeDBInstances","rds:RebootDBInstance"]; Resource = "*" },
      { Effect = "Allow"; Action = ["eks:DescribeCluster"]; Resource = "*" },
      { Effect = "Allow"; Action = ["ssm:GetParameter","ssm:GetParameters","ssm:PutParameter"]; Resource = "arn:aws:ssm:*:*:parameter/dr/*" },
      { Effect = "Allow"; Action = ["sns:Publish"]; Resource = aws_sns_topic.failover_alerts.arn },
      { Effect = "Allow"; Action = ["cloudwatch:GetMetricStatistics","cloudwatch:DescribeAlarms"]; Resource = "*" }
    ]
  })
}
resource "aws_security_group" "lambda" {
  name   = "healsync-lambda-sg-${var.environment}"; vpc_id = var.vpc_id
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags   = { Name = "healsync-lambda-sg" }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../../lambda"
  output_path = "${path.module}/lambda_failover.zip"
}

resource "aws_lambda_function" "failover" {
  function_name    = "healsync-failover-${var.environment}"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  role             = aws_iam_role.lambda.arn
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment {
    variables = {
      ENVIRONMENT      = var.environment
      AWS_REGION_NAME  = var.aws_region
      EKS_CLUSTER      = var.eks_cluster_name
      RDS_IDENTIFIER   = var.rds_identifier
      ROUTE53_ZONE_ID  = var.route53_zone_id
      APP_DOMAIN       = var.app_domain
      FAILOVER_CNAME_TARGET = var.failover_cname_target
      EKS_ENDPOINT     = var.eks_endpoint
      SNS_TOPIC_ARN    = aws_sns_topic.failover_alerts.arn
    }
  }
  dead_letter_config { target_arn = aws_sqs_queue.dlq.arn }
  tags = { Name = "healsync-failover-lambda" }
}

resource "aws_cloudwatch_event_rule" "health_check" {
  name                = "healsync-health-check-${var.environment}"
  description         = "HealSync health check every 1 minute"
  schedule_expression = "rate(1 minute)"
}
resource "aws_cloudwatch_event_target" "health_check" {
  rule      = aws_cloudwatch_event_rule.health_check.name
  target_id = "DrHealthCheck"
  arn       = aws_lambda_function.failover.arn
  input     = jsonencode({ action = "health_check" })
}
resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_check.arn
}
resource "aws_lambda_function_url" "failover" {
  function_name      = aws_lambda_function.failover.function_name
  authorization_type = "AWS_IAM"
}
resource "aws_sns_topic" "failover_alerts" {
  name              = "healsync-failover-alerts-${var.environment}"
  kms_master_key_id = "alias/aws/sns"
}
resource "aws_sqs_queue" "dlq" {
  name                      = "healsync-lambda-dlq-${var.environment}"
  message_retention_seconds = 86400
}
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/healsync-failover-${var.environment}"
  retention_in_days = 30
}
