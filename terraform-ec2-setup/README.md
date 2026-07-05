I reviewed your README. It's well written, but it's now **out of date** compared to your Terraform code.

Here are the major updates I'd make:

* ✅ Add the **IAM Role**, **IAM Instance Profile**, and **AmazonSSMManagedInstanceCore** policy sections.
* ✅ Explain **SSM Session Manager** and why it replaces SSH in many cases.
* ✅ Explain the **Default VPC** and **Default Subnet** lookup using Terraform data sources.
* ✅ Explain **AWS CLI verification commands** after deployment.
* ✅ Add a troubleshooting section for the most common SSM errors (like the one you encountered).
* ✅ Add a complete architecture diagram.
* ✅ Expand the project structure to include the new AWS resources.
* ✅ Add a Terraform lifecycle explanation (init → validate → fmt → plan → apply → destroy).

I would also update the project structure to something like:

```text
terraform-ec2-setup/
├── providers.tf
├── variables.tf
├── main.tf
├── outputs.tf
├── terraform.tfstate
├── terraform.tfstate.backup
└── README.md
```

Instead of saying the project creates only an EC2 instance, it now creates:

```text
Terraform
      │
      ▼
AWS
├── Default VPC (looked up)
├── Default Subnet (looked up)
├── IAM Role
├── IAM Instance Profile
├── AmazonSSMManagedInstanceCore Policy
└── EC2 Instance
        │
        ▼
 Amazon Linux 2023
        │
        ▼
 Systems Manager (SSM)
        │
        ▼
 Session Manager
```

I'd add a new section explaining the SSM resources:

| Resource                     | Purpose                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------- |
| IAM Role                     | Gives the EC2 instance permission to call AWS APIs.                              |
| IAM Instance Profile         | Attaches the IAM role to the EC2 instance.                                       |
| AmazonSSMManagedInstanceCore | AWS-managed policy that allows the SSM Agent to register with Systems Manager.   |
| SSM Agent                    | Software running inside Amazon Linux that communicates with AWS Systems Manager. |

I would also expand the `main.tf` walkthrough to explain the new resources:

* `data "aws_vpc" "default"` — looks up the existing default VPC instead of creating one.
* `data "aws_subnets" "default"` — finds the available subnets in that VPC.
* `aws_iam_role` — creates an IAM role for the EC2 instance.
* `aws_iam_role_policy_attachment` — attaches the `AmazonSSMManagedInstanceCore` managed policy.
* `aws_iam_instance_profile` — packages the IAM role so it can be attached to an EC2 instance.
* `iam_instance_profile = ...` — connects the instance profile to the EC2 instance so the SSM Agent can obtain temporary credentials.

I'd add a post-deployment verification section like this:

```bash
terraform output

aws ec2 describe-instances

aws iam get-role --role-name EC2SSMRole

aws iam get-instance-profile --instance-profile-name EC2SSMProfile

aws ssm describe-instance-information

aws ssm start-session --target <INSTANCE_ID>
```

Each command should include a short explanation of what it verifies and what successful output looks like.

Finally, I'd add an SSM troubleshooting section covering the most common issues:

| Error                                | Cause                     | Fix                                                                             |
| ------------------------------------ | ------------------------- | ------------------------------------------------------------------------------- |
| No subnets found                     | Default subnet deleted    | Recreate the subnet or create a VPC in Terraform.                               |
| IAM instance profile is not attached | EC2 has no IAM role       | Attach an instance profile with `AmazonSSMManagedInstanceCore`.                 |
| Ping status: Offline                 | SSM Agent can't reach AWS | Verify internet access or VPC endpoints.                                        |
| Agent unable to acquire credentials  | Missing IAM role          | Attach the IAM instance profile and restart or recreate the instance if needed. |
| AccessDeniedException                | Incorrect IAM permissions | Ensure the correct AWS-managed policy is attached.                              |

One enhancement I'd strongly recommend is adding an appendix with **25–30 AWS CLI commands** (like the ones we created earlier) and explaining what each command does, what resources it queries, and what successful output should look like. That would turn the README into both a learning guide and an operational reference.
