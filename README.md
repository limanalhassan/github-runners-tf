# github-runners-tf

Auto-scaling, ephemeral, self-hosted GitHub Actions runners on AWS EC2 for
`limanalhassan/devops-labs`. Runners scale from zero: when CI is idle nothing runs and
nothing bills. Each job gets a fresh instance that terminates itself when the job ends.

Built and verified 2026-11-20/21. Smoke run `44859172210` green; first full CI run on
these runners: `44859496610`.

---

## Contents

1. [How it works](#1-how-it-works)
2. [What gets created](#2-what-gets-created)
3. [Prerequisites](#3-prerequisites)
4. [Setup from scratch](#4-setup-from-scratch)
5. [Point CI at the runners](#5-point-ci-at-the-runners)
6. [Verify it works](#6-verify-it-works)
7. [Day-to-day operations](#7-day-to-day-operations)
8. [Costs](#8-costs)
9. [Troubleshooting](#9-troubleshooting)
10. [Design decisions](#10-design-decisions)
11. [Teardown](#11-teardown)

---

## 1. How it works

```
 git push / Run workflow
        │
        ▼
 GitHub queues a job with  runs-on: aws-m7i
        │  webhook (workflow_job)                      every 2 min (backstop)
        ▼                                                      │
 API Gateway  POST /webhook ──► Lambda "gh-runners-scaler" ◄───┘ EventBridge
                                   │ 1. verify HMAC signature
                                   │ 2. count queued + running aws-m7i jobs (GitHub API)
                                   │ 3. ASG desired = min(max_runners, that count)
                                   │    (only ever raises it, never lowers)
                                   ▼
                      Auto Scaling Group "gh-runners-asg" (min 0, max 8)
                                   │ launches m7i-flex.large (Ubuntu 24.04)
                                   ▼
                      user-data bootstrap on the instance:
                        install Docker, buildx, compose, git, Python, AWS CLI
                        read the PAT from Parameter Store
                        register a JIT (single-job) runner with GitHub
                        run exactly one job
                                   │
                                   ▼
                      job finished ──► instance removes its scale-in protection,
                                       terminates itself and lowers ASG desired by 1
                                       ──► back to 0 when the queue is empty
```

Safety nets so nothing runs (and bills) forever:

| Situation | What happens |
|---|---|
| Job finishes | Instance terminates within seconds |
| Runner gets no job within 15 min (job cancelled, taken by another runner) | Runner deregisters, instance terminates |
| Instance alive 90 min | Hard kill, regardless of state |
| Bootstrap script fails | Instance terminates (set `keep_failed_instances = true` to debug) |
| Webhook missed or jobs queued while all runners busy | 2-minute backstop re-counts and scales up |
| ASG tries to rebalance or scale in | Blocked: instances are scale-in protected and `AZRebalance` is suspended, so a busy runner is never killed |

---

## 2. What gets created

22 resources (plus a budget when `budget_email` is set):

| File | Resources |
|---|---|
| `network.tf` | Security group `gh-runners-sg` (no inbound, all outbound) in the **default VPC**, subnets filtered to AZs that offer `m7i-flex.large` |
| `iam.tf` | Instance role (read the PAT, terminate itself, SSM Session Manager) and Lambda role (read PAT + webhook secret, set ASG capacity, write logs) |
| `asg.tf` | Launch template (Ubuntu 24.04, 50 GB gp3 encrypted, IMDSv2 hop limit 1, public IP) and ASG with mixed On-Demand/Spot policy |
| `lambda.tf` | Lambda `gh-runners-scaler` (Python 3.13, stdlib only), HTTP API Gateway, EventBridge 2-minute rule, 7-day log group |
| `ssm.tf` | Random webhook secret stored as SecureString `/gh-runners/devops-labs/webhook-secret`; reads the PAT parameter |
| `github.tf` | Repo webhook on `devops-labs` for `workflow_job` events |
| `budget.tf` | Optional monthly cost budget with email alerts |
| `templates/user_data.sh.tftpl` | Instance bootstrap (systemd unit `gh-runner`) |
| `lambda/scaler.py` | Scaler logic |
| `examples/runner-smoke.yaml` | End-to-end test workflow |

**Not** created by Terraform (on purpose): the PAT parameter `/gh-runners/devops-labs/pat`.
You create it by hand so the token never sits in a `.tf` or `.tfvars` file.

---

## 3. Prerequisites

| Need | Value used |
|---|---|
| AWS account | Free plan, $200 credits, us-east-1 |
| AWS CLI profile | `devopslab` (check: `aws sts get-caller-identity --profile devopslab`) |
| Terraform | >= 1.9 (built with 1.14.4) |
| GitHub repo | `limanalhassan/devops-labs` (private, personal account, so runners are **repo-level**) |
| EC2 vCPU quota | 16 On-Demand standard vCPU (`L-1216C47A`), 32 Spot. Each runner uses 2. Check: |

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --region us-east-1 --profile devopslab --query 'Quota.Value'
```

`max_runners × 2` must stay under the quota.

---

## 4. Setup from scratch

### Step 1. Create a fine-grained Personal Access Token (PAT)

GitHub → your avatar → **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token**.

| Field | Set to |
|---|---|
| Token name | e.g. `gh-runners-devops-labs` |
| Expiration | Your choice. **Current token expires 2026-12-20.** Put a reminder in your calendar |
| Repository access | **Only select repositories** → `devops-labs` **only** (do not add other repos) |

Repository permissions (use **+ Add permissions**):

| Permission | Access | Why |
|---|---|---|
| **Actions** | Read-only | Scaler counts queued and running jobs |
| **Administration** | Read and write | Register (JIT config) and delete runners. Missing this = every instance fails at boot |
| **Webhooks** | Read and write | Terraform creates the repo webhook. Missing this = `terraform apply` fails |
| Metadata | Read-only | Required, added automatically |

Click **Generate token** and copy it (starts with `github_pat_`). You cannot see it again.

### Step 2. Save the PAT in Parameter Store

Type **SecureString**, tier **Standard** (free). Run this in **zsh** (macOS default):

```bash
read -s "GH_PAT?Paste GitHub token, then press Enter: " && echo && \
aws ssm put-parameter --name /gh-runners/devops-labs/pat \
  --type SecureString --tier Standard --value "$GH_PAT" \
  --region us-east-1 --profile devopslab && unset GH_PAT
```

What it does:

1. `read -s` shows the prompt and waits. **Paste the token (Cmd+V). Nothing appears on
   screen; that is expected.** Press Enter.
2. `aws ssm put-parameter` creates the parameter (no need to create it first) and stores
   the token encrypted with the AWS managed `aws/ssm` key.
3. `unset GH_PAT` wipes the variable from your shell.

This keeps the token out of `~/.zsh_history`. Do **not** use `--value github_pat_...`
directly, it would be saved in plain text in your history.

In **bash**, the prompt syntax differs: `read -s -p "Paste GitHub token: " GH_PAT`.

Success output:

```json
{ "Version": 1, "Tier": "Standard" }
```

Verify without printing the token:

```bash
aws ssm get-parameter --name /gh-runners/devops-labs/pat --region us-east-1 \
  --profile devopslab --query 'Parameter.{name:Name,type:Type,version:Version}'
```

**Order matters:** this step must come **before** `terraform apply`. Terraform only
*reads* this parameter; if it is missing, plan/apply fail with `ParameterNotFound`.

### Step 3. Configure variables (optional)

```bash
cp terraform.tfvars.example terraform.tfvars
```

Defaults live in `variables.tf`. The ones you are most likely to touch:

| Variable | Default | Current | Meaning |
|---|---|---|---|
| `max_runners` | 3 | **8** | Max instances at once. Must match `max-parallel` in `ci.yaml` |
| `on_demand_base_capacity` | 1 | 1 | First N runners are On-Demand |
| `on_demand_percentage_above_base` | 0 | **100** | 100 = all On-Demand (current, while on credits). 0 = Spot for runners 2+ |
| `instance_type` | `m7i-flex.large` | same | 2 vCPU, 8 GiB |
| `root_volume_size_gb` | 50 | 50 | gp3 disk per runner |
| `idle_timeout_minutes` | 15 | 15 | Runner with no job terminates after this |
| `max_job_minutes` | 90 | 90 | Hard cap per instance |
| `runner_label` | `aws-m7i` | same | Jobs use `runs-on: aws-m7i` |
| `budget_email` | null | set | Enables the monthly budget alert |
| `budget_monthly_usd` | 20 | 20 | Budget amount |
| `keep_failed_instances` | false | false | Debug only: keep instances whose bootstrap fails |

`terraform.tfvars` is git-ignored.

### Step 4. Deploy

```bash
cd ~/git/github-runners-tf
terraform init
terraform plan      # expect: 22 to add (23 with budget)
terraform apply     # type: yes
```

Outputs:

```
asg_name     = "gh-runners-asg"
runner_label = "aws-m7i"
webhook_url  = "https://<id>.execute-api.us-east-1.amazonaws.com/webhook"
```

Nothing bills after apply: the ASG starts at 0 instances.

### Step 5. Activate the cost allocation tag (for the budget)

The budget filters on the `Project=gh-runners` tag. AWS ignores tags in billing until
you activate them once:

```bash
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=Project,Status=Active \
  --region us-east-1 --profile devopslab
```

If it says the tag is not found, wait about 24 h after the first tagged resource exists
and run it again.

---

## 5. Point CI at the runners

In `devops-labs/.github/workflows/ci.yaml` (done in commit `e1bd057`):

```yaml
jobs:
  api:
    runs-on: aws-m7i
  ui:
    runs-on: aws-m7i
  plan:
    runs-on: aws-m7i
  labs:
    runs-on: aws-m7i
    strategy:
      fail-fast: false
      max-parallel: 8        # keep equal to max_runners
      matrix: ...
```

`publish.yaml` stays on `ubuntu-latest`: it builds `linux/amd64,linux/arm64`, and arm64
emulation on 2 vCPU is very slow. It only runs on release tags.

**Keep `max-parallel` and `max_runners` equal.** If `max-parallel` is lower, extra runners
are never used. If it is higher, jobs simply wait in the queue (harmless).

A change to `max-parallel` only applies to runs started after the push; a run already in
progress keeps its old limit.

---

## 6. Verify it works

### 6a. Webhook

Repo → **Settings → Webhooks** → the `execute-api` hook → **Recent Deliveries**. The
`ping` should be **200**. Or from the CLI:

```bash
HOOK=$(gh api repos/limanalhassan/devops-labs/hooks --jq '.[]|select(.config.url|test("execute-api"))|.id')
gh api repos/limanalhassan/devops-labs/hooks/$HOOK/deliveries \
  --jq '.[0:5][]|"\(.delivered_at) \(.event)/\(.action) status=\(.status_code)"'
gh api -X POST repos/limanalhassan/devops-labs/hooks/$HOOK/pings   # resend a ping
```

An unsigned request must be rejected (proves signature checking works):

```bash
curl -s -X POST "$(terraform output -raw webhook_url)" -d '{}'   # -> bad signature (401)
```

### 6b. Scaler

```bash
aws lambda invoke --function-name gh-runners-scaler --payload '{"reconcile":true}' \
  --cli-binary-format raw-in-base64-out --region us-east-1 --profile devopslab /dev/stdout
# {"current": 0, "target": 0, "max": 8, "scaled": false}
```

### 6c. Smoke test (end to end)

`examples/runner-smoke.yaml` is already in `devops-labs/.github/workflows/`. Run it:

```bash
gh workflow run runner-smoke.yaml -R limanalhassan/devops-labs --ref main
```

Expected timeline (measured):

| Time | Event |
|---|---|
| 0:00 | Job queued, scaler sets desired 0 → 1 |
| ~0:15 | Instance launches (`InService`) |
| ~1:30 | Runner `aws-i-<instance-id>` appears in **Settings → Actions → Runners** with a yellow **Active** dot (busy), job starts |
| ~2:00 | Job green, runner disappears, instance `Terminating`, desired back to 0 |

The smoke job prints Python 3.12, Docker 29.x, buildx 0.30.x, `hello-world`, disk
(48 GB, about 43 GB free) and memory (7.6 GiB).

### 6d. Watch the ASG

```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names gh-runners-asg \
  --region us-east-1 --profile devopslab \
  --query 'AutoScalingGroups[0].{desired:DesiredCapacity,max:MaxSize,instances:Instances[].[InstanceId,LifecycleState]}'
```

Which instances are Spot vs On-Demand:

```bash
aws ec2 describe-instances --region us-east-1 --profile devopslab \
  --filters Name=tag:aws:autoscaling:groupName,Values=gh-runners-asg Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceLifecycle||`on-demand`,LaunchTime]' --output text
```

---

## 7. Day-to-day operations

### Rotate the PAT (before it expires: current one expires 2026-12-20)

Create a new token with the same permissions (Step 1), then:

```bash
read -s "GH_PAT?Paste NEW GitHub token, then press Enter: " && echo && \
aws ssm put-parameter --name /gh-runners/devops-labs/pat --overwrite \
  --type SecureString --tier Standard --value "$GH_PAT" \
  --region us-east-1 --profile devopslab && unset GH_PAT
```

New instances read it at boot. The Lambda caches it per container, so force a refresh:

```bash
aws lambda update-function-configuration --function-name gh-runners-scaler \
  --description "pat rotated $(date +%F)" --region us-east-1 --profile devopslab >/dev/null
```

No `terraform apply` needed. An **expired token means jobs sit in `queued` forever**.

### Change the number of runners

Edit `max_runners` in `terraform.tfvars`, `terraform apply` (in-place, running instances
are untouched), and update `max-parallel` in `ci.yaml` to the same number.

### Turn Spot off

`on_demand_percentage_above_base = 100`, then `terraform apply`.

### Shell into a running runner (no SSH, no open ports)

```bash
aws ssm start-session --target <instance-id> --region us-east-1 --profile devopslab
sudo journalctl -u gh-runner -f          # bootstrap + runner log
cat /opt/gh-runner/env                   # config the instance booted with
```

Needs the Session Manager plugin locally: `brew install --cask session-manager-plugin`.

### Scaler logs

```bash
aws logs tail /aws/lambda/gh-runners-scaler --since 15m --follow \
  --region us-east-1 --profile devopslab
```

Each line is `{"current": N, "target": N, "max": N, "scaled": bool}`.

### Empty the ASG by hand (emergency stop)

```bash
aws autoscaling update-auto-scaling-group --auto-scaling-group-name gh-runners-asg \
  --max-size 0 --region us-east-1 --profile devopslab
```

Instances are scale-in protected, so also terminate them:

```bash
for i in $(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names gh-runners-asg \
  --region us-east-1 --profile devopslab --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text); do
  aws ec2 terminate-instances --instance-ids $i --region us-east-1 --profile devopslab >/dev/null; done
```

`terraform apply` restores `max-size` afterwards.

---

## 8. Costs

You pay per **job-minute**, not per runner. `max_runners` only changes how fast a run
finishes, not what it costs.

| Item | Price (us-east-1) | When |
|---|---|---|
| `m7i-flex.large` On-Demand | ~$0.096/h | only while a job runs |
| `m7i-flex.large` Spot | ~$0.030 to $0.042/h | only while a job runs |
| 50 GB gp3 | ~$0.0055/h | deleted with the instance |
| Public IPv4 | $0.005/h | only while running |
| Lambda, API Gateway, EventBridge, SSM Standard, logs (7 days) | ~$0 | within free allowances |
| NAT Gateway | **$0, there is none** (one would be ~$33/month + $0.045/GB) | |

Measured basis: a full CI run is ~20 jobs and ~218 job-minutes, plus ~1.5 min boot per job,
so about **4.2 instance-hours**.

| Run | Cost |
|---|---|
| Full CI run (all modules) | ~$0.20 to $0.25 |
| Typical push (api + ui + plan + 1 module) | ~$0.02 to $0.03 |
| Idle | ~$0 |

| Monthly usage | Estimate |
|---|---|
| Light: 30 pushes + 2 full runs | ~$1.50 |
| Normal: 60 pushes + 6 full runs | ~$3 |
| Heavy: 150 pushes + 20 full runs | ~$8 to $9 |

Full runs happen on any change to `api/`, `compose.yaml`, `.github/workflows/ci.yaml` or
the CI matrix scripts, on tags and on manual dispatch.

**GitHub side:** self-hosted runner minutes are free (a $0.002/min platform fee announced
for March 2026 was postponed; check GitHub's billing docs now and then). But a GitHub
**billing block still stops self-hosted jobs** (see Troubleshooting).

**AWS free plan deadline:** free-plan accounts close **6 months after creation** (or when
credits run out) unless upgraded to a paid plan. Upgrade before then; unused credits carry
over. Check remaining credits:

```bash
aws freetier get-account-plan-state --region us-east-1 --profile devopslab
```

**Budget:** counts usage **before** credits (`include_credit = false`). Otherwise credits
make net cost $0 and the alert never fires. Alerts at 80% actual and 100% forecast.

---

## 9. Troubleshooting

### Run shows `Startup failure`, no jobs created

Open the run page. If the annotation says:

> The job was not started because recent account payments have failed or your spending
> limit needs to be increased.

it is a **GitHub billing block**, not this infra. It blocks self-hosted jobs too. Fix it
at **github.com/settings/billing** (payment method, or raise the Actions budget). The
Lambda logs show `target: 0` because GitHub never created the job.

### Re-run of a failed-to-start run sits in `queued` with no jobs

Re-running a `startup_failure` run can get stuck. Start a fresh run instead:

```bash
gh workflow run <workflow>.yaml -R limanalhassan/devops-labs --ref main
```

### Job queued, no instance starts

1. Scaler logs (section 7). `target: 0` means it does not see a job with label `aws-m7i`:
   check `runs-on` spelling.
2. `target > current` but no instance: check ASG activity:
   ```bash
   aws autoscaling describe-scaling-activities --auto-scaling-group-name gh-runners-asg \
     --max-items 5 --region us-east-1 --profile devopslab \
     --query 'Activities[].[StartTime,StatusCode,StatusMessage]' --output text
   ```
   Typical causes: vCPU quota reached, Spot capacity (the On-Demand base still launches).
3. Errors calling GitHub (401/403): PAT expired or missing a permission. Rotate it.

### Instance starts but runner never appears

The bootstrap failed and the instance terminated itself. To see why, set
`keep_failed_instances = true`, `terraform apply`, re-run the job, then shell in
(section 7) and run `sudo journalctl -u gh-runner`. Set it back to `false` afterwards.

### `terraform plan` fails with `ParameterNotFound`

The PAT parameter does not exist yet. Do Step 2 first.

### `read -s` "hangs"

It is waiting for you to paste the token. Nothing shows while you type or paste. Press
Enter after pasting.

### First webhook ping shows 404

GitHub pings the moment the hook is created. Fixed with `depends_on` in `github.tf` so the
route exists first. If you still see it, resend a ping (section 6a).

### A job failed with the runner lost mid-run

Probably a Spot interruption (2-minute notice, instance reclaimed). Re-run the failed job.
If it happens often, raise `on_demand_base_capacity` or set
`on_demand_percentage_above_base = 100`.

### A shard runs out of memory or disk

Each job has 8 GiB RAM and ~43 GB free disk. If a lab shard OOMs, the options are a larger
`instance_type` (check free-plan eligibility first) or splitting the shard in
`.github/scripts/lab_matrix.py` (`SHARDS`).

---

## 10. Design decisions

| Decision | Why |
|---|---|
| Ephemeral one-job runners (JIT config) | Clean machine every job, no Docker leftovers or full disks, nothing to patch long-term, no idle billing |
| ASG + small Lambda, not the community `terraform-aws-github-runner` module | Small enough to read end to end; uses an ASG as requested |
| Not ECS / Fargate | Lab tests need a real Docker daemon; Fargate allows no privileged containers or Docker-in-Docker |
| Scaler only raises capacity; instances lower it themselves | The ASG never picks a busy runner to kill |
| 2-minute reconcile backstop | Jobs queued while all runners were busy still get a runner when one frees up (verified 2026-11-21) |
| Default VPC public subnets, no NAT | NAT Gateway would cost ~$33/month idle plus data processing. Security group has no inbound rules; shell access through SSM |
| IMDSv2, hop limit 1 | Containers started by lab tests cannot reach the instance role credentials |
| Ubuntu 24.04, not 26.04 | Matches GitHub's `ubuntu-latest`, so `setup-python` and `setup-node` have prebuilt binaries |
| gp3, not gp2 | 3,000 IOPS baseline at any size and ~20% cheaper; gp2 at 50 GB only gets 150 IOPS baseline |
| 50 GB disk | Heaviest shard peaks around 15 GB; 11% used after bootstrap |
| PAT in SSM Standard SecureString, created by hand | Free tier, encrypted, and the token never appears in Terraform code |
| First runner On-Demand, rest Spot | Single-job CI is reliable on the first runner; burst capacity is ~65% cheaper |
| `publish.yaml` stays on GitHub-hosted | Multi-arch (arm64 via QEMU) builds are slow on 2 vCPU, and it only runs on tags |

### Possible next step: a baked AMI

Each boot spends ~60 to 90 s installing packages. A Packer-built AMI with Docker, the
runner, AWS CLI, Python 3.12, Node 22 and the large lab base images pre-pulled would save
~1.5 to 2.5 min per job. Cost: ~$0.50/month for the snapshot plus rebuilding it every few
weeks for security updates. Adding installs to the launch template's user-data does **not**
help; it runs on every boot.

---

## 11. Teardown

```bash
terraform destroy
```

Removes the ASG (and any running runners), launch template, Lambda, API Gateway, rule,
webhook, IAM roles, security group, webhook secret and budget. Then, if you want them gone:

```bash
aws ssm delete-parameter --name /gh-runners/devops-labs/pat --region us-east-1 --profile devopslab
```

and revoke the PAT on GitHub. Switch `ci.yaml` back to `runs-on: ubuntu-latest` first, or
CI jobs will queue forever.

---

## Notes

- **State is local** (`terraform.tfstate`). It contains the PAT and the webhook secret.
  It is git-ignored. Before running Terraform from another machine, move state to a shared
  backend (e.g. S3 with versioning and encryption); running `apply` with no state would try
  to create everything again and collide with the existing resources.
- The PAT is fetched at runtime by the instances and the Lambda; rotating it never needs a
  Terraform change.
