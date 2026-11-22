variable "name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "gh-runners"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile Terraform uses."
  type        = string
  default     = "devopslab"
}

variable "github_owner" {
  description = "GitHub user or org that owns the repo."
  type        = string
  default     = "limanalhassan"
}

variable "github_repos" {
  description = "Repos the runners serve (same owner). The first one names the webhook secret parameter."
  type        = list(string)
  default     = ["devops-labs"]
}

variable "github_pat_parameter" {
  description = "SSM Parameter Store name (SecureString, Standard tier) holding the fine-grained PAT. Create it by hand before the first apply."
  type        = string
  default     = "/gh-runners/devops-labs/pat"
}

variable "runner_label" {
  description = "Custom label the runners get. Jobs opt in with `runs-on: <this label>`."
  type        = string
  default     = "aws-m7i"
}

variable "instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "max_runners" {
  description = "Hard cap on instances running at once (each uses 2 vCPU of your quota)."
  type        = number
  default     = 3
}

variable "on_demand_base_capacity" {
  description = "How many of the first instances are On-Demand. The rest follow on_demand_percentage_above_base."
  type        = number
  default     = 1
}

variable "on_demand_percentage_above_base" {
  description = "Percent On-Demand above the base. 0 = every extra runner is Spot. 100 = no Spot at all."
  type        = number
  default     = 0
}

variable "root_volume_size_gb" {
  type    = number
  default = 50
}

variable "idle_timeout_minutes" {
  description = "A runner that has not picked up a job by this time deregisters and terminates."
  type        = number
  default     = 15
}

variable "max_job_minutes" {
  description = "Safety cap: an instance is terminated after this long no matter what."
  type        = number
  default     = 90
}

variable "key_name" {
  description = "Optional EC2 key pair for SSH. Leave null and use SSM Session Manager instead."
  type        = string
  default     = null
}

variable "keep_failed_instances" {
  description = "Debug switch: when true, an instance whose bootstrap fails stays up so you can inspect it. Leave false normally."
  type        = bool
  default     = false
}

variable "reconcile_interval_minutes" {
  description = "How often the scaler re-checks GitHub for queued jobs (backs up the webhook)."
  type        = number
  default     = 2
}

variable "budget_email" {
  description = "Email for the monthly budget alert. Null skips the budget."
  type        = string
  default     = null
}

variable "budget_monthly_usd" {
  type    = number
  default = 20
}
