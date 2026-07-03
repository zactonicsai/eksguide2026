# terraform.tfvars.example
# Copy to terraform.tfvars and edit. Never commit real secrets.

aws_region   = "us-east-1"
project_name = "starterEks"
environment  = "dev"
vpc_cidr     = "10.0.0.0/16"
az_count     = 2

# prod: false (one NAT per AZ, resilient). dev: true (one NAT, cheaper).
single_nat_gateway = false

enable_flow_logs = true

# ---------------------------------------------------------------------------
# Optional workload stack. Leave disabled to deploy just the base network.
# Flip to true to add self-hosted Kafka/Postgres/OpenSearch/NiFi + ALB + app.
# (EC2 + EBS + ALB cost money — keep this off until you need it.)
# ---------------------------------------------------------------------------
enable_example_workloads = false

# "Limited public web": narrow these to your office/CDN/WAF ranges in prod.
# allowed_web_cidrs = ["203.0.113.0/24", "198.51.100.10/32"]

# HTTPS on the ALB (recommended). Empty string => HTTP-only demo listener.
# acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/xxxx"

# Optional SSH key. Leave empty to use SSM Session Manager (no inbound SSH).
# ec2_key_name = "my-keypair"

# --- per-service sizing (uncomment to override the defaults) ---
# app_instance_type        = "t3.medium"
# kafka_instance_type      = "m6i.large"
# postgres_instance_type   = "r6i.large"
# opensearch_instance_type = "r6i.large"
# nifi_instance_type       = "m6i.large"
# app_node_count        = 2
# kafka_broker_count    = 3
# postgres_node_count   = 1
# opensearch_node_count = 3
# nifi_node_count       = 3

# --- versions you self-host ---
# kafka_version      = "3.9.0"
# opensearch_version = "2.17.1"
# nifi_version       = "2.0.0"
