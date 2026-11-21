# Canonical publishes the current Ubuntu 24.04 AMI here. 24.04 matches GitHub's
# ubuntu-latest, so actions/setup-python and friends have prebuilt binaries for it.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_launch_template" "runner" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type = var.instance_type
  key_name      = var.key_name

  # If the bootstrap ever falls back to `shutdown`, the instance is gone, not just stopped.
  instance_initiated_shutdown_behavior = "terminate"

  iam_instance_profile {
    arn = aws_iam_instance_profile.runner.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.runners.id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/sda1" # Ubuntu root device
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 only, hop limit 1: containers started by lab tests cannot reach the
  # instance role credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region                = var.region
    asg_name              = local.asg_name
    pat_parameter         = var.github_pat_parameter
    repo                  = "${var.github_owner}/${var.github_repo}"
    runner_label          = var.runner_label
    idle_timeout_minutes  = var.idle_timeout_minutes
    max_job_minutes       = var.max_job_minutes
    keep_failed_instances = var.keep_failed_instances
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-runner" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name}-runner" }
  }

  update_default_version = true
}

resource "aws_autoscaling_group" "runners" {
  name                = local.asg_name
  min_size            = 0
  max_size            = var.max_runners
  desired_capacity    = 0
  vpc_zone_identifier = data.aws_subnets.runners.ids
  health_check_type   = "EC2"

  # The scaler only ever raises desired capacity. Instances lower it themselves
  # when they finish, so the ASG must never pick a busy runner to kill.
  protect_from_scale_in = true
  suspended_processes   = ["AZRebalance"]
  capacity_rebalance    = false

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.runner.id
        version            = "$Latest"
      }
      override {
        instance_type = var.instance_type
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-runner"
    propagate_at_launch = true
  }

  lifecycle {
    # Owned by the scaler and the instances at runtime.
    ignore_changes = [desired_capacity]
  }
}
