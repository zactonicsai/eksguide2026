#!/usr/bin/env python3
"""
tf_cost_estimator.py

Reads a Terraform file (or a directory of .tf files), finds the AWS
resources declared in it, and writes a Markdown report estimating the
monthly cost of each one using a bundled AWS pricing snapshot
(pricing_data.json, sitting next to this script).

USAGE
    python3 tf_cost_estimator.py main.tf
    python3 tf_cost_estimator.py ./my-terraform-dir/
    python3 tf_cost_estimator.py main.tf -o cost_report.md

This is a best-effort ESTIMATE, not a bill. It only covers the always-on,
non-usage-based portion of AWS pricing (instance-hours, load balancer
hours, NAT gateway hours, storage, etc). It does NOT model:
  - actual traffic (data transfer, LCUs, request counts, S3 storage growth...)
  - AWS Free Tier credits
  - Reserved Instances / Savings Plans / Spot pricing
  - regions other than us-east-1 (pricing here is US East, N. Virginia)
Always confirm anything budget-critical with https://calculator.aws
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PRICING_FILE = os.path.join(SCRIPT_DIR, "pricing_data.json")

# Resource types that never carry a direct recurring charge on their own.
FREE_RESOURCE_TYPES = {
    "aws_vpc", "aws_subnet", "aws_route_table", "aws_route_table_association",
    "aws_security_group", "aws_security_group_rule", "aws_internet_gateway",
    "aws_iam_role", "aws_iam_role_policy", "aws_iam_role_policy_attachment",
    "aws_iam_instance_profile", "aws_iam_policy", "aws_key_pair",
    "aws_lb_target_group", "aws_lb_target_group_attachment", "aws_lb_listener",
    "aws_lb_listener_rule", "aws_network_acl", "aws_network_acl_rule",
    "aws_default_route_table", "aws_default_security_group",
}

# Resource types with usage-based (not flat) pricing we don't try to model.
USAGE_BASED_RESOURCE_TYPES = {
    "aws_s3_bucket": "Storage + requests + data transfer, all usage-based",
    "aws_cloudwatch_log_group": "Ingestion + storage, usage-based",
    "aws_dynamodb_table": "On-demand/provisioned throughput, usage-based",
    "aws_sqs_queue": "Per-request, usage-based",
    "aws_sns_topic": "Per-request, usage-based",
    "aws_lambda_function": "Per-invocation + duration, usage-based",
}


# --------------------------------------------------------------------------
# Minimal HCL-ish parsing (regex + brace counting - good enough for typical,
# reasonably-formatted Terraform; not a full HCL parser).
# --------------------------------------------------------------------------

HEADER_RE = re.compile(
    r'(?P<kw>resource|data|variable|provider)\s*'
    r'(?:"(?P<l1>[^"]*)")?\s*(?:"(?P<l2>[^"]*)")?\s*\{'
)


def extract_top_level_blocks(text):
    """Find resource/data/variable/provider blocks via brace counting."""
    blocks = []
    for m in HEADER_RE.finditer(text):
        start = m.end() - 1  # index of the opening '{'
        depth = 0
        end = None
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end is None:
            continue
        blocks.append({
            "keyword": m.group("kw"),
            "label1": m.group("l1"),
            "label2": m.group("l2"),
            "body": text[start + 1:end],
        })
    return blocks


def extract_top_level_attrs(body):
    """Grab simple `key = value` pairs that sit at the block's top level
    (i.e. not inside a nested `{ ... }` sub-block)."""
    attrs = {}
    depth = 0
    for line in body.split("\n"):
        stripped = line.strip()
        if depth == 0:
            m = re.match(r'^([a-zA-Z0-9_]+)\s*=\s*(.*)$', stripped)
            if m:
                attrs[m.group(1)] = m.group(2).strip()
        depth += line.count("{") - line.count("}")
    return attrs


def extract_named_subblock(body, block_name):
    """Return the body text of a nested, unlabeled block like
    `root_block_device { ... }`, or None if not present."""
    m = re.search(r'\b' + re.escape(block_name) + r'\s*\{', body)
    if not m:
        return None
    start = m.end() - 1
    depth = 0
    for i in range(start, len(body)):
        if body[i] == "{":
            depth += 1
        elif body[i] == "}":
            depth -= 1
            if depth == 0:
                return body[start + 1:i]
    return None


def literal_value(raw):
    """Turn a raw HCL literal (as text) into a Python value where easy."""
    if raw is None:
        return None
    raw = raw.strip()
    if raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1]
    if raw == "true":
        return True
    if raw == "false":
        return False
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    return raw  # unresolved expression - return as-is


def resolve_value(raw, variables):
    """Resolve a `var.NAME` reference against parsed variable defaults;
    otherwise fall back to a plain literal."""
    if raw is None:
        return None
    stripped = raw.strip()
    m = re.fullmatch(r'var\.([a-zA-Z0-9_-]+)', stripped)
    if m:
        return variables.get(m.group(1))
    return literal_value(stripped)


def load_variables(blocks):
    variables = {}
    for b in blocks:
        if b["keyword"] == "variable" and b["label1"]:
            attrs = extract_top_level_attrs(b["body"])
            variables[b["label1"]] = literal_value(attrs.get("default"))
    return variables


def get_count(attrs, variables):
    """Returns (count:int, note:str|None)."""
    if "count" in attrs:
        val = resolve_value(attrs["count"], variables)
        if isinstance(val, (int, float)):
            return int(val), None
        return 1, f"could not resolve `count = {attrs['count']}`, assumed 1"
    if "for_each" in attrs:
        return 1, "uses for_each; quantity not auto-resolved, assumed 1"
    return 1, None


# --------------------------------------------------------------------------
# Per-resource-type cost models
# --------------------------------------------------------------------------

def price_aws_instance(name, attrs, variables, pricing):
    qty, qty_note = get_count(attrs, variables)
    itype = resolve_value(attrs.get("instance_type", ""), variables)
    hourly = pricing["ec2_hourly"].get(itype) if isinstance(itype, str) else None
    hpm = pricing["hours_per_month"]

    notes = []
    if qty_note:
        notes.append(qty_note)

    if hourly is None:
        notes.append(f"unknown instance_type '{itype}' - add it to pricing_data.json")
        return qty, None, None, "; ".join(notes)

    unit_month = round(hourly * hpm, 2)
    total = round(unit_month * qty, 2)
    notes.insert(0, f"{itype}, on-demand Linux")

    # Optional root EBS volume, only if explicitly declared in the .tf
    root = extract_named_subblock(attrs.get("_body", ""), "root_block_device")
    return qty, unit_month, total, "; ".join(notes)


def price_load_balancer(name, attrs, variables, pricing):
    lb_type = resolve_value(attrs.get("load_balancer_type", '"application"'), variables)
    lb_type = (lb_type or "application").lower()
    conf = pricing["load_balancer"].get(lb_type)
    if not conf:
        return 1, None, None, f"unknown load_balancer_type '{lb_type}'"
    hpm = pricing["hours_per_month"]
    unit_month = round(conf["hourly"] * hpm, 2)
    note = (
        f"{lb_type} load balancer, base hourly charge only; "
        f"usage-based {conf['capacity_unit_name']} charges "
        f"(~${conf['capacity_unit_hourly']}/hr per unit, traffic-dependent) not included"
    )
    return 1, unit_month, unit_month, note


def price_nat_gateway(name, attrs, variables, pricing):
    hpm = pricing["hours_per_month"]
    conf = pricing["nat_gateway"]
    unit_month = round(conf["hourly"] * hpm, 2)
    note = f"hourly charge only; +${conf['gb_processed']}/GB data processed (traffic-dependent) not included"
    return 1, unit_month, unit_month, note


def price_vpc_endpoint(name, attrs, variables, pricing):
    ep_type = resolve_value(attrs.get("vpc_endpoint_type", '"Gateway"'), variables)
    ep_type = (ep_type or "Gateway").lower()
    conf = pricing["vpc_endpoint"]
    hpm = pricing["hours_per_month"]
    if ep_type == "gateway":
        return 1, 0.0, 0.0, "Gateway endpoint (S3/DynamoDB only) - always free"
    unit_month = round(conf["interface_hourly"] * hpm, 2)
    note = f"interface endpoint; +${conf['interface_gb_processed']}/GB processed (traffic-dependent) not included"
    return 1, unit_month, unit_month, note


def price_eip(name, attrs, variables, pricing):
    conf = pricing["eip_idle_hourly"]
    hpm = pricing["hours_per_month"]
    idle_month = round(conf * hpm, 2)
    note = f"free while attached to a running instance; ~${idle_month}/mo if left unattached"
    return 1, 0.0, 0.0, note


def price_ebs_volume(name, attrs, variables, pricing):
    size = resolve_value(attrs.get("size", "8"), variables)
    vtype = resolve_value(attrs.get("type", '"gp3"'), variables) or "gp3"
    try:
        size = float(size)
    except (TypeError, ValueError):
        return 1, None, None, f"could not resolve size '{attrs.get('size')}'"
    gb_price = pricing["ebs_gb_month"].get(vtype)
    if gb_price is None:
        return 1, None, None, f"unknown volume type '{vtype}'"
    total = round(size * gb_price, 2)
    return 1, total, total, f"{int(size)} GB {vtype}"


def price_db_instance(name, attrs, variables, pricing):
    qty, qty_note = get_count(attrs, variables)
    iclass = resolve_value(attrs.get("instance_class", ""), variables)
    hourly = pricing["rds_hourly"].get(iclass)
    hpm = pricing["hours_per_month"]
    notes = [qty_note] if qty_note else []
    if hourly is None:
        notes.append(f"unknown instance_class '{iclass}' - add it to pricing_data.json")
        return qty, None, None, "; ".join(notes)
    unit_month = round(hourly * hpm, 2)
    total = round(unit_month * qty, 2)
    notes.insert(0, f"{iclass} (storage/IOPS not included)")
    return qty, unit_month, total, "; ".join(notes)


COST_MODELS = {
    "aws_instance": price_aws_instance,
    "aws_lb": price_load_balancer,
    "aws_alb": price_load_balancer,
    "aws_nat_gateway": price_nat_gateway,
    "aws_vpc_endpoint": price_vpc_endpoint,
    "aws_eip": price_eip,
    "aws_ebs_volume": price_ebs_volume,
    "aws_db_instance": price_db_instance,
}


# --------------------------------------------------------------------------
# Driving logic
# --------------------------------------------------------------------------

def read_terraform_files(path):
    """Return list of (filename, text) for the given .tf file or directory."""
    files = []
    if os.path.isdir(path):
        for fname in sorted(os.listdir(path)):
            if fname.endswith(".tf"):
                fpath = os.path.join(path, fname)
                with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                    files.append((fname, f.read()))
    else:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            files.append((os.path.basename(path), f.read()))
    if not files:
        raise FileNotFoundError(f"No .tf files found at: {path}")
    return files


def detect_region(blocks, variables):
    for b in blocks:
        if b["keyword"] == "provider" and b["label1"] == "aws":
            attrs = extract_top_level_attrs(b["body"])
            if "region" in attrs:
                return resolve_value(attrs["region"], variables)
    return None


def analyze(path, pricing):
    files = read_terraform_files(path)
    combined_text = "\n".join(text for _, text in files)
    blocks = extract_top_level_blocks(combined_text)
    variables = load_variables(blocks)
    region = detect_region(blocks, variables)

    rows = []          # priced resources
    free_rows = []      # $0 by nature
    usage_rows = []     # usage-based, not modeled
    unmodeled_rows = [] # resource type we have no model for at all

    for b in blocks:
        if b["keyword"] != "resource" or not b["label1"] or not b["label2"]:
            continue
        rtype, rname = b["label1"], b["label2"]
        attrs = extract_top_level_attrs(b["body"])
        attrs["_body"] = b["body"]  # stash for models that need nested blocks

        if rtype in COST_MODELS:
            qty, unit_month, total_month, note = COST_MODELS[rtype](rname, attrs, variables, pricing)
            rows.append({
                "resource": f"{rtype}.{rname}",
                "type": rtype,
                "qty": qty,
                "unit_month": unit_month,
                "total_month": total_month,
                "note": note,
            })
        elif rtype in FREE_RESOURCE_TYPES:
            free_rows.append(f"{rtype}.{rname}")
        elif rtype in USAGE_BASED_RESOURCE_TYPES:
            usage_rows.append((f"{rtype}.{rname}", USAGE_BASED_RESOURCE_TYPES[rtype]))
        else:
            unmodeled_rows.append(f"{rtype}.{rname}")

    return {
        "files": [f for f, _ in files],
        "region": region,
        "rows": rows,
        "free_rows": free_rows,
        "usage_rows": usage_rows,
        "unmodeled_rows": unmodeled_rows,
    }


def render_markdown(result, pricing):
    meta = pricing["metadata"]
    lines = []
    lines.append("# Terraform AWS Cost Estimate")
    lines.append("")
    lines.append(f"**Source:** `{', '.join(result['files'])}`  ")
    lines.append(f"**Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}  ")
    lines.append(
        f"**Pricing basis:** {meta['region']} ({meta['os']}, {meta['purchase_option']}), "
        f"snapshot dated {meta['snapshot_date']}"
    )
    if result["region"] and result["region"] != meta["region"]:
        lines.append(
            f"\n> ⚠️ This Terraform targets region `{result['region']}`, but prices below are "
            f"for `{meta['region']}`. Actual costs will differ."
        )
    lines.append("")

    priced = [r for r in result["rows"] if r["total_month"] is not None]
    unpriced = [r for r in result["rows"] if r["total_month"] is None]
    grand_total = round(sum(r["total_month"] for r in priced), 2)

    lines.append("## Summary")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append(f"| **Estimated recurring monthly cost** | **${grand_total:,.2f}** |")
    lines.append(f"| Resources priced | {len(priced)} |")
    lines.append(f"| Resources needing attention (unknown type/size) | {len(unpriced)} |")
    lines.append(f"| Free / $0 resources | {len(result['free_rows'])} |")
    lines.append(f"| Usage-based (not estimated) | {len(result['usage_rows'])} |")
    lines.append(f"| Unrecognized resource types | {len(result['unmodeled_rows'])} |")
    lines.append("")
    lines.append(
        "> Total excludes all usage-based charges (data transfer, LCUs, requests, storage growth, etc). "
        "See **Assumptions & Caveats** below."
    )
    lines.append("")

    lines.append("## Cost Breakdown")
    lines.append("")
    lines.append("| Resource | Qty | Unit $/mo | Total $/mo | Notes |")
    lines.append("|---|---|---|---|---|")
    for r in sorted(priced, key=lambda x: -x["total_month"]):
        lines.append(
            f"| `{r['resource']}` | {r['qty']} | ${r['unit_month']:,.2f} | "
            f"${r['total_month']:,.2f} | {r['note'] or ''} |"
        )
    for r in unpriced:
        lines.append(f"| `{r['resource']}` | {r['qty']} | — | — | ⚠️ {r['note'] or 'not estimated'} |")
    if not result["rows"]:
        lines.append("| _(none found)_ | | | | |")
    lines.append("")

    if result["free_rows"]:
        lines.append("## Free / No Direct Cost")
        lines.append("")
        for name in result["free_rows"]:
            lines.append(f"- `{name}`")
        lines.append("")

    if result["usage_rows"]:
        lines.append("## Usage-Based (Not Estimated)")
        lines.append("")
        lines.append("| Resource | Why it's not estimated |")
        lines.append("|---|---|")
        for name, why in result["usage_rows"]:
            lines.append(f"| `{name}` | {why} |")
        lines.append("")

    if result["unmodeled_rows"]:
        lines.append("## Unrecognized Resource Types")
        lines.append("")
        lines.append("No cost model exists yet for these - check the AWS Pricing Calculator directly:")
        lines.append("")
        for name in result["unmodeled_rows"]:
            lines.append(f"- `{name}`")
        lines.append("")

    lines.append("## Assumptions & Caveats")
    lines.append("")
    lines.append(f"- Prices are a hand-maintained snapshot for **{meta['region']}**, dated {meta['snapshot_date']}. AWS prices change; re-verify anything budget-critical at https://calculator.aws")
    lines.append("- Only flat, always-on charges are estimated (instance-hours, load-balancer-hours, NAT gateway-hours, provisioned storage). Traffic-driven charges (data transfer, LCUs/NLCUs, requests, S3 storage growth) are **not** included.")
    lines.append("- AWS Free Tier credits are not applied.")
    lines.append("- Only On-Demand pricing is used; Reserved Instances, Savings Plans, and Spot are not modeled.")
    lines.append("- `count`/`for_each` are resolved only when they're a literal number or a `var.x` with a literal default; anything more dynamic is assumed to be 1 (flagged in the notes).")
    lines.append("- This is a lightweight, regex-based reader, not a full HCL parser - unusual formatting or heavily nested expressions may be missed.")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Estimate monthly AWS cost from a Terraform file or directory.")
    parser.add_argument("path", help="Path to a .tf file, or a directory containing .tf files")
    parser.add_argument("-o", "--output", help="Output Markdown file (default: <input>_cost_report.md)")
    parser.add_argument("--pricing", default=DEFAULT_PRICING_FILE, help="Path to a pricing_data.json override")
    args = parser.parse_args()

    if not os.path.exists(args.path):
        print(f"error: path not found: {args.path}", file=sys.stderr)
        sys.exit(1)

    with open(args.pricing, "r", encoding="utf-8") as f:
        pricing = json.load(f)

    result = analyze(args.path, pricing)
    report = render_markdown(result, pricing)

    if args.output:
        out_path = args.output
    else:
        base = os.path.splitext(os.path.basename(args.path.rstrip("/\\")))[0] or "terraform"
        out_dir = args.path if os.path.isdir(args.path) else os.path.dirname(os.path.abspath(args.path))
        out_path = os.path.join(out_dir or ".", f"{base}_cost_report.md")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(report)

    print(f"Cost report written to: {out_path}")


if __name__ == "__main__":
    main()
