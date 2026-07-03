# variables.tf
# All tunable inputs live here. Change values in terraform.tfvars, not in code.

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project/system name used in resource names and tags."
  type        = string
  default     = "platform"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = <<-EOT
    Primary IPv4 CIDR for the VPC. /16 gives 65,536 addresses and leaves
    plenty of room to grow. Must be inside an RFC 1918 private range
    (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16). Avoid 172.17.0.0/16 because
    some AWS services (Cloud9, SageMaker, Docker) use it internally.
  EOT
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR (e.g. 10.0.0.0/16)."
  }
}

variable "az_count" {
  description = <<-EOT
    Number of Availability Zones to spread subnets across. 3 is the standard
    for production high availability. 2 is acceptable for cost-sensitive dev.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    true  = one NAT Gateway shared by all AZs (cheaper, but a single AZ
            failure removes outbound internet for private subnets).
    false = one NAT Gateway per AZ (resilient, recommended for prod, costs
            roughly one NAT hourly + data charge per AZ).
  EOT
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Capture VPC Flow Logs to CloudWatch for security/audit visibility."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# WORKLOAD STACK (self-hosted data services + public ALB + app/API tier)
# Everything below is gated on enable_example_workloads so the base VPC can
# be applied on its own. Flip to true to stand up the reference architecture:
#   internet -> ALB (public) -> app/API (private-medium)
#            -> Kafka / Postgres / OpenSearch (private-large, self-hosted EC2)
#            -> NiFi (private-medium, self-hosted EC2)
#            -> SNS / SQS (AWS-native, reached via VPC endpoints)
# ---------------------------------------------------------------------------

variable "enable_example_workloads" {
  description = <<-EOT
    Create the full example stack (ALB, app/API, and self-hosted Kafka,
    Postgres, OpenSearch, NiFi, plus SNS/SQS). EC2 + EBS + ALB cost real money,
    so this defaults to false. The base VPC applies with this off.
  EOT
  type        = bool
  default     = false
}

variable "allowed_web_cidrs" {
  description = <<-EOT
    "Limited public web": the only source ranges allowed to reach the public
    ALB on 80/443. Default is the whole internet; in production narrow this to
    your office/CDN/WAF ranges so the public surface is as small as possible.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of an ACM certificate for HTTPS on the ALB. If empty, the module
    creates an HTTP:80 listener only (fine for a demo; add a cert + 443 for
    production). Example: arn:aws:acm:us-east-1:123456789012:certificate/abc...
  EOT
  type        = string
  default     = ""
}

variable "ec2_key_name" {
  description = "Optional EC2 key pair name for SSH. Leave empty to rely on SSM Session Manager (recommended, no inbound SSH)."
  type        = string
  default     = ""
}

# --- instance sizing (override in terraform.tfvars to fit your workload) ---
variable "app_instance_type"        { type = string  default = "t3.medium" }
variable "kafka_instance_type"      { type = string  default = "m6i.large" }
variable "postgres_instance_type"   { type = string  default = "r6i.large" }
variable "opensearch_instance_type" { type = string  default = "r6i.large" }
variable "nifi_instance_type"       { type = string  default = "m6i.large" }

# --- node counts (clustered services default to one node per AZ) ---
variable "app_node_count"        { type = number  default = 2 }
variable "kafka_broker_count"    { type = number  default = 3 }
variable "postgres_node_count"   { type = number  default = 1 }
variable "opensearch_node_count" { type = number  default = 3 }
variable "nifi_node_count"       { type = number  default = 3 }

# --- dedicated data-volume sizes in GiB (separate from the OS disk) ---
variable "kafka_data_gb"      { type = number  default = 200 }
variable "postgres_data_gb"   { type = number  default = 200 }
variable "opensearch_data_gb" { type = number  default = 200 }
variable "nifi_data_gb"       { type = number  default = 100 }

# --- software versions you control (self-hosted = you pick the version) ---
variable "kafka_version"      { type = string  default = "3.9.0" }
variable "opensearch_version" { type = string  default = "2.17.1" }
variable "nifi_version"       { type = string  default = "2.0.0" }
