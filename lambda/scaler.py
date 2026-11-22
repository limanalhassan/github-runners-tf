"""Scale the runner ASG to match queued and running GitHub jobs.

Called two ways:
- by API Gateway when GitHub sends a `workflow_job` webhook (signature checked), and
- by an EventBridge schedule every few minutes, as a backstop for jobs that queued
  while every runner was busy.

Both paths do the same idempotent thing: count jobs that want our label and are
queued or in progress, cap at the ASG max, and raise desired capacity if it is lower.
It never lowers capacity: each instance removes itself when its one job is done.
"""

import base64
import hashlib
import hmac
import json
import os
import urllib.request

import boto3

REPOS = [r.strip() for r in os.environ["GITHUB_REPOS"].split(",") if r.strip()]
LABEL = os.environ["RUNNER_LABEL"]
ASG_NAME = os.environ["ASG_NAME"]
PAT_PARAM = os.environ["PAT_PARAMETER"]
SECRET_PARAM = os.environ["WEBHOOK_SECRET_PARAMETER"]

ssm = boto3.client("ssm")
asg = boto3.client("autoscaling")
_params: dict[str, str] = {}


def _param(name: str) -> str:
    if name not in _params:
        _params[name] = ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]
    return _params[name]


def _gh(repo: str, path: str) -> dict:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/{path}",
        headers={
            "Authorization": f"Bearer {_param(PAT_PARAM)}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def _wanted_jobs() -> int:
    """Jobs with our label that are queued or running, across every repo we serve."""
    count = 0
    for repo in REPOS:
        for status in ("queued", "in_progress"):
            runs = _gh(repo, f"actions/runs?status={status}&per_page=100")["workflow_runs"]
            for run in runs:
                jobs = _gh(repo, f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]
                count += sum(1 for j in jobs if j["status"] in ("queued", "in_progress") and LABEL in j["labels"])
    return count


def reconcile() -> dict:
    group = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])["AutoScalingGroups"][0]
    current, maximum = group["DesiredCapacity"], group["MaxSize"]
    target = min(maximum, _wanted_jobs())
    if target > current:
        asg.set_desired_capacity(AutoScalingGroupName=ASG_NAME, DesiredCapacity=target, HonorCooldown=False)
    result = {"current": current, "target": target, "max": maximum, "scaled": target > current}
    print(json.dumps(result))
    return result


def _response(code: int, body: str) -> dict:
    return {"statusCode": code, "body": body}


def handler(event, _context):
    # Scheduled backstop.
    if event.get("reconcile"):
        return reconcile()

    # Webhook through API Gateway (HTTP API, payload v2).
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    expected = "sha256=" + hmac.new(_param(SECRET_PARAM).encode(), body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(headers.get("x-hub-signature-256", ""), expected):
        return _response(401, "bad signature")

    kind = headers.get("x-github-event")
    if kind == "ping":
        return _response(200, "pong")
    if kind != "workflow_job":
        return _response(202, "ignored event")

    payload = json.loads(body)
    if payload.get("repository", {}).get("full_name") not in REPOS:
        return _response(202, "ignored repo")
    job = payload["workflow_job"]
    if payload["action"] != "queued" or LABEL not in job["labels"]:
        return _response(202, "ignored job")

    return _response(200, json.dumps(reconcile()))
