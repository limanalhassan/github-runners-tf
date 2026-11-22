data "archive_file" "scaler" {
  type        = "zip"
  source_file = "${path.module}/lambda/scaler.py"
  output_path = "${path.module}/.build/scaler.zip"
}

resource "aws_cloudwatch_log_group" "scaler" {
  name              = "/aws/lambda/${var.name}-scaler"
  retention_in_days = 7
}

resource "aws_lambda_function" "scaler" {
  function_name    = "${var.name}-scaler"
  role             = aws_iam_role.scaler.arn
  runtime          = "python3.13"
  handler          = "scaler.handler"
  filename         = data.archive_file.scaler.output_path
  source_code_hash = data.archive_file.scaler.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      GITHUB_REPOS             = join(",", [for r in var.github_repos : "${var.github_owner}/${r}"])
      RUNNER_LABEL             = var.runner_label
      ASG_NAME                 = aws_autoscaling_group.runners.name
      PAT_PARAMETER            = var.github_pat_parameter
      WEBHOOK_SECRET_PARAMETER = aws_ssm_parameter.webhook_secret.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.scaler, aws_iam_role_policy.scaler]
}

# ---------- Webhook endpoint (API Gateway HTTP API) ----------

resource "aws_apigatewayv2_api" "webhook" {
  name          = "${var.name}-webhook"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "scaler" {
  api_id                 = aws_apigatewayv2_api.webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.scaler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "webhook" {
  api_id    = aws_apigatewayv2_api.webhook.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.scaler.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.webhook.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*/webhook"
}

# ---------- Backstop schedule ----------

resource "aws_cloudwatch_event_rule" "reconcile" {
  name                = "${var.name}-reconcile"
  schedule_expression = "rate(${var.reconcile_interval_minutes} minutes)"
}

resource "aws_cloudwatch_event_target" "reconcile" {
  rule  = aws_cloudwatch_event_rule.reconcile.name
  arn   = aws_lambda_function.scaler.arn
  input = jsonencode({ reconcile = true })
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reconcile.arn
}
