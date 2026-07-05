output "instance_id" {
  value = aws_instance.web_server.id
}

output "public_ip" {
  value = aws_instance.web_server.public_ip
}

output "ssm_role" {
  value = aws_iam_role.ec2_ssm_role.name
}