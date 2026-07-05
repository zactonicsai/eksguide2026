Below is a useful set of AWS CLI commands to inspect **everything** Terraform created for your EC2 + SSM setup. Run these in order to verify each component.

> **Tip:** First export your AWS Region so you don't have to specify it on every command.

```bash
export AWS_REGION=us-east-1
```

---

# 1. Verify your AWS identity

Shows the account and IAM identity you're using.

```bash
aws sts get-caller-identity
```

Example output:

```json
{
  "UserId": "...",
  "Account": "123456789012",
  "Arn": "arn:aws:iam::123456789012:user/admin"
}
```

---

# 2. List all EC2 instances

```bash
aws ec2 describe-instances \
  --query "Reservations[].Instances[].[
      InstanceId,
      State.Name,
      InstanceType,
      PublicIpAddress,
      PrivateIpAddress,
      VpcId,
      SubnetId
  ]" \
  --output table
```

Shows:

* Instance ID
* Running state
* Public IP
* Private IP
* VPC
* Subnet

---

# 3. Describe one instance in detail

Replace the instance ID.

```bash
aws ec2 describe-instances \
  --instance-ids i-xxxxxxxxxxxxxxxxx
```

Shows everything about the instance.

---

# 4. Check the IAM Instance Profile attached

```bash
aws ec2 describe-instances \
  --instance-ids i-xxxxxxxxxxxxxxxxx \
  --query "Reservations[0].Instances[0].IamInstanceProfile"
```

Expected:

```json
{
  "Arn": "arn:aws:iam::123456789012:instance-profile/EC2SSMProfile",
  "Id": "..."
}
```

If you get:

```text
null
```

No IAM profile is attached.

---

# 5. List IAM Roles

```bash
aws iam list-roles
```

---

# 6. Show the SSM role

```bash
aws iam get-role \
  --role-name EC2SSMRole
```

Shows:

* Trust policy
* ARN
* Role ID
* Creation date

---

# 7. List policies attached to the role

```bash
aws iam list-attached-role-policies \
  --role-name EC2SSMRole
```

Expected:

```text
AmazonSSMManagedInstanceCore
```

---

# 8. Show the instance profile

```bash
aws iam get-instance-profile \
  --instance-profile-name EC2SSMProfile
```

Shows:

* Profile ARN
* Attached role
* Creation date

---

# 9. List all instance profiles

```bash
aws iam list-instance-profiles
```

---

# 10. Show the default VPC

```bash
aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true
```

Shows:

* CIDR
* VPC ID
* DNS support
* DNS hostnames

---

# 11. List subnets

```bash
aws ec2 describe-subnets \
  --query "Subnets[].[
      SubnetId,
      AvailabilityZone,
      CidrBlock,
      VpcId
  ]" \
  --output table
```

---

# 12. Show route tables

```bash
aws ec2 describe-route-tables
```

Look for:

```
0.0.0.0/0
```

pointing to:

```
igw-xxxxxxxx
```

---

# 13. List Internet Gateways

```bash
aws ec2 describe-internet-gateways
```

---

# 14. Show Security Groups

```bash
aws ec2 describe-security-groups
```

---

# 15. Show only your instance security groups

```bash
aws ec2 describe-instances \
  --instance-ids i-xxxxxxxx \
  --query "Reservations[0].Instances[0].SecurityGroups"
```

---

# 16. Verify the SSM Agent is online

```bash
aws ssm describe-instance-information
```

Expected:

```
PingStatus = Online
```

---

# 17. Show only Ping Status

```bash
aws ssm describe-instance-information \
  --query "InstanceInformationList[].[
      InstanceId,
      PingStatus,
      PlatformName,
      AgentVersion
  ]" \
  --output table
```

---

# 18. Start an SSM Session

```bash
aws ssm start-session \
  --target i-xxxxxxxxxxxxxxxx
```

If SSM is configured correctly, you'll get a shell on the instance.

---

# 19. Wait until the EC2 instance is running

```bash
aws ec2 wait instance-running \
  --instance-ids i-xxxxxxxxxxxxxxxx
```

---

# 20. Wait until EC2 passes all health checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids i-xxxxxxxxxxxxxxxx
```

---

# 21. Show the latest Amazon Linux AMIs

```bash
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*" \
  --query "Images[].[
      ImageId,
      Name
  ]" \
  --output table
```

---

# 22. Show your public IP

```bash
aws ec2 describe-instances \
  --instance-ids i-xxxxxxxx \
  --query "Reservations[0].Instances[0].PublicIpAddress"
```

---

# 23. Show all EC2 tags

```bash
aws ec2 describe-tags
```

---

# 24. List all VPCs

```bash
aws ec2 describe-vpcs
```

---

# 25. List all IAM policies

```bash
aws iam list-policies --scope AWS
```

---

# 26. View the Terraform state

```bash
terraform state list
```

This shows every resource Terraform manages, for example:

```text
aws_iam_instance_profile.ec2_profile
aws_iam_role.ec2_ssm_role
aws_iam_role_policy_attachment.ssm
aws_instance.web_server
```

---

# 27. Inspect one Terraform-managed resource

```bash
terraform state show aws_instance.web_server
```

or:

```bash
terraform state show aws_iam_role.ec2_ssm_role
```

This displays all attributes Terraform knows about the resource.

---

# 28. Show Terraform outputs

```bash
terraform output
```

Or retrieve a single output:

```bash
terraform output instance_id
terraform output public_ip
```

---

## Quick health check sequence

Run these commands after `terraform apply`:

```bash
terraform output

aws ec2 describe-instances

aws iam get-role --role-name EC2SSMRole

aws iam get-instance-profile --instance-profile-name EC2SSMProfile

aws ssm describe-instance-information

aws ssm start-session --target <INSTANCE_ID>
```

If any step fails, the error usually points directly to the missing piece (IAM role, instance profile, networking, or SSM registration).
