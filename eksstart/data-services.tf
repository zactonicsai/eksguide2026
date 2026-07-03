# data-services.tf
# ===========================================================================
# SELF-HOSTED data services on EC2. We run Kafka, Postgres, and OpenSearch
# ourselves (not MSK / RDS / OpenSearch Service) so we own every config knob:
# server.properties, postgresql.conf, opensearch.yml, JVM flags, versions,
# patch cadence. NiFi is self-hosted by nature. SNS and SQS are AWS-native
# (you can't self-host them) and are reached privately via the VPC endpoints
# defined in security.tf - no traffic crosses the public internet.
#
# WHY SELF-HOST (pros): total config control, any version/plugin, no managed
#   feature gaps, portable across clouds, often cheaper at steady high load.
# WHY IT COSTS YOU (cons): you own patching, backups, failover, scaling,
#   monitoring, and on-call. Managed services trade money for that toil.
#
# Everything here is gated on var.enable_example_workloads.
# ===========================================================================

# Latest Amazon Linux 2023 AMI (no hard-coded AMI IDs that rot over time).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  # Ordered subnet ID lists so count.index maps to an AZ deterministically.
  large_subnet_ids  = [for az in local.azs : aws_subnet.private_large[az].id]
  medium_subnet_ids = [for az in local.azs : aws_subnet.private_medium[az].id]

  wl = var.enable_example_workloads ? 1 : 0
}

# ---------------------------------------------------------------------------
# IAM: instances use SSM Session Manager (no inbound SSH, no bastion) and need
# ec2:DescribeInstances so each node can discover its cluster peers by tag.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Role for the data nodes (Kafka / Postgres / OpenSearch / NiFi).
resource "aws_iam_role" "node" {
  count              = local.wl
  name_prefix        = "${local.name_prefix}-node-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  count      = local.wl
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "discovery" {
  statement {
    sid       = "PeerDiscovery"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"] # DescribeInstances does not support resource-level scoping
  }
}

resource "aws_iam_role_policy" "node_discovery" {
  count  = local.wl
  role   = aws_iam_role.node[0].id
  policy = data.aws_iam_policy_document.discovery.json
}

resource "aws_iam_instance_profile" "node" {
  count       = local.wl
  name_prefix = "${local.name_prefix}-node-"
  role        = aws_iam_role.node[0].name
}

# ---------------------------------------------------------------------------
# SNS topic + SQS queue (+ dead-letter queue). AWS-native, reached privately
# through the SNS/SQS interface endpoints. Classic fan-out: publish once to
# the topic, the queue subscribes, workers poll the queue, failures land in
# the DLQ for inspection instead of being lost.
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "events" {
  count = local.wl
  name  = "${local.name_prefix}-events"
}

resource "aws_sqs_queue" "dlq" {
  count                     = local.wl
  name                      = "${local.name_prefix}-events-dlq"
  message_retention_seconds = 1209600 # 14 days to debug poison messages
}

resource "aws_sqs_queue" "main" {
  count                      = local.wl
  name                       = "${local.name_prefix}-events"
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[0].arn
    maxReceiveCount     = 5 # after 5 failed reads, send to the DLQ
  })
}

resource "aws_sns_topic_subscription" "events_to_sqs" {
  count     = local.wl
  topic_arn = aws_sns_topic.events[0].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main[0].arn
}

# Allow the SNS topic (and only it) to deliver into the queue.
data "aws_iam_policy_document" "queue_policy" {
  count = local.wl
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main[0].arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events[0].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "main" {
  count     = local.wl
  queue_url = aws_sqs_queue.main[0].id
  policy    = data.aws_iam_policy_document.queue_policy[0].json
}

# ---------------------------------------------------------------------------
# Shared bootstrap fragment: mount the dedicated EBS data volume and discover
# cluster peers by tag. Written as $VAR (no braces) so the bash survives
# Terraform's heredoc interpolation; ${var.*} below are Terraform values.
# ---------------------------------------------------------------------------
locals {
  bootstrap_common = <<-BASH
    #!/bin/bash
    set -euxo pipefail
    dnf -y update

    # --- mount the dedicated data volume (second NVMe disk) at /data ---
    DATA_DEV=$(lsblk -dpno NAME,TYPE | awk '$2=="disk" && $1 !~ /nvme0n1/ {print $1; exit}')
    if [ -n "$DATA_DEV" ]; then
      blkid "$DATA_DEV" || mkfs -t xfs "$DATA_DEV"
      mkdir -p /data
      echo "$DATA_DEV /data xfs defaults,nofail 0 2" >> /etc/fstab
      mount -a
    fi

    # --- discover cluster peers by tag (set CLUSTER before sourcing) ---
    TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
    SELF_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
  BASH
}

# ---------------------------------------------------------------------------
# KAFKA brokers (self-hosted, KRaft mode - no ZooKeeper). One per AZ by
# default, in the private-large tier. You control server.properties entirely.
# ---------------------------------------------------------------------------
resource "aws_instance" "kafka" {
  count                  = var.enable_example_workloads ? var.kafka_broker_count : 0
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.kafka_instance_type
  subnet_id              = local.large_subnet_ids[count.index % length(local.large_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.messaging.id]
  iam_instance_profile   = aws_iam_instance_profile.node[0].name
  key_name               = var.ec2_key_name != "" ? var.ec2_key_name : null

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # Dedicated, encrypted log volume that survives instance replacement.
  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.kafka_data_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  user_data = <<-BASH
    ${local.bootstrap_common}
    CLUSTER="${local.name_prefix}-kafka"
    PEERS=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Cluster,Values=$CLUSTER" "Name=instance-state-name,Values=running,pending" \
      --query 'Reservations[].Instances[].PrivateIpAddress' --output text | tr '\t' '\n' | sort)

    dnf -y install java-17-amazon-corretto-headless
    # >>> Install Kafka ${var.kafka_version} here (download the official
    #     binary tarball to /opt/kafka). Self-hosting = your choice of source.
    #
    # Write /data/kafka + a config you own. KRaft needs a quorum of voters;
    # build it from the discovered $PEERS. Example shape:
    #   process.roles=broker,controller
    #   controller.quorum.voters=<id1>@<ip1>:9093,<id2>@<ip2>:9093,...
    #   listeners=PLAINTEXT://$SELF_IP:9092,CONTROLLER://$SELF_IP:9093
    #   log.dirs=/data/kafka
    mkdir -p /data/kafka
    printf 'peers:\n%s\n' "$PEERS" > /data/kafka/CLUSTER_PEERS.txt
  BASH

  tags = {
    Name    = "${local.name_prefix}-kafka-${count.index}"
    Tier    = "private-large"
    Role    = "kafka"
    Cluster = "${local.name_prefix}-kafka"
  }
}

# ---------------------------------------------------------------------------
# POSTGRES (self-hosted). Node 0 is the primary; extra nodes are standbys you
# attach via streaming replication (the data SG already allows 5432 self).
# ---------------------------------------------------------------------------
resource "aws_instance" "postgres" {
  count                  = var.enable_example_workloads ? var.postgres_node_count : 0
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.postgres_instance_type
  subnet_id              = local.large_subnet_ids[count.index % length(local.large_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.data.id]
  iam_instance_profile   = aws_iam_instance_profile.node[0].name
  key_name               = var.ec2_key_name != "" ? var.ec2_key_name : null

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.postgres_data_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  user_data = <<-BASH
    ${local.bootstrap_common}
    ROLE="primary"; [ "${count.index}" -ne 0 ] && ROLE="standby"
    dnf -y install postgresql16-server
    # >>> You own postgresql.conf + pg_hba.conf. Put the data directory on the
    #     mounted volume (/data/pgdata), set listen_addresses, and for standbys
    #     run pg_basebackup against the primary's private IP.
    mkdir -p /data/pgdata && chown -R postgres:postgres /data/pgdata
    echo "this node role: $ROLE" > /data/pgdata/NODE_ROLE.txt
  BASH

  tags = {
    Name    = "${local.name_prefix}-postgres-${count.index}"
    Tier    = "private-large"
    Role    = "postgres"
    Cluster = "${local.name_prefix}-postgres"
  }
}

# ---------------------------------------------------------------------------
# OPENSEARCH (self-hosted). REST on 9200, node-to-node transport on 9300.
# Nodes find each other through the discovered seed-host list.
# ---------------------------------------------------------------------------
resource "aws_instance" "opensearch" {
  count                  = var.enable_example_workloads ? var.opensearch_node_count : 0
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.opensearch_instance_type
  subnet_id              = local.large_subnet_ids[count.index % length(local.large_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.search.id]
  iam_instance_profile   = aws_iam_instance_profile.node[0].name
  key_name               = var.ec2_key_name != "" ? var.ec2_key_name : null

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.opensearch_data_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  user_data = <<-BASH
    ${local.bootstrap_common}
    CLUSTER="${local.name_prefix}-opensearch"
    SEEDS=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Cluster,Values=$CLUSTER" "Name=instance-state-name,Values=running,pending" \
      --query 'Reservations[].Instances[].PrivateIpAddress' --output text | tr '\t' '\n' | sort | paste -sd, -)

    # OpenSearch needs this kernel setting for memory-mapped indices.
    sysctl -w vm.max_map_count=262144
    echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf
    # >>> Install OpenSearch ${var.opensearch_version} here. You own
    #     opensearch.yml. Point path.data at /data, then set:
    #       network.host: $SELF_IP
    #       discovery.seed_hosts: [ $SEEDS ]
    #       cluster.initial_cluster_manager_nodes: [ ... ]
    mkdir -p /data/opensearch
    echo "$SEEDS" > /data/opensearch/SEED_HOSTS.txt
  BASH

  tags = {
    Name    = "${local.name_prefix}-opensearch-${count.index}"
    Tier    = "private-large"
    Role    = "opensearch"
    Cluster = "${local.name_prefix}-opensearch"
  }
}

# ---------------------------------------------------------------------------
# NIFI (self-hosted dataflow). Lives in the private-medium tier. Moves data
# between Kafka, Postgres, OpenSearch, S3, SQS/SNS, and external systems.
# ---------------------------------------------------------------------------
resource "aws_instance" "nifi" {
  count                  = var.enable_example_workloads ? var.nifi_node_count : 0
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.nifi_instance_type
  subnet_id              = local.medium_subnet_ids[count.index % length(local.medium_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.nifi.id]
  iam_instance_profile   = aws_iam_instance_profile.node[0].name
  key_name               = var.ec2_key_name != "" ? var.ec2_key_name : null

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.nifi_data_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  user_data = <<-BASH
    ${local.bootstrap_common}
    CLUSTER="${local.name_prefix}-nifi"
    PEERS=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Cluster,Values=$CLUSTER" "Name=instance-state-name,Values=running,pending" \
      --query 'Reservations[].Instances[].PrivateIpAddress' --output text | tr '\t' '\n' | sort)

    dnf -y install java-21-amazon-corretto-headless
    # >>> Install NiFi ${var.nifi_version} here. You own nifi.properties.
    #     For a cluster set nifi.cluster.is.node=true, point the repositories
    #     at /data, and configure the embedded/ external ZooKeeper or the
    #     built-in cluster coordinator using the discovered $PEERS.
    mkdir -p /data/nifi
    printf 'peers:\n%s\n' "$PEERS" > /data/nifi/CLUSTER_PEERS.txt
  BASH

  tags = {
    Name    = "${local.name_prefix}-nifi-${count.index}"
    Tier    = "private-medium"
    Role    = "nifi"
    Cluster = "${local.name_prefix}-nifi"
  }
}
