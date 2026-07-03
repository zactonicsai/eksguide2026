# AWS VPC Terraform Module

A production-ready VPC with public subnets and **three sizes** of private subnets
(small / medium / large), spread across multiple Availability Zones for high
availability. Includes NAT gateways, per-AZ route tables, security groups,
network ACLs, VPC endpoints (S3 / SQS / SNS), and optional VPC Flow Logs.

Designed to host a typical platform stack: load balancers in public subnets;
web/API apps and NiFi in the medium tier; Kafka, Postgres, and OpenSearch in
the large tier; and SNS/SQS endpoints in the small tier.

---

## What gets created

| Resource | Purpose |
|---|---|
| 1 VPC (`10.0.0.0/16` by default) | The private network boundary |
| Public subnets (one per AZ) | Internet-facing load balancers, NAT gateways |
| Private **small** subnets (`/26`) | Small services, SNS/SQS interface endpoints |
| Private **medium** subnets (`/24`) | Java/Node web apps, backend APIs, NiFi |
| Private **large** subnets (`/22`) | Kafka, Postgres, OpenSearch |
| Internet Gateway | Outbound/inbound path for public subnets |
| NAT Gateway(s) | Outbound-only internet for private subnets |
| Route tables (1 public + 1 private per AZ) | Per-AZ isolation for failover |
| Security groups | `alb`, `app`, `data`, `messaging`, `search`, `nifi` tiers |
| Network ACL | Subnet-level backstop on private subnets |
| VPC endpoints | S3 (gateway), SQS + SNS (interface) |
| VPC Flow Logs → CloudWatch | Security/audit visibility (optional) |

**Optional workload stack** (only when `enable_example_workloads = true`):

| Resource | Purpose |
|---|---|
| Self-hosted **Kafka** on EC2 (KRaft) | Streaming backbone, private-large, dedicated EBS |
| Self-hosted **PostgreSQL** on EC2 | System of record, private-large, streaming replication |
| Self-hosted **OpenSearch** on EC2 | Search/analytics, private-large, 9200 REST / 9300 transport |
| Self-hosted **NiFi** on EC2 | Dataflow/ETL, private-medium, UI on 8443 |
| **SNS** topic + **SQS** queue + DLQ | AWS-native messaging, reached via VPC endpoints |
| Public **ALB** + listeners | The only internet entry point (allow-listed ranges) |
| **App/API** EC2 tier | Stateless Java/Node behind the ALB |
| IAM roles + instance profiles | SSM access, peer discovery, scoped SNS/SQS perms |

**CIDR layout** (within `10.0.0.0/16`):

```
10.0.0.0/20   -> public        (carved into /24 per AZ)
10.0.16.0/20  -> private-small (carved into /26 per AZ)
10.0.32.0/20  -> private-medium(carved into /24 per AZ)
10.0.48.0/20  -> private-large (carved into /22 per AZ)
10.0.64.0/18  -> RESERVED for future growth
```

---

## Prerequisites

1. **Terraform >= 1.9.0** — check with `terraform version`.
   Install: <https://developer.hashicorp.com/terraform/install>
2. **AWS account + credentials** configured locally. Any one of:
   - `aws configure` (AWS CLI), or
   - environment variables:
     ```bash
     export AWS_ACCESS_KEY_ID="..."
     export AWS_SECRET_ACCESS_KEY="..."
     export AWS_DEFAULT_REGION="us-east-1"
     ```
   - an IAM role / SSO profile: `export AWS_PROFILE="my-profile"`
3. **IAM permissions** to create VPC, EC2 networking, NAT/EIP, CloudWatch Logs,
   and IAM roles (for flow logs). An admin or network-admin policy covers this.
   The optional workload stack (`enable_example_workloads = true`) additionally
   needs permission to create EC2 instances + EBS volumes, ELB/ALB, SNS, SQS, and
   IAM roles/instance profiles.

> **Two-phase tip:** the base network applies cleanly with `enable_example_workloads = false`.
> Stand up the network first, confirm it, then flip the flag to add the self-hosted
> data services and the public app edge. The data stores cost real money (EC2 + EBS + ALB),
> so leave the flag off until you need them.

---

## Files

| File | What it holds |
|---|---|
| `versions.tf` | Terraform & AWS provider version pins, provider + default tags, (commented) S3 remote-state backend |
| `variables.tf` | All tunable inputs, including the optional workload-stack toggles |
| `main.tf` | VPC, subnets, IGW, NAT, route tables |
| `security.tf` | Security groups (incl. `nifi`), NACLs, VPC endpoints, flow logs |
| `data-services.tf` | Self-hosted Kafka, Postgres, OpenSearch, NiFi on EC2, plus SNS/SQS and shared IAM/AMI (gated) |
| `app-and-alb.tf` | Public ALB + app/API tier that bridges the web to the backends (gated) |
| `outputs.tf` | Values to feed into other stacks |
| `terraform.tfvars.example` | Sample input values — copy this |
| `README.md` | This file |

---

## Setup & deploy

From inside the `terraform/` directory:

```bash
# 1. Create your own variable file from the example
cp terraform.tfvars.example terraform.tfvars
#    then edit terraform.tfvars to taste (region, names, AZ count, etc.)

# 2. Download the AWS provider and initialize the working directory
terraform init

# 3. Check formatting & internal validity (catches typos before any API calls)
terraform fmt
terraform validate

# 4. Preview exactly what will be created — read this carefully
terraform plan

# 5. Create the infrastructure (asks for confirmation; type "yes")
terraform apply
```

`apply` typically takes a few minutes (NAT gateways are the slow part).

---

## Configuration

Set these in `terraform.tfvars`:

| Variable | Type | Default | Notes |
|---|---|---|---|
| `aws_region` | string | `us-east-1` | Region to deploy into |
| `project_name` | string | `platform` | Used in resource names and tags |
| `environment` | string | `prod` | `dev` / `staging` / `prod` |
| `vpc_cidr` | string | `10.0.0.0/16` | Must be RFC 1918; avoid `172.17.0.0/16` |
| `az_count` | number | `3` | Between 2 and 4; 3 is the prod standard |
| `single_nat_gateway` | bool | `false` | `true` = one shared NAT (cheaper, less resilient); `false` = one NAT per AZ (prod) |
| `enable_flow_logs` | bool | `true` | Send VPC Flow Logs to CloudWatch |
| `enable_example_workloads` | bool | `false` | Create the self-hosted data services + ALB + app/API tier |
| `allowed_web_cidrs` | list(string) | `["0.0.0.0/0"]` | "Limited public web": ranges allowed to reach the ALB. Narrow this for prod |
| `acm_certificate_arn` | string | `""` | ACM cert for HTTPS on the ALB; empty = HTTP-only demo listener |
| `ec2_key_name` | string | `""` | Optional SSH key; empty relies on SSM Session Manager (recommended) |
| `*_instance_type` / `*_node_count` / `*_data_gb` | various | sensible defaults | Per-service sizing for app, kafka, postgres, opensearch, nifi |
| `kafka_version` / `opensearch_version` / `nifi_version` | string | current | The versions you self-host (your call) |

**Cost tip:** for a dev/test environment, set `single_nat_gateway = true` and
`az_count = 2` to cut the largest recurring charge (NAT gateways are billed per
hour **and** per GB processed). Keep `enable_example_workloads = false` until you
need the data stores — EC2 + EBS + ALB are the next-largest charges.

**Self-hosted bootstrap:** the EC2 `user_data` scripts mount the data volume and
discover cluster peers by tag, then leave the actual package install + config as
clearly-marked starting points — because the whole point of self-hosting is that
*you* own `server.properties`, `postgresql.conf`, `opensearch.yml`, and
`nifi.properties`. Reach the internal-only UIs (NiFi, OpenSearch) via
`aws ssm start-session ... AWS-StartPortForwardingSession` — no bastion, no inbound SSH.

---

## Using the outputs

After `apply`, view results:

```bash
terraform output                       # all outputs
terraform output vpc_id                # one value
terraform output -json security_group_ids
```

Available outputs: `vpc_id`, `vpc_cidr`, `public_subnet_ids`,
`private_small_subnet_ids`, `private_medium_subnet_ids`,
`private_large_subnet_ids`, `nat_gateway_ids`, and `security_group_ids`
(a map of `alb` / `app` / `data` / `messaging` / `search` → SG ID).

Reference them from another stack via `terraform_remote_state`, or pass the IDs
into your compute / RDS / MSK / OpenSearch modules.

---

## Remote state (recommended for teams)

Local state (the default) is fine for one person experimenting. For a team,
store state in S3 with locking so two people can't apply at once:

1. Create an S3 bucket and a DynamoDB lock table (one-time, out of band).
2. Uncomment the `backend "s3"` block in `versions.tf` and fill in your values.
3. Re-run `terraform init` (it will offer to migrate existing state).

---

## Tear down

To delete everything this module created:

```bash
terraform destroy
```

This stops all associated charges (NAT, EIPs, flow-log storage). Type `yes` to
confirm. **Irreversible** — anything running in these subnets goes away with it.

---

## Troubleshooting

- **`Error: creating EC2 VPC: VpcLimitExceeded`** — you've hit the default
  5-VPC-per-region soft limit. Delete an unused VPC or request a quota increase.
- **`UnauthorizedOperation` / `AccessDenied`** — your IAM principal is missing a
  permission named in the error. Add it and re-run.
- **CIDR overlap with an existing/peered VPC** — pick a different `vpc_cidr`
  that doesn't collide; you can't change a VPC's primary CIDR after creation.
- **`terraform init` fails downloading the provider** — check network/proxy
  access to `releases.hashicorp.com` and `registry.terraform.io`.

---

## References

- AWS VPC docs: <https://docs.aws.amazon.com/vpc/latest/userguide/>
- Terraform AWS provider: <https://registry.terraform.io/providers/hashicorp/aws/latest/docs>
- VPC subnet sizing & CIDR: <https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html>

See the accompanying `index.html` tutorial for the full background, security
model, AWS CLI equivalents, and workload-placement guidance.
