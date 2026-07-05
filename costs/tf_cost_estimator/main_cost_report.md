# Terraform AWS Cost Estimate

**Source:** `main.tf`  
**Generated:** 2026-07-05 20:46 UTC  
**Pricing basis:** us-east-1 (Linux, On-Demand), snapshot dated 2026-07-05

## Summary

| Metric | Value |
|---|---|
| **Estimated recurring monthly cost** | **$38.33** |
| Resources priced | 5 |
| Resources needing attention (unknown type/size) | 1 |
| Free / $0 resources | 14 |
| Usage-based (not estimated) | 0 |
| Unrecognized resource types | 0 |

> Total excludes all usage-based charges (data transfer, LCUs, requests, storage growth, etc). See **Assumptions & Caveats** below.

## Cost Breakdown

| Resource | Qty | Unit $/mo | Total $/mo | Notes |
|---|---|---|---|---|
| `aws_lb.app_lb` | 1 | $16.43 | $16.43 | application load balancer, base hourly charge only; usage-based LCU charges (~$0.008/hr per unit, traffic-dependent) not included |
| `aws_vpc_endpoint.ssm` | 1 | $7.30 | $7.30 | interface endpoint; +$0.01/GB processed (traffic-dependent) not included |
| `aws_vpc_endpoint.ssmmessages` | 1 | $7.30 | $7.30 | interface endpoint; +$0.01/GB processed (traffic-dependent) not included |
| `aws_vpc_endpoint.ec2messages` | 1 | $7.30 | $7.30 | interface endpoint; +$0.01/GB processed (traffic-dependent) not included |
| `aws_vpc_endpoint.s3` | 1 | $0.00 | $0.00 | Gateway endpoint (S3/DynamoDB only) - always free |
| `aws_instance.web_server` | 1 | — | — | ⚠️ could not resolve `count = var.instance_count`, assumed 1; unknown instance_type 'None' - add it to pricing_data.json |

## Free / No Direct Cost

- `aws_subnet.internal_a`
- `aws_subnet.internal_b`
- `aws_route_table.internal`
- `aws_route_table_association.internal_a`
- `aws_route_table_association.internal_b`
- `aws_iam_role.ec2_ssm_role`
- `aws_iam_role_policy_attachment.ssm`
- `aws_iam_instance_profile.ec2_profile`
- `aws_security_group.alb_sg`
- `aws_security_group.web_sg`
- `aws_security_group.ssm_endpoint_sg`
- `aws_lb_target_group.app_tg`
- `aws_lb_target_group_attachment.app_tg_attach`
- `aws_lb_listener.http`

## Assumptions & Caveats

- Prices are a hand-maintained snapshot for **us-east-1**, dated 2026-07-05. AWS prices change; re-verify anything budget-critical at https://calculator.aws
- Only flat, always-on charges are estimated (instance-hours, load-balancer-hours, NAT gateway-hours, provisioned storage). Traffic-driven charges (data transfer, LCUs/NLCUs, requests, S3 storage growth) are **not** included.
- AWS Free Tier credits are not applied.
- Only On-Demand pricing is used; Reserved Instances, Savings Plans, and Spot are not modeled.
- `count`/`for_each` are resolved only when they're a literal number or a `var.x` with a literal default; anything more dynamic is assumed to be 1 (flagged in the notes).
- This is a lightweight, regex-based reader, not a full HCL parser - unusual formatting or heavily nested expressions may be missed.
