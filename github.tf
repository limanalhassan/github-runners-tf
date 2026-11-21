resource "github_repository_webhook" "runners" {
  repository = var.github_repo
  events     = ["workflow_job"]
  active     = true

  configuration {
    url          = "${aws_apigatewayv2_stage.default.invoke_url}webhook"
    content_type = "json"
    secret       = random_password.webhook_secret.result
    insecure_ssl = false
  }

  # GitHub pings the URL the moment the hook is created; the route and the Lambda
  # permission must already be live or the ping 404s.
  depends_on = [aws_apigatewayv2_route.webhook, aws_lambda_permission.apigw]
}
