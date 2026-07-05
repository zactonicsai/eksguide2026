output "instance_ids" {
  description = "IDs of the EC2 instances"
  value       = aws_instance.web_server[*].id
}

output "instance_private_ips" {
  description = "Private IPs of the EC2 instances (no public IPs are assigned)"
  value       = aws_instance.web_server[*].private_ip
}

output "ssm_role" {
  value = aws_iam_role.ec2_ssm_role.name
}

output "alb_dns_name" {
  description = "Internal DNS name of the load balancer (reachable only from inside the VPC)"
  value       = aws_lb.app_lb.dns_name
}

output "target_group_arn" {
  value = aws_lb_target_group.app_tg.arn
}

output "internal_subnet_ids" {
  description = "IDs of the two dedicated, fully-internal subnets (no IGW/NAT route)"
  value       = [aws_subnet.internal_a.id, aws_subnet.internal_b.id]
}
