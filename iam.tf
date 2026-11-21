locals {
  asg_name = "${var.name}-asg"
  # ASG ARNs contain a random id, so match on the name part.
  asg_arn_pattern = "arn:aws:autoscaling:${var.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${local.asg_name}"
}

# ---------- Runner instances ----------

resource "aws_iam_role" "runner" {
  name = "${var.name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "runner" {
  name = "runner"
  role = aws_iam_role.runner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadPat"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = data.aws_ssm_parameter.github_pat.arn
      },
      {
        Sid      = "TerminateSelf"
        Effect   = "Allow"
        Action   = ["autoscaling:TerminateInstanceInAutoScalingGroup", "autoscaling:SetInstanceProtection"]
        Resource = local.asg_arn_pattern
      }
    ]
  })
}

# Shell access through Session Manager, no SSH port needed.
resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.name}-instance"
  role = aws_iam_role.runner.name
}

# ---------- Scaler Lambda ----------

resource "aws_iam_role" "scaler" {
  name = "${var.name}-scaler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scaler" {
  name = "scaler"
  role = aws_iam_role.scaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = [data.aws_ssm_parameter.github_pat.arn, aws_ssm_parameter.webhook_secret.arn]
      },
      {
        Effect   = "Allow"
        Action   = "autoscaling:DescribeAutoScalingGroups"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "autoscaling:SetDesiredCapacity"
        Resource = local.asg_arn_pattern
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.scaler.arn}:*"
      }
    ]
  })
}
