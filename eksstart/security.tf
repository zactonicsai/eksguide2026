# security.tf
# ---------------------------------------------------------------------------
# Layered security: Security Groups (stateful, instance-level) +
# Network ACLs (stateless, subnet-level) + VPC Endpoints (keep AWS-service
# traffic off the public internet) + Flow Logs (audit/visibility).
# ---------------------------------------------------------------------------

# === SECURITY GROUPS (the primary firewall; stateful) =====================

# Public-facing load balancer: accepts HTTPS from the internet.
resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Public ALB - allow 443 from internet"
  vpc_id      = aws_vpc.this.id

  # "Limited public web": only the allow-listed ranges may reach the ALB.
  ingress {
    description = "HTTPS from allowed web ranges"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_web_cidrs
  }

  ingress {
    description = "HTTP from allowed web ranges (redirect to HTTPS in prod)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_web_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags       = { Name = "${local.name_prefix}-sg-alb" }
  lifecycle { create_before_destroy = true }
}

# Web/app tier (Java + Node apps, backend APIs). Only the ALB may reach it.
resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "App tier - traffic only from the ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "App port from ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id] # reference, not CIDR
  }

  egress {
    description = "All outbound (to DB, cache, NAT, endpoints)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags       = { Name = "${local.name_prefix}-sg-app" }
  lifecycle { create_before_destroy = true }
}

# Data tier (Postgres/RDS). Only the app tier may reach 5432. No egress to net.
resource "aws_security_group" "data" {
  name_prefix = "${local.name_prefix}-data-"
  description = "Data tier - Postgres from app tier only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from app + NiFi tiers"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id, aws_security_group.nifi.id]
  }

  # Primary <-> standby streaming replication stays within the data tier.
  ingress {
    description = "Postgres replication between nodes"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
  }

  # Tight egress: databases rarely need to call out, but a self-hosted box
  # must fetch packages/patches. Allow responses within the VPC + HTTPS out.
  egress {
    description = "Responses within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS out for package install/patching (via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags       = { Name = "${local.name_prefix}-sg-data" }
  lifecycle { create_before_destroy = true }
}

# Messaging / streaming tier (Kafka/MSK). App tier produces/consumes.
resource "aws_security_group" "messaging" {
  name_prefix = "${local.name_prefix}-msg-"
  description = "Kafka/MSK - broker ports from app tier"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Kafka listeners from app + NiFi tiers"
    from_port       = 9092
    to_port         = 9098
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id, aws_security_group.nifi.id]
  }

  # Brokers must talk to each other for replication.
  ingress {
    description = "Inter-broker replication"
    from_port   = 9092
    to_port     = 9098
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS out for package install/patching (via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags       = { Name = "${local.name_prefix}-sg-messaging" }
  lifecycle { create_before_destroy = true }
}

# Search tier (self-hosted OpenSearch on EC2).
# Self-managed OpenSearch uses 9200 for the REST/HTTP API and 9300 for the
# node-to-node transport (cluster coordination) - NOT 443 like the managed
# OpenSearch Service. Clients hit 9200; nodes gossip on 9300 among themselves.
resource "aws_security_group" "search" {
  name_prefix = "${local.name_prefix}-search-"
  description = "Self-hosted OpenSearch - 9200 from app/NiFi, 9300 node-to-node"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "OpenSearch REST (9200) from app + NiFi"
    from_port       = 9200
    to_port         = 9200
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id, aws_security_group.nifi.id]
  }

  ingress {
    description = "OpenSearch transport (9300) between nodes"
    from_port   = 9300
    to_port     = 9300
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Responses within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS out for package install/patching (via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags       = { Name = "${local.name_prefix}-sg-search" }
  lifecycle { create_before_destroy = true }
}

# Dataflow tier (self-hosted Apache NiFi on EC2). NiFi pulls/pushes data to
# Kafka, Postgres, OpenSearch, S3, SQS/SNS, and external systems. The secured
# UI/API is 8443; cluster nodes coordinate on 11443 and load-balance on 6342.
resource "aws_security_group" "nifi" {
  name_prefix = "${local.name_prefix}-nifi-"
  description = "Self-hosted NiFi - UI from inside VPC, cluster ports node-to-node"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "NiFi HTTPS UI/API from within the VPC (reach via SSM or internal LB)"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "NiFi cluster node protocol"
    from_port   = 11443
    to_port     = 11443
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "NiFi cluster load balancing"
    from_port   = 6342
    to_port     = 6342
    protocol    = "tcp"
    self        = true
  }

  # NiFi dataflows frequently reach external sources, so allow all egress
  # (to the brokers/DB/search inside the VPC and out via NAT to the internet).
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags       = { Name = "${local.name_prefix}-sg-nifi" }
  lifecycle { create_before_destroy = true }
}

# Security group used by Interface VPC Endpoints (below).
resource "aws_security_group" "vpce" {
  name_prefix = "${local.name_prefix}-vpce-"
  description = "Allow HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags       = { Name = "${local.name_prefix}-sg-vpce" }
  lifecycle { create_before_destroy = true }
}

# === NETWORK ACL for private subnets (stateless, subnet-level backstop) ===
# Defense in depth. SGs are your main control; this NACL blocks inbound SSH/RDP
# from anywhere as a coarse extra layer. Stateless = you must allow return
# traffic on ephemeral ports explicitly.
resource "aws_network_acl" "private" {
  vpc_id = aws_vpc.this.id
  subnet_ids = concat(
    [for s in aws_subnet.private_small : s.id],
    [for s in aws_subnet.private_medium : s.id],
    [for s in aws_subnet.private_large : s.id],
  )
  tags = { Name = "${local.name_prefix}-nacl-private" }
}

resource "aws_network_acl_rule" "private_in_vpc" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
}

resource "aws_network_acl_rule" "private_in_ephemeral" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_out_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# === VPC ENDPOINTS (keep S3 / SQS / SNS traffic off the public internet) ==

# Gateway endpoint for S3 (free). Adds an S3 route to private route tables.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]
  tags              = { Name = "${local.name_prefix}-vpce-s3" }
}

# Interface endpoints for SQS and SNS so messaging stays private.
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.sqs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = [for s in aws_subnet.private_small : s.id]
  tags                = { Name = "${local.name_prefix}-vpce-sqs" }
}

resource "aws_vpc_endpoint" "sns" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.sns"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = [for s in aws_subnet.private_small : s.id]
  tags                = { Name = "${local.name_prefix}-vpce-sns" }
}

# === VPC FLOW LOGS (visibility/audit) =====================================
resource "aws_cloudwatch_log_group" "flow" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/vpc/flowlogs/${local.name_prefix}"
  retention_in_days = 90
}

data "aws_iam_policy_document" "flow_assume" {
  count = var.enable_flow_logs ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  count              = var.enable_flow_logs ? 1 : 0
  name_prefix        = "${local.name_prefix}-flow-"
  assume_role_policy = data.aws_iam_policy_document.flow_assume[0].json
}

data "aws_iam_policy_document" "flow_perms" {
  count = var.enable_flow_logs ? 1 : 0
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  count  = var.enable_flow_logs ? 1 : 0
  role   = aws_iam_role.flow[0].id
  policy = data.aws_iam_policy_document.flow_perms[0].json
}

resource "aws_flow_log" "this" {
  count           = var.enable_flow_logs ? 1 : 0
  iam_role_arn    = aws_iam_role.flow[0].arn
  log_destination = aws_cloudwatch_log_group.flow[0].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.this.id
  tags            = { Name = "${local.name_prefix}-flowlog" }
}
