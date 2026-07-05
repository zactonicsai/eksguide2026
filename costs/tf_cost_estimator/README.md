# tf_cost_estimator

A small, dependency-free Python script that reads a Terraform file (or a
folder of `.tf` files), finds the AWS resources in it, and writes a
Markdown report estimating the monthly cost of each one.

## Usage

```bash
python3 tf_cost_estimator.py main.tf
python3 tf_cost_estimator.py ./my-terraform-project/
python3 tf_cost_estimator.py main.tf -o cost_report.md
```

By default the report is written next to the input as `<name>_cost_report.md`.

## What it prices

Reads flat, always-on charges for: `aws_instance` (EC2), `aws_lb`/`aws_alb`
(ALB/NLB/GWLB/CLB), `aws_nat_gateway`, `aws_vpc_endpoint`, `aws_eip`,
`aws_ebs_volume`, `aws_db_instance` (RDS).

Resources that are always free (subnets, route tables, security groups, IAM
roles, target groups, listeners, etc.) are listed separately with $0.
Usage-billed services (S3, DynamoDB, SQS, Lambda, CloudWatch Logs) are
listed but not priced, since their cost depends entirely on traffic/usage.
Anything else is listed under "Unrecognized Resource Types."

## Pricing data

Prices live in `pricing_data.json` next to the script — a hand-maintained,
dated snapshot of **US East (N. Virginia) On-Demand Linux** list prices.
AWS pricing changes over time and by region, so:

- Update the numbers in `pricing_data.json` periodically.
- Add new instance types / resource types to that file as needed.
- For anything budget-critical, double check with the
  [AWS Pricing Calculator](https://calculator.aws).

## Known limitations

- This is a lightweight regex/brace-counting reader, not a full HCL parser.
  It handles typical, reasonably-formatted Terraform well, but unusual
  formatting or deeply dynamic expressions (complex `for_each`, computed
  values, modules) may not resolve correctly — these are flagged with a
  ⚠️ in the report rather than silently guessed.
- Only variables with a literal `default` are resolved.
- No usage-based costs are modeled (data transfer, LCUs, request counts,
  storage growth, etc.) — only flat hourly/monthly charges.
- Only `us-east-1` pricing is bundled today.
