data "aws_caller_identity" "current" {}

# Created by hand (see README), never by Terraform, so the token is not in any .tf/.tfvars.
data "aws_ssm_parameter" "github_pat" {
  name            = var.github_pat_parameter
  with_decryption = true
}

resource "random_password" "webhook_secret" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "webhook_secret" {
  name  = "/${var.name}/${var.github_repo}/webhook-secret"
  type  = "SecureString"
  tier  = "Standard"
  value = random_password.webhook_secret.result
}
