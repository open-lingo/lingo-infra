# Cost circuit breaker — trips on the flood alarms / budget backstop and
# stops all billing-capable traffic until a human restores it. Spencer's call
# 2026-08-26: breaking the app is acceptable; an unbounded bill is not.
#
# Created OUTSIDE tf via CLI on 2026-08-26 (import or leave; they're stable):
#   - SNS topics  arn:aws:sns:{us-west-1,us-east-1}:349654078389:lingo-cost-alarms
#     (email subs: spencer@lichfieldfamily.com, sortaminty@gmail.com)
#   - CloudWatch alarms: lingo-core-invocation-flood (>=6k invocations/min x3),
#     lingo-core-throttle-flood (>=1k throttles/min x3), both us-west-1;
#     lingo-app-cdn-request-flood (>=150k req/5min) us-east-1
#   - Budget "lingo-monthly-guardrail" 200% ($50) SNS notification -> us-east-1 topic
#
# This file adds the part that NEEDS IAM (PowerUser can't create roles):
# the breaker Lambda, its role, and the SNS -> Lambda wiring. After apply,
# the alarms stop being email-only and actually pull the plug.
#
# Restore after a trip (from the snapshot the breaker writes to SSM):
#   aws lambda invoke --function-name lingo-cost-breaker \
#     --payload '{"action": "restore"}' \
#     --cli-binary-format raw-in-base64-out /tmp/out.json

locals {
  cost_alarm_topic_usw1 = "arn:aws:sns:us-west-1:349654078389:lingo-cost-alarms"
  cost_alarm_topic_use1 = "arn:aws:sns:us-east-1:349654078389:lingo-cost-alarms"
  # app.openlingoapp.com distro — not tf-managed (known drift), so by id.
  app_distribution_id = "E1BFOGAPA9DNMV"
}

data "archive_file" "cost_breaker_zip" {
  type        = "zip"
  source_file = "${path.module}/breaker/handler.py"
  output_path = "${path.module}/breaker/handler.zip"
}

resource "aws_iam_role" "cost_breaker_lambda" {
  name = "lingo-cost-breaker-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cost_breaker_lambda" {
  name = "cost-breaker-actions"
  role = aws_iam_role.cost_breaker_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "ThrottleFunctions"
        Effect = "Allow"
        Action = [
          "lambda:GetFunctionConcurrency",
          "lambda:PutFunctionConcurrency",
          "lambda:DeleteFunctionConcurrency",
        ]
        Resource = [
          aws_lambda_function.lingo_core.arn,
          aws_lambda_function.lingo_ops.arn,
        ]
      },
      {
        Sid    = "DisableDistribution"
        Effect = "Allow"
        Action = [
          "cloudfront:GetDistributionConfig",
          "cloudfront:UpdateDistribution",
        ]
        Resource = "arn:aws:cloudfront::349654078389:distribution/${local.app_distribution_id}"
      },
      {
        Sid      = "Page"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = [local.cost_alarm_topic_usw1, local.cost_alarm_topic_use1]
      },
      {
        Sid    = "Snapshot"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
        ]
        Resource = "arn:aws:ssm:us-west-1:349654078389:parameter/lingo/breaker/*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-west-1:349654078389:*"
      },
    ]
  })
}

resource "aws_lambda_function" "cost_breaker" {
  function_name = "lingo-cost-breaker"
  role          = aws_iam_role.cost_breaker_lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.13"
  architectures = ["arm64"]
  memory_size   = 128
  timeout       = 60

  filename         = data.archive_file.cost_breaker_zip.output_path
  source_code_hash = data.archive_file.cost_breaker_zip.output_base64sha256

  # The breaker must never be part of the problem: cap it hard.
  reserved_concurrent_executions = 1

  environment {
    variables = {
      BREAKER_REGION  = "us-west-1"
      FUNCTIONS       = "lingo-core,lingo-ops"
      DISTRIBUTION_ID = local.app_distribution_id
      ALERT_TOPIC_ARN = local.cost_alarm_topic_usw1
      STATE_PARAM     = "/lingo/breaker/prior-state"
    }
  }
}

resource "aws_lambda_permission" "cost_breaker_from_usw1_topic" {
  statement_id  = "AllowSNSUsWest1"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_breaker.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = local.cost_alarm_topic_usw1
}

resource "aws_lambda_permission" "cost_breaker_from_use1_topic" {
  statement_id  = "AllowSNSUsEast1"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_breaker.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = local.cost_alarm_topic_use1
}

resource "aws_sns_topic_subscription" "cost_breaker_usw1" {
  topic_arn = local.cost_alarm_topic_usw1
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_breaker.arn
}

# SNS supports cross-region delivery to Lambda; the subscription lives in the
# topic's region, hence the aliased provider.
resource "aws_sns_topic_subscription" "cost_breaker_use1" {
  provider  = aws.us_east_1
  topic_arn = local.cost_alarm_topic_use1
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_breaker.arn
}
