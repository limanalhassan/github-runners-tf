resource "github_repository_webhook" "runners" {
  for_each = toset(var.github_repos)

  repository = each.value
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

# The single-repo webhook from the first version keeps its identity.
moved {
  from = github_repository_webhook.runners
  to   = github_repository_webhook.runners["devops-labs"]
}
