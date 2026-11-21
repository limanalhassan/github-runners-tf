output "webhook_url" {
  value = "${aws_apigatewayv2_stage.default.invoke_url}webhook"
}

output "asg_name" {
  value = aws_autoscaling_group.runners.name
}

output "runner_label" {
  description = "Put this in `runs-on:` for the jobs that should use these runners."
  value       = var.runner_label
}

output "subnets" {
  value = data.aws_subnets.runners.ids
}
