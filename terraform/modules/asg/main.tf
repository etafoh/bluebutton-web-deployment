##
# Data providers
##
data "aws_vpc" "selected" {
  id = "${var.vpc_id}"
}

data "aws_subnet_ids" "app" {
  vpc_id = "${var.vpc_id}"

  tags {
    Layer       = "app"
    stack       = "${var.stack}"
    application = "${var.app}"
  }
}

data "aws_subnet" "app" {
  count = "${length(data.aws_subnet_ids.app.ids)}"
  id    = "${data.aws_subnet_ids.app.ids[count.index]}"
}

data "aws_elb" "elb" {
  name = "${var.elb_name}"
}

##
# Security groups
##
resource "aws_security_group" "ci" {
  name        = "ci-to-app-servers"
  description = "Allow CI access to app servers"
  vpc_id      = "${data.aws_vpc.selected.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.ci_cidrs}"]
  }
}

##
# Launch configuration
##
resource "aws_launch_configuration" "app" {
  security_groups = [
    "${var.app_sg_id}",
    "${var.vpn_sg_id}",
    "${aws_security_group.ci.id}",
  ]

  key_name                    = "${var.key_name}"
  image_id                    = "${var.ami_id}"
  instance_type               = "${var.instance_type}"
  associate_public_ip_address = false
  name_prefix                 = "bb-${var.stack}-app-"

  lifecycle {
    create_before_destroy = true
  }
}

##
# Autoscaling group
##
resource "aws_autoscaling_group" "main" {
  availability_zones        = ["${var.azs}"]
  name                      = "bb-${var.stack}-app-${aws_launch_configuration.app.name}"
  desired_capacity          = "${var.asg_desired}"
  max_size                  = "${var.asg_max}"
  min_size                  = "${var.asg_min}"
  min_elb_capacity          = "${var.asg_min}"
  health_check_grace_period = 300
  health_check_type         = "ELB"
  vpc_zone_identifier       = ["${data.aws_subnet_ids.app.ids}"]
  launch_configuration      = "${aws_launch_configuration.app.name}"
  load_balancers            = ["${data.aws_elb.elb.name}"]

  tag {
    key                 = "Name"
    value               = "bb-${var.stack}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "${var.env}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Function"
    value               = "app-AppServer"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

##
# Autoscaling policies and Cloudwatch alarms
##
resource "aws_autoscaling_policy" "high-cpu" {
  name                   = "${var.app}-${var.env}-high-cpu-scaleup"
  scaling_adjustment     = 2
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = "${aws_autoscaling_group.main.name}"
}

resource "aws_cloudwatch_metric_alarm" "high-cpu" {
  alarm_name          = "${var.app}-${var.env}-high-cpu"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "60"

  dimensions {
    AutoScalingGroupName = "${aws_autoscaling_group.main.name}"
  }

  alarm_description = "CPU usage for ${aws_autoscaling_group.main.name} ASG"
  alarm_actions     = ["${aws_autoscaling_policy.high-cpu.arn}"]
}

resource "aws_autoscaling_policy" "low-cpu" {
  name                   = "${var.app}-${var.env}-low-cpu-scaledown"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = "${aws_autoscaling_group.main.name}"
}

resource "aws_cloudwatch_metric_alarm" "low-cpu" {
  alarm_name          = "${var.app}-${var.env}-low-cpu"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "20"

  dimensions {
    AutoScalingGroupName = "${aws_autoscaling_group.main.name}"
  }

  alarm_description = "CPU usage for ${aws_autoscaling_group.main.name} ASG"
  alarm_actions     = ["${aws_autoscaling_policy.low-cpu.arn}"]
}