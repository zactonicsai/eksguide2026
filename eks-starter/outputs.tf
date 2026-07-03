# outputs.tf
# Values you'll feed into other modules (compute, RDS, MSK, OpenSearch, etc.).

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Primary CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (load balancers, NAT)."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_small_subnet_ids" {
  description = "Small private subnet IDs (small services, SNS/SQS endpoints)."
  value       = [for s in aws_subnet.private_small : s.id]
}

output "private_medium_subnet_ids" {
  description = "Medium private subnet IDs (Java/Node apps, APIs, NiFi)."
  value       = [for s in aws_subnet.private_medium : s.id]
}

output "private_large_subnet_ids" {
  description = "Large private subnet IDs (Kafka, Postgres, OpenSearch)."
  value       = [for s in aws_subnet.private_large : s.id]
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs."
  value       = [for n in aws_nat_gateway.this : n.id]
}

output "security_group_ids" {
  description = "Map of tier -> security group ID."
  value = {
    alb       = aws_security_group.alb.id
    app       = aws_security_group.app.id
    data      = aws_security_group.data.id
    messaging = aws_security_group.messaging.id
    search    = aws_security_group.search.id
  }
}

# --- workload stack outputs (null/empty when enable_example_workloads=false) ---

output "alb_dns_name" {
  description = "Public DNS name of the ALB - the internet entry point."
  value       = var.enable_example_workloads ? aws_lb.web[0].dns_name : null
}

output "app_instance_ids" {
  description = "App/API instance IDs (private-medium)."
  value       = aws_instance.app[*].id
}

output "kafka_broker_private_ips" {
  description = "Self-hosted Kafka broker private IPs (private-large)."
  value       = aws_instance.kafka[*].private_ip
}

output "postgres_private_ips" {
  description = "Self-hosted Postgres node private IPs (node 0 = primary)."
  value       = aws_instance.postgres[*].private_ip
}

output "opensearch_private_ips" {
  description = "Self-hosted OpenSearch node private IPs (private-large)."
  value       = aws_instance.opensearch[*].private_ip
}

output "nifi_private_ips" {
  description = "Self-hosted NiFi node private IPs (private-medium)."
  value       = aws_instance.nifi[*].private_ip
}

output "sns_topic_arn" {
  description = "ARN of the events SNS topic."
  value       = var.enable_example_workloads ? aws_sns_topic.events[0].arn : null
}

output "sqs_queue_url" {
  description = "URL of the main SQS queue."
  value       = var.enable_example_workloads ? aws_sqs_queue.main[0].id : null
}

output "sqs_dlq_url" {
  description = "URL of the dead-letter queue."
  value       = var.enable_example_workloads ? aws_sqs_queue.dlq[0].id : null
}
