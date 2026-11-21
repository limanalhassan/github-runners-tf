# Default VPC public subnets: instances get a public IP for outbound traffic, so there is
# no NAT Gateway (that alone would cost ~$32/month). The security group allows no inbound.

data "aws_vpc" "default" {
  default = true
}

# Only AZs that actually offer the instance type.
data "aws_ec2_instance_type_offerings" "this" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_subnets" "runners" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.this.locations
  }
}

resource "aws_security_group" "runners" {
  name        = "${var.name}-sg"
  description = "GitHub runners: no inbound, all outbound"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
