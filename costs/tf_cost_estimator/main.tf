data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.aws_region}.s3"
}

resource "aws_subnet" "internal_a" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = cidrsubnet(data.aws_vpc.default.cidr_block, 8, 250)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.instance_name}-internal-a"
  }
}

resource "aws_subnet" "internal_b" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = cidrsubnet(data.aws_vpc.default.cidr_block, 8, 251)
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.instance_name}-internal-b"
  }
}

resource "aws_route_table" "internal" {
  vpc_id = data.aws_vpc.default.id

  tags = {
    Name = "${var.instance_name}-internal-rt"
  }
}

resource "aws_route_table_association" "internal_a" {
  subnet_id      = aws_subnet.internal_a.id
  route_table_id = aws_route_table.internal.id
}

resource "aws_route_table_association" "internal_b" {
  subnet_id      = aws_subnet.internal_b.id
  route_table_id = aws_route_table.internal.id
}

locals {
  internal_subnet_ids = [
    aws_subnet.internal_a.id,
    aws_subnet.internal_b.id
  ]
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.internal.id]

  tags = {
    Name = "${var.instance_name}-s3-endpoint"
  }
}

resource "aws_iam_role" "ec2_ssm_role" {
  name = "${var.instance_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.instance_name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

resource "aws_security_group" "alb_sg" {
  name        = "${var.instance_name}-alb-sg"
  description = "Allow inbound HTTP from inside the VPC"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from inside VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    description = "Traffic to web servers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  tags = {
    Name = "${var.instance_name}-alb-sg"
  }
}

resource "aws_security_group" "web_sg" {
  name        = "${var.instance_name}-web-sg"
  description = "Allow HTTP from ALB and private egress to VPC endpoints"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "Within VPC, including interface endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    description     = "HTTPS to S3 via gateway endpoint prefix list"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_prefix_list.s3.id]
  }

  tags = {
    Name = "${var.instance_name}-web-sg"
  }
}

resource "aws_security_group" "ssm_endpoint_sg" {
  name        = "${var.instance_name}-ssm-endpoint-sg"
  description = "Allow EC2 instances to connect to SSM interface endpoints"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTPS from EC2 web servers"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  tags = {
    Name = "${var.instance_name}-ssm-endpoint-sg"
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.internal_subnet_ids
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.instance_name}-ssm-endpoint"
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.internal_subnet_ids
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.instance_name}-ssmmessages-endpoint"
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.internal_subnet_ids
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.instance_name}-ec2messages-endpoint"
  }
}

resource "aws_instance" "web_server" {
  count = var.instance_count

  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = element(local.internal_subnet_ids, count.index % length(local.internal_subnet_ids))
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids      = [aws_security_group.web_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              systemctl enable amazon-ssm-agent
              systemctl start amazon-ssm-agent

              dnf install -y httpd
              systemctl enable httpd
              systemctl start httpd

              cat <<'HTML' > /var/www/html/index.html
              <!DOCTYPE html>
              <html>
                <head><title>Hello World</title></head>
                <body>
                  <h1>Hello World</h1>
                  <p>Served by $(hostname -f)</p>
                </body>
              </html>
              HTML
              EOF

  depends_on = [
    aws_vpc_endpoint.s3,
    aws_vpc_endpoint.ssm,
    aws_vpc_endpoint.ssmmessages,
    aws_vpc_endpoint.ec2messages
  ]

  tags = {
    Name        = "${var.instance_name}-${count.index + 1}"
    Environment = "Development"
  }
}

resource "aws_lb" "app_lb" {
  name               = "${var.instance_name}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = local.internal_subnet_ids

  tags = {
    Name = "${var.instance_name}-alb"
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "${var.instance_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
    timeout             = 5
  }

  tags = {
    Name = "${var.instance_name}-tg"
  }
}

resource "aws_lb_target_group_attachment" "app_tg_attach" {
  count = var.instance_count

  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.web_server[count.index].id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}