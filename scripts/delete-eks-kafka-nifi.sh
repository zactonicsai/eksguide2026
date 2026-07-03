#!/usr/bin/env bash
# ================================================================
#  delete-eks-kafka-nifi.sh   (Unix / Linux / macOS version)
#
#  PURPOSE : Tear down an AWS EKS cluster that runs Kafka (Strimzi)
#            and Apache NiFi, plus every AWS resource they created,
#            so ALL billing for the cluster stops.
#
#  WARNING : THIS PERMANENTLY DESTROYS ALL KAFKA MESSAGES AND ALL
#            NIFI DATA. There is no undo button.
#
#  NEEDS   : aws CLI v2, kubectl, helm, eksctl on your PATH, and an
#            AWS profile with admin permissions.
#
#  USAGE   : ./delete-eks-kafka-nifi.sh <cluster-name> [region]
# ================================================================

# ---------- SETTINGS ----------
# Cluster name comes from the 1st argument, or falls back to this default.
CLUSTER_NAME="${1:-my-eks-cluster}"
# AWS region comes from the 2nd argument, or falls back to this default.
REGION="${2:-us-east-1}"
# Kubernetes namespace where Strimzi/Kafka was installed.
KAFKA_NS="kafka"
# Kubernetes namespace where NiFi was installed.
NIFI_NS="nifi"

# ---------- SAFETY GATE: make the human prove they mean it ----------
# Print a big warning so nobody runs this by accident.
echo ""
echo "*** DANGER *** This will DELETE cluster \"$CLUSTER_NAME\" in $REGION,"
echo "including ALL Kafka messages and ALL NiFi data. No undo."
echo ""
# Force the user to re-type the cluster name; anything else aborts.
read -r -p "Type the cluster name to confirm: " CONFIRM
# Compare answer to the real name; quit without deleting on a mismatch.
[ "$CONFIRM" = "$CLUSTER_NAME" ] || { echo "Names did not match. Nothing deleted."; exit 1; }

# ---------- STEP 0: Point kubectl at THIS cluster ----------
# Downloads the cluster's login info so every kubectl command below talks
# to this cluster and not some other one. (Free - no billing.)
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# ---------- STEP 1: Delete Kafka INSIDE Kubernetes FIRST ----------
# Why first? While the Strimzi operator is still alive, it politely tells
# AWS to remove the load balancers ($16-25/mo EACH) and EBS disks
# ($0.08/GB-mo) it created. Skip this and those bill forever.

# Delete Kafka users (their passwords/TLS certs are Kubernetes Secrets).
kubectl delete kafkauser --all -n "$KAFKA_NS" --ignore-not-found=true 2>/dev/null
# Delete Kafka topics (the "mailboxes" whose messages sit on EBS disks).
kubectl delete kafkatopic --all -n "$KAFKA_NS" --ignore-not-found=true 2>/dev/null
# If topics get stuck "Terminating" (finalizers), un-comment the next line:
# kubectl get kafkatopic -n "$KAFKA_NS" -o name | xargs -r -I{} kubectl patch {} -n "$KAFKA_NS" --type=merge -p '{"metadata":{"finalizers":[]}}'
# Delete Kafka Connect / MirrorMaker2 / Bridge (extra pods burning EC2 time).
kubectl delete kafkaconnect,kafkamirrormaker2,kafkabridge --all -n "$KAFKA_NS" --ignore-not-found=true 2>/dev/null
# Delete the Kafka cluster itself: broker + controller pods vanish AND
# Strimzi asks AWS to remove the PER-BROKER load balancers (a 3-broker
# cluster with external listeners has 4 of them: 3 brokers + bootstrap).
kubectl delete kafka --all -n "$KAFKA_NS" --ignore-not-found=true 2>/dev/null
# Delete the node pool definitions (newer Strimzi splits brokers into pools).
kubectl delete kafkanodepool --all -n "$KAFKA_NS" --ignore-not-found=true 2>/dev/null
# Delete any leftover rebalance requests (Cruise Control instructions).
kubectl delete kafkarebalance --all -n "$KAFKA_NS" --ignore-not-found=true 2>/dev/null
# Give AWS about 2 minutes to actually tear the Kafka load balancers down.
sleep 120
# Remove the Strimzi operator itself (just pods - it billed only EC2 time).
helm uninstall strimzi-cluster-operator -n "$KAFKA_NS" 2>/dev/null || true
# Delete leftover PersistentVolumeClaims: EACH ONE is a real EBS disk in
# AWS that keeps billing ~$0.08/GB-month until it is gone.
kubectl delete pvc --all -n "$KAFKA_NS" --ignore-not-found=true 2>/dev/null

# ---------- STEP 2: Delete NiFi INSIDE Kubernetes ----------
# Remove the NiFi Helm release: deletes the NiFi pods (EC2 usage) and the
# web-UI Service, which tells AWS to delete NiFi's load balancer.
# (If your release has a different name, check with: helm list -n "$NIFI_NS")
helm uninstall nifi -n "$NIFI_NS" 2>/dev/null || true
# If NiFi used its own ZooKeeper release for clustering, remove it too
# (more pods + more EBS disks that would otherwise keep billing).
helm uninstall zookeeper -n "$NIFI_NS" 2>/dev/null || true
# Delete any Ingress objects: each Ingress = a real AWS ALB (~$17+/mo).
kubectl delete ingress --all -n "$NIFI_NS" --ignore-not-found=true 2>/dev/null
# Delete NiFi's disks: the FlowFile, Content, and Provenance repositories
# each live on EBS volumes that bill until their PVCs are deleted.
kubectl delete pvc --all -n "$NIFI_NS" --ignore-not-found=true 2>/dev/null

# ---------- STEP 3: Delete EVERY remaining LoadBalancer Service ----------
# Each Service of type LoadBalancer = one real AWS load balancer billing
# ~$16-25/month. This sweep catches any we missed in ANY namespace.
kubectl get svc --all-namespaces \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
while read -r NS NAME; do
  # Skip blank lines, then delete this Service so Kubernetes tells AWS
  # to remove the matching load balancer (and stop its billing).
  [ -n "$NAME" ] && kubectl delete svc "$NAME" -n "$NS" --ignore-not-found=true
done

# ---------- STEP 4: Delete the namespaces (final inside sweep) ----------
# Deleting a namespace deletes EVERY leftover object inside it (services,
# secrets, configmaps) so nothing hidden survives to keep billing.
kubectl delete namespace "$KAFKA_NS" "$NIFI_NS" --ignore-not-found=true 2>/dev/null
# Give the AWS Load Balancer Controller time to finish AWS-side cleanup.
sleep 120

# ---------- STEP 5: Delete the EKS cluster itself ----------
# Best case: the cluster was made with eksctl, which also removes node
# groups (EC2 computers), the control plane (the ~$73/month "brain" fee),
# and the VPC + NAT gateway (~$33/month) if eksctl created them.
if command -v eksctl >/dev/null 2>&1 && eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  # Delete everything eksctl knows about and wait until it is truly gone.
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait
else
  # Fallback for clusters made in the console / Terraform / CDK:
  # 1) Delete every managed node group (these ARE the EC2 computers).
  for NG in $(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups[]' --output text 2>/dev/null); do
    # Ask AWS to remove this group of worker computers.
    echo "Deleting node group: $NG"
    aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" --region "$REGION"
    # Wait for it, because the cluster refuses to die while groups exist.
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" --region "$REGION"
  done
  # 2) Delete any Fargate profiles (serverless pods billed per-second).
  for FP in $(aws eks list-fargate-profiles --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'fargateProfileNames[]' --output text 2>/dev/null); do
    # Remove this Fargate profile so no serverless pods can bill anymore.
    echo "Deleting Fargate profile: $FP"
    aws eks delete-fargate-profile --cluster-name "$CLUSTER_NAME" --fargate-profile-name "$FP" --region "$REGION"
    # Wait until AWS confirms the profile is gone.
    aws eks wait fargate-profile-deleted --cluster-name "$CLUSTER_NAME" --fargate-profile-name "$FP" --region "$REGION"
  done
  # 3) Delete the control plane - this stops the ~$73/month EKS fee.
  aws eks delete-cluster --name "$CLUSTER_NAME" --region "$REGION"
  # Wait until the cluster is completely deleted before cleanup below.
  aws eks wait cluster-deleted --name "$CLUSTER_NAME" --region "$REGION"
  # NOTE: this path does NOT delete your VPC, NAT gateway (~$33/month),
  # or Elastic IPs because they might be shared with other systems -
  # review them by hand in the VPC console.
fi

# ---------- STEP 6: Hunt down orphaned EBS disks ----------
# Any disk still tagged with our cluster and sitting "available" (attached
# to nothing) is a zombie that silently bills $0.08/GB-month forever.
for VOL in $(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER_NAME}" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null); do
  # Delete this zombie disk so its per-GB billing stops.
  echo "Deleting leftover EBS disk: $VOL"
  aws ec2 delete-volume --volume-id "$VOL" --region "$REGION"
done

# ---------- STEP 7: Hunt down orphaned load balancers ----------
# Loop over every modern (ALB/NLB) load balancer left in the region...
for LB_ARN in $(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null); do
  # ...read its tags to see whether it belonged to OUR cluster.
  OWNED=$(aws elbv2 describe-tags --resource-arns "$LB_ARN" --region "$REGION" \
          --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'] | length(@)" --output text 2>/dev/null)
  # If the cluster tag is present, it is a billing zombie: delete it.
  if [ -n "$OWNED" ] && [ "$OWNED" != "0" ] && [ "$OWNED" != "None" ]; then
    echo "Deleting orphaned load balancer: $LB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region "$REGION"
  fi
done
# Same hunt for old-style "Classic" load balancers (older Kafka external
# listeners sometimes created these instead of NLBs).
for LB_NAME in $(aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null); do
  # Read the classic load balancer's tags looking for our cluster's tag.
  OWNED=$(aws elb describe-tags --load-balancer-names "$LB_NAME" --region "$REGION" \
          --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'] | length(@)" --output text 2>/dev/null)
  # If tagged with our cluster, delete it to stop its hourly billing.
  if [ -n "$OWNED" ] && [ "$OWNED" != "0" ] && [ "$OWNED" != "None" ]; then
    echo "Deleting orphaned classic load balancer: $LB_NAME"
    aws elb delete-load-balancer --load-balancer-name "$LB_NAME" --region "$REGION"
  fi
done

# ---------- STEP 8: Delete CloudWatch log groups ----------
# Stored logs bill ~$0.03/GB-month FOREVER until the groups are deleted.
# The first group is the control plane's own logs; the rest are Container
# Insights groups that held the chatty Kafka broker and NiFi app logs.
for LG in "/aws/eks/${CLUSTER_NAME}/cluster" \
          "/aws/containerinsights/${CLUSTER_NAME}/application" \
          "/aws/containerinsights/${CLUSTER_NAME}/dataplane" \
          "/aws/containerinsights/${CLUSTER_NAME}/host" \
          "/aws/containerinsights/${CLUSTER_NAME}/performance"; do
  # Delete this log group (silently skips if it never existed).
  aws logs delete-log-group --log-group-name "$LG" --region "$REGION" 2>/dev/null && echo "Deleted log group: $LG"
done

# ---------- STEP 9 (OPTIONAL): things we do NOT auto-delete ----------
# ECR repositories (your custom NiFi / Kafka Connect images) bill
# $0.10/GB-month. Un-comment and edit the next line to remove one:
# aws ecr delete-repository --repository-name my-custom-nifi --force --region "$REGION"
# EBS snapshots (disk backups) bill ~$0.05/GB-month - list them with:
# aws ec2 describe-snapshots --owner-ids self --region "$REGION"

# ---------- DONE ----------
echo ""
echo "Teardown finished. In the AWS console, double-check for leftovers:"
echo "  EC2 > Load Balancers, Target Groups, Volumes, Elastic IPs"
echo "  VPC > NAT Gateways (only if your VPC was NOT created by eksctl)"
echo "  ECR > old image repositories"
echo "When those pages are empty for this cluster, the meter has stopped."
