resource "aws_budgets_budget" "runners" {
  count = var.budget_email == null ? 0 : 1

  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_monthly_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits cover the bill, so the default (net of credits) would sit at $0 and never alert.
  # Track gross usage instead.
  cost_types {
    include_credit = false
    include_refund = false
  }

  cost_filter {
    name = "TagKeyValue"
    # Needs "Project" activated as a cost allocation tag (Billing console, once).
    values = [format("user:Project$%s", var.name)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
