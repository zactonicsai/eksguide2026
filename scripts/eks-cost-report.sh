#!/usr/bin/env bash
# ================================================================
#  eks-cost-report.sh
#
#  PURPOSE : Scan ONE EKS cluster, list every billable AWS service
#            it is using right now (EKS fee, EC2 nodes, EBS disks,
#            load balancers, NAT gateways, public IPs, CloudWatch
#            logs, ECR), and write a report file with a rough
#            monthly cost ESTIMATE for each.
#
#  NEEDS   : aws CLI v2 and bash 4+ (Linux default; on macOS run
#            "brew install bash" first). Read-only IAM permissions
#            for eks, ec2, elb, elbv2, logs, ecr and (optionally)
#            ce:GetCostAndUsage for the real-spend section.
#
#  USAGE   : ./eks-cost-report.sh <cluster-name> [region]
# ================================================================

# ---------- INPUTS ----------
# Cluster name is required (1st argument); region is optional (2nd).
CLUSTER_NAME="${1:-}"
REGION="${2:-us-east-1}"
# If no cluster name was given, show usage help and stop.
if [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <cluster-name> [region]"; exit 1
fi

# ---------- REPORT FILE ----------
# Every line we print also gets saved into this timestamped report file.
REPORT="eks-cost-report_${CLUSTER_NAME}_$(date +%Y-%m-%d_%H%M).txt"
# AWS uses ~730 hours as the length of an average month.
HOURS_PER_MONTH=730

# ---------- PRICE TABLE (EDIT FOR YOUR REGION) ----------
# Approximate US East (N. Virginia) ON-DEMAND list prices, mid-2026.
# These are ESTIMATES for planning - your real bill will differ!
EKS_HOURLY=0.10            # EKS control plane, standard support
GP3_GB_MONTH=0.08          # gp3 EBS disk, per GB per month
GP2_GB_MONTH=0.10          # gp2 EBS disk, per GB per month
ALB_MONTHLY=16.43          # Application LB base ($0.0225/hr), LCUs extra
NLB_MONTHLY=16.43          # Network LB base ($0.0225/hr), LCUs extra
CLB_MONTHLY=18.25          # Classic LB base ($0.025/hr), data extra
NAT_MONTHLY=32.85          # NAT gateway base ($0.045/hr), + $0.045/GB
PUBLIC_IPV4_MONTHLY=3.65   # Each public IPv4 address ($0.005/hr)
LOG_STORAGE_GB_MONTH=0.03  # CloudWatch log STORAGE (ingest $0.50/GB extra)

# Hourly on-demand prices for common node types (add yours if missing).
declare -A EC2_HOURLY=(
  [t3.small]=0.0208  [t3.medium]=0.0416 [t3.large]=0.0832  [t3.xlarge]=0.1664
  [t3a.medium]=0.0376 [t3a.large]=0.0752
  [m5.large]=0.096   [m5.xlarge]=0.192  [m5.2xlarge]=0.384 [m5.4xlarge]=0.768
  [m6i.large]=0.096  [m6i.xlarge]=0.192 [m6i.2xlarge]=0.384
  [m7i.large]=0.1008 [m7i.xlarge]=0.2016
  [m6g.large]=0.077  [m6g.xlarge]=0.154 [m7g.xlarge]=0.1632
  [c5.large]=0.085   [c5.xlarge]=0.17   [c5.2xlarge]=0.34
  [c6i.large]=0.085  [c6i.xlarge]=0.17
  [r5.large]=0.126   [r5.xlarge]=0.252  [r5.2xlarge]=0.504
  [r6i.large]=0.126  [r6i.xlarge]=0.252
)
# Fallback hourly price used when an instance type is not in the table.
DEFAULT_EC2_HOURLY=0.20

# ---------- LITTLE HELPER FUNCTIONS ----------
# Running total of every estimate we add up, in dollars.
TOTAL=0
# add <amount>  : adds a dollar amount to the running total.
add() { TOTAL=$(awk -v t="$TOTAL" -v a="$1" 'BEGIN{printf "%.2f", t+a}'); }
# mul <a> <b>   : multiplies two numbers and prints the result (2 decimals).
mul() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a*b}'; }
# say <text>    : prints a line to the screen AND appends it to the report.
say() { printf '%b\n' "$*" | tee -a "$REPORT"; }
# hr            : prints a divider line to keep the report readable.
hr()  { say "----------------------------------------------------------------"; }

# ---------- REPORT HEADER ----------
say "================================================================"
say " EKS BILLABLE-SERVICES USAGE + COST-ESTIMATE REPORT"
say " Cluster : $CLUSTER_NAME    Region : $REGION"
say " Created : $(date)"
say "================================================================"

# ---------- SECTION 1: EKS CONTROL PLANE (the cluster 'brain') ----------
hr
say "1) AMAZON EKS CONTROL PLANE - billed every hour, even when idle"
# Ask AWS for the cluster's version, status, and its VPC id (used later).
CLUSTER_INFO=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.[version,status,resourcesVpcConfig.vpcId]' --output text 2>/dev/null)
# If the cluster doesn't exist, there is nothing to report - stop here.
[ -z "$CLUSTER_INFO" ] && { say "ERROR: cluster not found."; exit 1; }
# Split the answer into three variables.
read -r K8S_VERSION STATUS VPC_ID <<< "$CLUSTER_INFO"
# Convert the hourly brain fee into a monthly number.
EKS_MONTHLY=$(mul "$EKS_HOURLY" "$HOURS_PER_MONTH")
say "   Kubernetes version: $K8S_VERSION   Status: $STATUS   VPC: $VPC_ID"
say "   Estimated cost    : \$${EKS_MONTHLY}/month (\$${EKS_HOURLY}/hour)"
say "   NOTE: versions past standard support cost \$0.60/hour (~\$438/mo)!"
add "$EKS_MONTHLY"

# ---------- SECTION 2: EC2 WORKER NODES (where Kafka + NiFi run) ----------
hr
say "2) EC2 WORKER NODES - the computers running Kafka brokers, the"
say "   Strimzi operator, NiFi nodes, and ZooKeeper/KRaft controllers"
# List the managed node groups just for information (names + capacity type).
for NG in $(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups[]' --output text 2>/dev/null); do
  NG_INFO=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" --region "$REGION" \
    --query 'nodegroup.[capacityType,scalingConfig.desiredSize,instanceTypes[0]]' --output text 2>/dev/null)
  say "   Node group: $NG  ($NG_INFO)"
done
# Now count the ACTUAL running instances tagged as belonging to this
# cluster (this also catches Karpenter nodes outside managed groups).
EC2_SUBTOTAL=0
PUBLIC_IP_COUNT=0
INSTANCE_LINES=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,PublicIpAddress]' --output text 2>/dev/null)
if [ -z "$INSTANCE_LINES" ]; then
  say "   No running worker nodes found (cluster may be scaled to zero)."
fi
# Walk each running instance: look up its price and add it to the total.
while read -r IID ITYPE PIP; do
  # Skip blank lines from the query output.
  [ -z "$IID" ] && continue
  # Look up this instance type's hourly price (or use the fallback).
  PRICE="${EC2_HOURLY[$ITYPE]:-$DEFAULT_EC2_HOURLY}"
  # Turn hourly into monthly for the report.
  MONTHLY=$(mul "$PRICE" "$HOURS_PER_MONTH")
  say "   $IID  $ITYPE  ~\$${MONTHLY}/month"
  # Add this node's cost to the EC2 subtotal.
  EC2_SUBTOTAL=$(awk -v t="$EC2_SUBTOTAL" -v a="$MONTHLY" 'BEGIN{printf "%.2f", t+a}')
  # Count nodes that hold a public IPv4 address (billed separately below).
  if [ -n "$PIP" ] && [ "$PIP" != "None" ]; then PUBLIC_IP_COUNT=$((PUBLIC_IP_COUNT+1)); fi
done <<< "$INSTANCE_LINES"
say "   EC2 subtotal: ~\$${EC2_SUBTOTAL}/month (on-demand list; Spot/Savings"
say "   Plans can be 60-90% cheaper and are NOT reflected here)"
add "$EC2_SUBTOTAL"

# ---------- SECTION 3: EBS DISKS (Kafka logs + NiFi's 3 repositories) ----
hr
say "3) EBS DISKS - Kafka message storage per broker, plus NiFi's"
say "   FlowFile / Content / Provenance repositories"
GP3_GB=0; GP2_GB=0; OTHER_GB=0
# Walk every EBS volume tagged as belonging to this cluster.
while read -r VID SIZE VTYPE VSTATE; do
  # Skip blank lines from the query output.
  [ -z "$VID" ] && continue
  say "   $VID  ${SIZE}GB  $VTYPE  ($VSTATE)"
  # Add this disk's size to the right bucket by disk type.
  case "$VTYPE" in
    gp3) GP3_GB=$((GP3_GB+SIZE));;
    gp2) GP2_GB=$((GP2_GB+SIZE));;
    *)   OTHER_GB=$((OTHER_GB+SIZE));;
  esac
done <<< "$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER_NAME}" \
  --query 'Volumes[].[VolumeId,Size,VolumeType,State]' --output text 2>/dev/null)"
# Turn total gigabytes into dollars per month (unknown types use gp2 rate).
EBS_COST=$(awk -v g3="$GP3_GB" -v p3="$GP3_GB_MONTH" -v g2="$GP2_GB" -v p2="$GP2_GB_MONTH" -v o="$OTHER_GB" \
  'BEGIN{printf "%.2f", g3*p3 + g2*p2 + o*0.10}')
say "   Totals: ${GP3_GB}GB gp3 + ${GP2_GB}GB gp2 + ${OTHER_GB}GB other"
say "   EBS estimate: ~\$${EBS_COST}/month"
say "   NOTE: untagged node ROOT disks may be missing from this list."
add "$EBS_COST"

# ---------- SECTION 4: LOAD BALANCERS (Kafka's + NiFi's front doors) ----
hr
say "4) LOAD BALANCERS - Strimzi external listeners make ONE PER BROKER"
say "   plus a bootstrap LB; NiFi's web UI usually has one more"
ALB_COUNT=0; NLB_COUNT=0; CLB_COUNT=0
# Walk every modern (ALB/NLB) load balancer in the region...
while read -r LB_ARN LB_TYPE LB_NAME; do
  # Skip blank lines from the query output.
  [ -z "$LB_ARN" ] && continue
  # ...and check its tags to see if it belongs to OUR cluster.
  OWNED=$(aws elbv2 describe-tags --resource-arns "$LB_ARN" --region "$REGION" \
    --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'] | length(@)" --output text 2>/dev/null)
  if [ -n "$OWNED" ] && [ "$OWNED" != "0" ] && [ "$OWNED" != "None" ]; then
    say "   $LB_TYPE : $LB_NAME"
    # Count it in the right bucket for pricing.
    if [ "$LB_TYPE" = "application" ]; then ALB_COUNT=$((ALB_COUNT+1)); else NLB_COUNT=$((NLB_COUNT+1)); fi
  fi
done <<< "$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].[LoadBalancerArn,Type,LoadBalancerName]' --output text 2>/dev/null)"
# Same check for old-style Classic load balancers.
for LB_NAME in $(aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null); do
  OWNED=$(aws elb describe-tags --load-balancer-names "$LB_NAME" --region "$REGION" \
    --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'] | length(@)" --output text 2>/dev/null)
  if [ -n "$OWNED" ] && [ "$OWNED" != "0" ] && [ "$OWNED" != "None" ]; then
    say "   classic : $LB_NAME"; CLB_COUNT=$((CLB_COUNT+1))
  fi
done
# Convert the counts into a base monthly estimate.
LB_COST=$(awk -v a="$ALB_COUNT" -v pa="$ALB_MONTHLY" -v n="$NLB_COUNT" -v pn="$NLB_MONTHLY" -v c="$CLB_COUNT" -v pc="$CLB_MONTHLY" \
  'BEGIN{printf "%.2f", a*pa + n*pn + c*pc}')
say "   Found: $ALB_COUNT ALB, $NLB_COUNT NLB, $CLB_COUNT Classic"
say "   LB base estimate: ~\$${LB_COST}/month (+ traffic/LCU charges extra)"
add "$LB_COST"

# ---------- SECTION 5: NAT GATEWAYS (private nodes' internet door) -----
hr
say "5) NAT GATEWAYS - how private nodes pull images and NiFi calls APIs"
# Count the NAT gateways living inside this cluster's VPC.
NAT_COUNT=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
  --query 'length(NatGateways)' --output text 2>/dev/null)
# Guard against an empty answer so the math below never breaks.
[ -z "$NAT_COUNT" ] || [ "$NAT_COUNT" = "None" ] && NAT_COUNT=0
# Convert the count into a base monthly estimate.
NAT_COST=$(mul "$NAT_COUNT" "$NAT_MONTHLY")
say "   NAT gateways in VPC $VPC_ID : $NAT_COUNT"
say "   NAT base estimate: ~\$${NAT_COST}/month (+ \$0.045 per GB processed)"
add "$NAT_COST"

# ---------- SECTION 6: PUBLIC IPv4 ADDRESSES ---------------------------
hr
say "6) PUBLIC IPv4 ADDRESSES - every public address bills ~\$3.65/month"
# Estimate = node public IPs (counted in section 2) + one per NAT gateway.
IP_EST=$((PUBLIC_IP_COUNT + NAT_COUNT))
IP_COST=$(mul "$IP_EST" "$PUBLIC_IPV4_MONTHLY")
say "   Node public IPs: $PUBLIC_IP_COUNT   NAT gateway IPs: $NAT_COUNT"
say "   IPv4 estimate: ~\$${IP_COST}/month (internet-facing LBs add more)"
add "$IP_COST"

# ---------- SECTION 7: CLOUDWATCH LOGS (chatty Kafka + NiFi) -----------
hr
say "7) CLOUDWATCH LOG STORAGE - control plane logs + Container Insights"
LOG_BYTES=0
# Check both log-group families this cluster typically creates.
for PREFIX in "/aws/eks/${CLUSTER_NAME}" "/aws/containerinsights/${CLUSTER_NAME}"; do
  # Walk each log group under this prefix and add up its stored bytes.
  while read -r LGNAME BYTES; do
    # Skip blank lines and treat missing sizes as zero.
    [ -z "$LGNAME" ] && continue
    case "$BYTES" in ''|None) BYTES=0;; esac
    say "   $LGNAME : $BYTES bytes stored"
    LOG_BYTES=$((LOG_BYTES + BYTES))
  done <<< "$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$PREFIX" \
    --query 'logGroups[].[logGroupName,storedBytes]' --output text 2>/dev/null)"
done
# Convert bytes to gigabytes, then gigabytes to dollars per month.
LOG_GB=$(awk -v b="$LOG_BYTES" 'BEGIN{printf "%.2f", b/1073741824}')
LOG_COST=$(mul "$LOG_GB" "$LOG_STORAGE_GB_MONTH")
say "   Total stored: ${LOG_GB} GB -> ~\$${LOG_COST}/month storage"
say "   NOTE: log INGESTION (~\$0.50/GB) is billed separately as logs arrive."
add "$LOG_COST"

# ---------- SECTION 8: ECR IMAGE STORAGE (informational) ---------------
hr
say "8) ECR IMAGE REPOSITORIES (region-wide) - custom NiFi / Kafka Connect"
say "   images live here and bill ~\$0.10 per GB per month"
# Count the repositories (image sizes are not scanned to keep this fast).
REPO_COUNT=$(aws ecr describe-repositories --region "$REGION" --query 'length(repositories)' --output text 2>/dev/null)
[ -z "$REPO_COUNT" ] || [ "$REPO_COUNT" = "None" ] && REPO_COUNT=0
say "   Repositories found: $REPO_COUNT (storage size not included in total)"

# ---------- SECTION 9: REAL SPEND FROM COST EXPLORER (optional) --------
hr
say "9) ACTUAL SPEND, LAST 30 DAYS (whole account, from AWS Cost Explorer)"
# Work out the date 30 days ago on both Linux (GNU date) and macOS (BSD).
if date -d "30 days ago" +%F >/dev/null 2>&1; then
  START=$(date -d "30 days ago" +%F)
else
  START=$(date -v-30d +%F 2>/dev/null)
fi
END=$(date +%F)
TAB=$(printf '\t')
# Ask Cost Explorer for last month's spend grouped by AWS service.
if [ -n "$START" ] && aws ce get-cost-and-usage \
     --time-period "Start=${START},End=${END}" --granularity MONTHLY \
     --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE \
     --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' \
     --output text > /tmp/ce_out.$$ 2>/dev/null; then
  # Show the 12 most expensive services, biggest first.
  sort -t "$TAB" -k2 -gr /tmp/ce_out.$$ | head -12 | while IFS="$TAB" read -r SVC AMT; do
    say "   $(printf '%-45s' "$SVC") \$$(awk -v a="$AMT" 'BEGIN{printf "%.2f", a}')"
  done
  # Clean up the temporary file we used for sorting.
  rm -f /tmp/ce_out.$$
else
  say "   (Skipped - requires ce:GetCostAndUsage permission and Cost"
  say "    Explorer enabled on the account.)"
fi

# ---------- GRAND TOTAL + DISCLAIMER ----------
hr
say "ESTIMATED MONTHLY TOTAL (sections 1-7): ~\$${TOTAL}"
say ""
say "NOT included in the estimate (they WILL appear on the real bill):"
say "  - Cross-AZ data transfer (~\$0.01/GB each way - Kafka replication!)"
say "  - Load balancer LCU/traffic charges and NAT per-GB processing"
say "  - S3 storage/requests used by NiFi flows; ECR image storage"
say "  - CloudWatch log ingestion, custom metrics, alarms; KMS; Route 53"
say ""
say "DISCLAIMER: rough on-demand US-East list prices - edit the price"
say "table at the top for your region, and confirm real numbers with the"
say "AWS Pricing Calculator and Cost Explorer."
say ""
say "Report saved to: $REPORT"
