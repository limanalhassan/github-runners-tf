# Copy to terraform.tfvars and adjust. Everything here has a default in variables.tf.

region       = "us-east-1"
aws_profile  = "devopslab"
github_owner = "limanalhassan"
github_repos = ["devops-labs", "contract-opportunities"]
runner_label = "aws-m7i"

max_runners                     = 8   # 8 x 2 vCPU = the full 16 vCPU On-Demand quota
on_demand_base_capacity         = 1   # first runner On-Demand
on_demand_percentage_above_base = 100 # all On-Demand while on free-plan credits; set 0 to use Spot for runners 2+

budget_email       = "liman@linux.com"
budget_monthly_usd = 20
