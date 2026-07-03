# app-and-alb.tf
# ===========================================================================
# THE PUBLIC EDGE + APP/API TIER (the "limited public web that queries and
# presents info"). Traffic path:
#
#   allowed web ranges --(80/443)--> ALB (public subnets)
#        --> app/API instances (private-medium, no public IP)
#             --> Kafka / Postgres / OpenSearch (private-large)
#             --> NiFi (private-medium)
#             --> SNS / SQS (AWS-native, via VPC endpoints)
#
# The ALB is the ONLY thing the internet can touch, and only on the ports and
# source ranges you allow (var.allowed_web_cidrs). Everything that holds data
# sits in private subnets with no route from the internet inbound.
#
# Gated on var.enable_example_workloads.
# ===========================================================================

locals {
  public_subnet_ids = [for az in local.azs : aws_subnet.public[az].id]
  https_enabled     = var.enable_example_workloads && var.acm_certificate_arn != ""
}

# ---------------------------------------------------------------------------
# App/API IAM role: SSM + peer discovery + permission to publish to SNS and
# read/write the SQS queue. Least privilege - scoped to THIS topic/queue.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "app" {
  count              = local.wl
  name_prefix        = "${local.name_prefix}-app-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  count      = local.wl
  role       = aws_iam_role.app[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app_perms" {
  count = local.wl

  statement {
    sid       = "Discovery"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "PublishEvents"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.events[0].arn]
  }

  statement {
    sid = "ConsumeQueue"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.main[0].arn, aws_sqs_queue.dlq[0].arn]
  }
}

resource "aws_iam_role_policy" "app_perms" {
  count  = local.wl
  role   = aws_iam_role.app[0].id
  policy = data.aws_iam_policy_document.app_perms[0].json
}

resource "aws_iam_instance_profile" "app" {
  count       = local.wl
  name_prefix = "${local.name_prefix}-app-"
  role        = aws_iam_role.app[0].name
}

# ---------------------------------------------------------------------------
# App/API instances (Java / Node). Private-medium, no public IP. The ALB SG is
# the only thing allowed to reach them on 8080.
# ---------------------------------------------------------------------------
resource "aws_instance" "app" {
  count                  = var.enable_example_workloads ? var.app_node_count : 0
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.app_instance_type
  subnet_id              = local.medium_subnet_ids[count.index % length(local.medium_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app[0].name
  key_name               = var.ec2_key_name != "" ? var.ec2_key_name : null

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # Discover backend endpoints by tag and drop them in /etc/app.env, then run
  # your Java/Node service listening on 8080 with a 200 on /health.
  user_data = <<-BASH
    #!/bin/bash
    set -euxo pipefail
    dnf -y update
    TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

    disc() { aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Cluster,Values=$1" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].PrivateIpAddress' --output text | tr '\t' '\n' | sort; }

    KAFKA=$(disc "${local.name_prefix}-kafka"      | sed 's/$/:9092/' | paste -sd, -)
    PG=$(disc    "${local.name_prefix}-postgres"   | head -1)
    OS=$(disc    "${local.name_prefix}-opensearch" | sed 's/$/:9200/' | paste -sd, -)

    : > /etc/app.env
    echo "KAFKA_BOOTSTRAP=$KAFKA"   >> /etc/app.env
    echo "POSTGRES_HOST=$PG"        >> /etc/app.env
    echo "POSTGRES_PORT=5432"       >> /etc/app.env
    echo "OPENSEARCH_NODES=$OS"     >> /etc/app.env
    echo "SNS_TOPIC_ARN=${var.enable_example_workloads ? aws_sns_topic.events[0].arn : ""}" >> /etc/app.env
    echo "SQS_QUEUE_URL=${var.enable_example_workloads ? aws_sqs_queue.main[0].id : ""}"    >> /etc/app.env
    # >>> Install and start your Java/Node API here. It should read /etc/app.env,
    #     serve 8080, and return HTTP 200 on /health for the ALB health check.
  BASH

  tags = {
    Name    = "${local.name_prefix}-app-${count.index}"
    Tier    = "private-medium"
    Role    = "app"
    Cluster = "${local.name_prefix}-app"
  }
}

# ---------------------------------------------------------------------------
# Public Application Load Balancer - the single internet entry point.
# ---------------------------------------------------------------------------
resource "aws_lb" "web" {
  count              = local.wl
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.public_subnet_ids
  tags               = { Name = "${local.name_prefix}-alb" }
}

resource "aws_lb_target_group" "app" {
  count       = local.wl
  name        = "${local.name_prefix}-app-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  count            = var.enable_example_workloads ? var.app_node_count : 0
  target_group_arn = aws_lb_target_group.app[0].arn
  target_id        = aws_instance.app[count.index].id
  port             = 8080
}

# HTTPS listener when you supply an ACM certificate (recommended for prod).
resource "aws_lb_listener" "https" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.web[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# With a cert, port 80 just redirects to 443.
resource "aws_lb_listener" "http_redirect" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.web[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Without a cert (demo), port 80 forwards straight to the app. Add a cert for prod.
resource "aws_lb_listener" "http_forward" {
  count             = var.enable_example_workloads && var.acm_certificate_arn == "" ? 1 : 0
  load_balancer_arn = aws_lb.web[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}
