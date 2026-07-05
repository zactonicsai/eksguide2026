# Cloud Platform Support Plan — AI & Data Analytics Applications on AWS (Air-Gapped)

**Owner:** Cloud Platform / Cloud Support Team
**Consumers:** AI & Data Analytics application teams (Kafka, OpenSearch, NiFi, PostgreSQL, AI models & agents)
**Environment:** Air-gapped AWS VPCs — no Internet ingress/egress, corp-network-only, internal artifact mirror
**Doc version:** 1.0 — July 2026 (review quarterly; re-verify all versions against the internal approved-software catalog before use)

> **How this document was built and how to use it.** The plan is organized as independent workstreams so multiple engineers (or automation agents) can execute in parallel: (1) Foundation-as-Code, (2) Day-to-Day Operations, (3) Periodic Lifecycle, (4) Zero-Day & Forensics, (5) What-If Runbooks. Section 3 is the master task catalog; every catalog row links conceptually to a runbook or code example later in the document. All examples assume the air-gapped reference architecture in Section 1.

---

## Table of Contents

1. [Scope, Assumptions & Reference Architecture](#1-scope-assumptions--reference-architecture)
2. [Ownership Model (RACI)](#2-ownership-model-raci)
3. [Master Task Catalog — Day-to-Day / Periodic / Zero-Day](#3-master-task-catalog)
4. [Foundation as Code (Terraform + CloudFormation)](#4-foundation-as-code)
5. [Day-to-Day Runbooks & Commands](#5-day-to-day-runbooks)
6. [Periodic Runbooks (AMI, Patching, Upgrades, Backup/DR, Cost, Access)](#6-periodic-runbooks)
7. [Zero-Day Response & Forensics Toolkit](#7-zero-day-response--forensics)
8. [What-If Scenario Analysis (deep-dive runbooks)](#8-what-if-scenarios)
9. [Appendices (endpoint checklist, tagging, cheat sheet)](#9-appendices)

---

## 1. Scope, Assumptions & Reference Architecture

### 1.1 What the Cloud Platform team controls

| Domain | Platform team responsibility |
|---|---|
| **Golden AMIs** | Build, harden, scan, and publish base AMIs (standard + GPU) from EKS-optimized AL2023 parents via EC2 Image Builder; publish AMI IDs to SSM Parameter Store |
| **Patching** | OS patch cadence (AMI rotation for EKS nodes; SSM Patch Manager for standalone EC2), emergency zero-day patching |
| **EKS** | Cluster lifecycle, control-plane upgrades, managed add-ons, managed node groups + Karpenter pools, taints/labels, capacity |
| **Networking** | VPCs, private subnets, Transit Gateway to corp, VPC endpoints, Route 53 private zones + resolver endpoints, security groups, NetworkPolicies baseline. **No IGW, no NAT — ever.** |
| **Identity & RBAC** | IAM roles, EKS access entries, Keycloak (SSO/OIDC) platform, Kubernetes RBAC baseline, EKS Pod Identity for workloads |
| **Supply chain** | Internal registry (Harbor/Artifactory) + ECR replicas, OS/package mirrors, Terraform provider mirror, Helm chart mirror, image/AMI vulnerability scanning |
| **Observability** | CloudWatch, EKS control-plane logs, Prometheus (AMP via VPC endpoint or self-hosted) + self-hosted Grafana, alerting to corp on-call |
| **Cost** | Tagging enforcement, budgets, anomaly detection, CUR/Athena reporting, EKS split cost allocation, right-sizing reviews |
| **Data services (infra layer)** | Amazon OpenSearch domains (the **only** AWS-managed data service) plus the platforms the self-managed services run on: pre-req'd EC2 "data nodes" and EKS capacity for Kafka (Strimzi), NiFi, and PostgreSQL — machine vending, prerequisites, disks, scaling, patching, backup plumbing. Software install/config and app-level content (topics/indices/schemas/flows/models) belong to the data team, with platform support |
| **CI/CD (GitLab)** | GitLab runner fleets inside the VPC (Kubernetes executor on EKS + EC2 autoscaling runners), runner IAM roles & OIDC federation into AWS, S3 job cache, shared pipeline templates and guardrails. The GitLab server itself is corp-hosted; pipeline *content* (`.gitlab-ci.yml`) belongs to the teams |

### 1.2 Air-gap ground rules (apply to every example in this document)

- **No route to the Internet.** VPC route tables contain only local, VPC-endpoint prefix lists, and Transit Gateway routes to corp CIDRs. AWS APIs are reached exclusively through **VPC interface/gateway endpoints** (full checklist in Appendix A).
- **All software comes from the internal mirror.** Container images: `registry.corp.example.com` (Harbor) replicated into **ECR** for in-VPC pulls. OS packages: internal AL2023 dnf mirror. Helm charts, pip/npm/Maven, Terraform providers: Artifactory. Every artifact is vetted, scanned, and signed before promotion.
- **Public image references are rewritten** to the mirror at the containerd layer (`/etc/containerd/certs.d`) so upstream manifests (Strimzi, NiFi, Keycloak, NVIDIA) work unmodified — see §4.6.
- **Humans reach the environment only via corp network** (Transit Gateway / Direct Connect) and administer EC2 via **SSM Session Manager** (no SSH keys, no bastion port 22).
- **Amazon OpenSearch Service is the only AWS-managed data service** (VPC domain — its ENIs live inside your subnets, fully air-gap compatible). Everything else — Kafka, NiFi, PostgreSQL — is self-managed: containerized on EKS (Strimzi, NiFi StatefulSets, CloudNativePG) or on platform-vended EC2 **data nodes**, with all software installed from the internal mirror by the data teams.
- **CI/CD runs inside the gap too.** GitLab (self-managed) lives on the corp network; the platform team operates the **runner fleets inside the VPC** (EKS Kubernetes executor + EC2 autoscaling). Jobs pull images only from ECR, cache to S3 via the gateway endpoint, and reach AWS with **short-lived, per-project IAM roles** (§4.10) — no long-lived cloud keys in CI variables, ever.

### 1.3 Reference architecture

```
Corp Network ──DX/VPN── Transit Gateway ──── ATTACH ────────────────────────────┐
                                                                                │
  ┌─────────────────────────────  VPC data-platform (10.20.0.0/16 + 100.64.0.0/16) 
  │
  │  AZ-a / AZ-b / AZ-c   private subnets only (no IGW/NAT)
  │
  │  ┌ node subnets 10.20.x.0/24 (corp-routable)   ┌ pod subnets 100.64.x.0/18 (CGNAT, non-routable)
  │
  │  EKS "data-platform" (private endpoint, K8s 1.35)
  │   ├─ mng-system      (m7g)      taint: CriticalAddonsOnly    — CoreDNS, controllers, Karpenter
  │   ├─ mng-general     (m7i/r7i)  no taint                     — NiFi, Keycloak, Grafana, agents
  │   ├─ mng-kafka       (r7i)      taint: corp/workload=kafka   — Strimzi brokers + KRaft controllers
  │   ├─ karpenter gpu-inference    taint: nvidia.com/gpu        — vLLM / KServe model serving
  │   └─ karpenter gpu-training     taint: nvidia.com/gpu        — fine-tuning / batch jobs
  │
  │  Self-managed data services (software from the mirror, installed/configured by data teams):
  │   ├─ Kafka 4.0.x  — Strimzi 0.4x on EKS (KRaft)   ─or─  EC2 data-node fleet (tarball install)
  │   ├─ Apache NiFi 2.x — StatefulSet on EKS          ─or─  EC2 data-node fleet
  │   └─ PostgreSQL 17 — CloudNativePG on EKS          ─or─  EC2 data nodes + Patroni
  │
  │  EC2 "data node" fleet: golden AMI + role prereqs (JDK 21, XFS data volumes, sysctl,
  │   ulimits, systemd templates) — machines vended by platform, software installed by teams
  │
  │  AWS-managed (the ONLY one): Amazon OpenSearch Service 2.19/3.x — VPC domain, 3 AZ,
  │   dedicated masters
  │
  │  CI/CD: GitLab (corp, over TGW) ⇐ runner fleets in-VPC — K8s executor on EKS (ns ci-jobs)
  │         + EC2 autoscaling runners (fleeting/ASG, golden AMI); jobs assume per-team IAM roles
  │
  │  Supply chain: Harbor (EC2/EKS) ⇒ ECR replicas ⇒ nodes pull via ecr.dkr endpoint
  │  VPC endpoints: s3(gw), ecr.api, ecr.dkr, ec2, sts, eks, eks-auth, ssm, ssmmessages,
  │                 ec2messages, logs, monitoring, elasticloadbalancing, autoscaling,
  │                 kms, secretsmanager, aps-workspaces, guardduty-data
  └────────────────────────────────────────────────────────────────────────────┘
```

**Design decisions worth calling out**

- **Self-managed by policy — OpenSearch is the single AWS-managed exception.** Kafka, NiFi, and PostgreSQL run either containerized on EKS (Strimzi, NiFi StatefulSets, CloudNativePG — operators/images from the mirror) or on platform-vended EC2 **data nodes**: hardened golden-AMI instances delivered with every prerequisite in place (JDK, tuned kernel, XFS data volumes, ulimits, systemd templates, agents) so the data teams can install and configure Kafka/NiFi/Postgres themselves from Artifactory (§4.9). Patching *both* paths is a platform responsibility (§6.2–§6.3).
- **Custom networking for pods** (VPC CNI `ENIConfig` with a `100.64.0.0/16` secondary CIDR) preserves scarce corp-routable IP space — only nodes and load balancers consume corp-routable addresses.
- **Two node-provisioning systems on purpose**: managed node groups for the always-on baseline (system, general, kafka) and **Karpenter 1.x** for elastic GPU capacity, both pinned to the same golden AMI via tags.
- **Break-glass access is IAM-based** (EKS access entries), deliberately independent of Keycloak, so an IdP outage never locks out platform admins (see What-If 8.8).

### 1.4 Version matrix (verify at execution time — internal catalog is authoritative)

| Component | Version used in examples | Notes |
|---|---|---|
| Amazon EKS | **1.35** (1.36 rolling out) | AL2 AMIs ended at 1.32 — AL2023/Bottlerocket only from 1.33+. In-place upgrades can be rolled back within 7 days |
| Node OS | AL2023 EKS-optimized (standard + NVIDIA variants), containerd 2.x | Custom AMIs built on these parents |
| Karpenter | 1.x (`karpenter.sh/v1`) | Images/charts from mirror |
| Apache Kafka | 4.0.x (KRaft) via **Strimzi 0.4x** on EKS, or tarball on EC2 data nodes | 4.x requires Java 17+; drops clients < 2.1 |
| OpenSearch Service | 2.19 / 3.x | VPC domain, FGAC on |
| PostgreSQL | 17.x self-managed — **CloudNativePG 1.2x** on EKS, or EC2 + Patroni | Majors via logical-replication blue/green |
| Java runtime | Amazon Corretto 21 (17 minimum) from internal dnf mirror | Prerequisite on every data node |
| Apache NiFi | 2.x (self-hosted on EKS) | Image from mirror |
| Keycloak | 26.x | OIDC IdP for EKS + apps |
| Terraform | ≥ 1.10 (S3-native state locking) + AWS provider ~> 6.0 | Providers from internal mirror |
| AWS CLI | v2 (current) | Via internal installer repo |
| GitLab + Runner | Self-managed GitLab (corp-hosted); **runner minor tracks the GitLab minor** — chart + helper image from the mirror | Helper image pinned to ECR (§4.10) |

---

## 2. Ownership Model (RACI)

| Activity | Platform | Data team | Security | Notes |
|---|---|---|---|---|
| Golden AMI build/patch/publish | **R/A** | I | C | Security signs off scan results |
| EKS cluster & node group lifecycle | **R/A** | C | I | Data team consulted on maintenance windows |
| Taints/labels/capacity requests | **R/A** | **R** (requests) | I | Via ticket + Terraform PR |
| OpenSearch domain lifecycle (the one managed service) | **R/A** | C | I | |
| Data-node EC2 vending, prereqs, disks, patching; EKS capacity for Strimzi/CNPG/NiFi | **R/A** | C | I | Machines & prereqs = platform |
| Kafka / NiFi / Postgres software install, configuration, version choice | C | **R/A** | I | From the mirror only; platform supports |
| Topics, indices, schemas, NiFi flows, models, agents | C | **R/A** | I | Platform supports, doesn't own content |
| Image vetting into mirror | **R/A** | R (requests) | **A** (approval) | Nothing enters the mirror unscanned |
| RBAC / Keycloak groups | **R/A** | R (requests) | C | Quarterly access review joint |
| Incident response — infra layer | **R/A** | C | C | |
| Zero-day containment & forensics | **R** | C | **A** | Security leads, platform executes |
| Cost monitoring & showback | **R/A** | R (optimize own workloads) | I | |
| GitLab runner fleets (EKS + EC2), runner IAM/OIDC, S3 cache | **R/A** | C | C | Runner infra & identity = platform |
| Pipeline definitions (`.gitlab-ci.yml`), project CI config | C | **R/A** | I | Platform provides templates + review |
| CI deploy roles per team (scope, trust conditions) | **R/A** | R (requests) | C | Least-priv; audited with §6.11 |

---

## 3. Master Task Catalog

### 3.1 Day-to-Day (every business day, some automated + reviewed)

| # | Domain | Task | Tooling | Runbook |
|---|---|---|---|---|
| D1 | EKS | Morning health sweep: control-plane insights, node group health, NotReady nodes, pending pods, restart hot-spots, PDB blockers | AWS CLI + kubectl script | §5.1 |
| D2 | EKS | Triage workload tickets: ImagePullBackOff, Pending (taints/GPU), CrashLoop/OOM, evictions | kubectl, crictl via node debug | §5.2 |
| D3 | EKS | Node lifecycle hygiene: drain/recycle unhealthy nodes, verify replacements join | kubectl + EC2/ASG CLI | §5.3 |
| D4 | Kafka | Strimzi operator + broker/controller pod health, under-replicated partitions, PVC/disk %, consumer-group lag; EC2 brokers: service state + `/data` disk | kubectl + kafka CLI + Prometheus/SSM | §5.4 |
| D5 | OpenSearch | Cluster color, shard health, JVM pressure, storage headroom, ISM failures | CLI + `_cluster`/`_cat` APIs | §5.5 |
| D6 | Postgres | CNPG cluster/replica status, connections vs max, WAL & data disk %, top SQL (`pg_stat_statements`), replication lag; EC2 fleet the same via SSM | kubectl cnpg + psql + SSM | §5.6 |
| D7 | NiFi | Backpressure/queued counts, bulletin errors, content/provenance repo disk | NiFi REST API + kubectl | §5.7 |
| D8 | AI/GPU | Device-plugin health, allocatable GPUs, DCGM utilization, model-serving latency/queue, idle-GPU flag | kubectl + Prometheus | §5.8 |
| D9 | Identity | Keycloak health/readiness, failed-login spikes, expiring realm certs | kcadm + health endpoint | §5.9 |
| D10 | Identity | Fulfil access requests (Keycloak group, EKS access entry, namespace RBAC) with verification | kcadm + eks CLI + kubectl | §5.10 |
| D11 | Supply chain | Mirror→ECR replication status, new CRITICAL scan findings on promoted images | Harbor API + Inspector/ECR | §5.11 |
| D12 | Cost | Anomaly feed review, yesterday's spend by service, GPU utilization vs spend | Cost Explorer CLI | §5.12 |
| D13 | Networking | VPC endpoint health alarms, TGW attachment state, DNS resolver metrics | CloudWatch | §5.1 (sweep) |
| D14 | Backups | Verify last night's backup jobs (AWS Backup/EBS, Velero, CNPG barman, OpenSearch snapshots) succeeded | AWS Backup CLI / velero / kubectl | §5.1 (sweep) |
| D15 | Data-node EC2 | Fleet heartbeat (SSM ping), `/data` disk & memory alarms, failed systemd units, prereq-association compliance | SSM + CloudWatch agent | §5.13 |
| D16 | CI/CD | Runner fleet health (pods/ASG), offline/stale runners in GitLab, job-queue latency, S3 cache reachability | kubectl + GitLab API + Prometheus | §5.14 |

### 3.2 Periodic

| # | Cadence | Task | Runbook |
|---|---|---|---|
| P1 | Monthly (or on CVE) | Rebuild golden AMIs (standard + GPU) from latest EKS-optimized parents; scan; canary; publish to SSM | §6.1 |
| P2 | Monthly | Roll AMIs across all node groups / Karpenter pools (canary → waves), verify, keep rollback LT version | §6.2 |
| P3 | Monthly | SSM Patch Manager windows for the EC2 estate — data-node fleets (Kafka/NiFi/Postgres, **service-aware** orchestration) + utility hosts (Harbor); compliance report | §6.3 |
| P4 | Weekly | Review Inspector/ECR findings backlog with data team; schedule image rebuilds | §5.11/§7.1 |
| P5 | Quarterly | EKS minor upgrade: insights pre-flight → control plane → add-ons → node AMIs → data-plane roll | §6.4 |
| P6 | Semi-annual / as released | Kafka upgrade support: Strimzi operator + Kafka CR `version`/`metadataVersion` bump (operator rolls brokers); EC2 tarball rolling upgrade with the data team | §6.5 |
| P7 | Semi-annual | OpenSearch engine upgrade (dry-run check → snapshot → upgrade) | §6.6 |
| P8 | Quarterly / annual | Postgres upgrade support: CNPG minor image roll; majors via logical-replication blue/green (or `pg_upgrade` on EC2) | §6.7 |
| P9 | Quarterly | **DR drill**: CNPG barman point-in-time restore, EBS-snapshot restore of a data node, OpenSearch snapshot restore, Velero namespace restore — timed & documented | §6.8 |
| P10 | Quarterly | Certificate & secret rotation audit (ACM PCA issued certs, Secrets Manager rotation status, Keycloak realm keys) | §6.9 |
| P11 | Monthly | Cost review: CUR/Athena by team tag, inter-AZ transfer, idle GPU, unattached EBS/old snapshots, budgets refresh | §6.10 |
| P12 | Quarterly | Access review: EKS access entries + Keycloak groups + ClusterRoleBindings vs HR feed; remove leavers | §6.11 |
| P13 | Quarterly | Capacity & right-sizing: node group utilization, PVC growth, Kafka partition/storage forecast, OpenSearch shard strategy | §6.12 |
| P14 | Monthly | Karpenter/add-on/chart version bumps from mirror (vpc-cni, coredns, ebs-csi, pod-identity-agent, device plugin) | §6.4 (add-ons) |
| P15 | Quarterly | Game-day: execute one What-If scenario from §8 as a drill | §8 |
| P16 | On request / AMI cycle | Vend new data-node EC2 (Terraform module) and rebuild existing ones onto the current golden AMI (blue/green per node) | §4.9.2 / §6.3 |
| P17 | With each GitLab upgrade / quarterly | Runner chart + fleeting-AMI upgrade behind a canary-pipeline gate; runner token rotation; CI deploy-role audit (CloudTrail sessions by `gl-` prefix) | §6.13 |

### 3.3 Zero-Day / Emergency

| # | Phase | Task | Runbook |
|---|---|---|---|
| Z1 | Intake | Receive advisory (internal CERT), classify severity, map to affected layer (kernel/OS, runtime, K8s, app image, managed service, model artifact) | §7.1–7.2 |
| Z2 | Assess | Fleet exposure: SSM inventory, Inspector findings, ECR image scans, running-pod image census | §7.1 |
| Z3 | Contain | Interim mitigations (seccomp/caps, NetworkPolicy, feature flags, taint & drain exposed pools) | §7.3–7.4 |
| Z4 | Remediate — infra | Emergency AMI build fast-path → canary → accelerated fleet roll (target < 72h fleet-wide) | §7.3 |
| Z5 | Remediate — app | Rebuild affected images in mirror pipeline; coordinate data-team redeploys | §7.2 |
| Z6 | Compromise IR | Quarantine node/pod, preserve evidence (EBS snapshots, memory, logs), revoke credentials | §7.5 |
| Z7 | Forensics | Audit-log, flow-log, CloudTrail, GuardDuty timeline reconstruction | §7.5 |
| Z8 | Recover & report | Replace infrastructure, rotate secrets, restore service, post-incident report | §7.5–7.6 |

---
## 4. Foundation as Code

Everything below is the baseline the runbooks assume. Terraform is the system of record; CloudFormation is used where its lifecycle model fits better (VPC endpoints stack, Image Builder pipeline, SSM patching) or where teams already operate CFN.

### 4.1 Terraform in an air gap

`registry.terraform.io` is unreachable. Point the CLI at the internal provider mirror and use S3-native state locking (Terraform ≥ 1.10 — no DynamoDB table needed).

```hcl
# ~/.terraformrc (or TF_CLI_CONFIG_FILE) on runners and workstations
provider_installation {
  network_mirror {
    url = "https://artifacts.corp.example.com/artifactory/api/terraform/tf-mirror/providers/"
  }
  direct {
    exclude = ["*/*"]   # never attempt registry.terraform.io
  }
}
```

```hcl
# versions.tf — every stack
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "corp-tfstate-data-platform"   # reached via the S3 gateway endpoint
    key          = "data-platform/eks/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "alias/tfstate"
    use_lockfile = true                            # S3-native locking (TF 1.10+)
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      "corp:team"        = "cloud-platform"
      "corp:environment" = "prod"
      "corp:cost-center" = "CC-4211"
      "corp:managed-by"  = "terraform"
    }
  }
}
```

> Also mirror **AWS CLI v2**, kubectl, helm, and eksctl installers into Artifactory; nodes and CI runners must never fetch tooling from the Internet.

### 4.2 Network foundation — Terraform (no Internet, corp-only)

```hcl
locals {
  vpc_cidr      = "10.20.0.0/16"      # corp-routable (nodes, NLBs, service ENIs)
  pod_cidr      = "100.64.0.0/16"     # CGNAT space for pods — NOT advertised to corp
  azs           = ["us-east-1a", "us-east-1b", "us-east-1c"]
  corp_cidrs    = ["10.0.0.0/8"]      # reachable via Transit Gateway
  cluster_name  = "data-platform"
}

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "vpc-data-platform" }
}

# Secondary CIDR so pods don't consume corp-routable space
resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  vpc_id     = aws_vpc.this.id
  cidr_block = local.pod_cidr
}

resource "aws_subnet" "node" {
  for_each          = { for i, az in local.azs : az => i }
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, each.value)          # 10.20.0/24, 10.20.1/24, ...
  tags = {
    Name                                          = "node-${each.key}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "karpenter.sh/discovery"                      = local.cluster_name
  }
}

resource "aws_subnet" "pod" {
  for_each          = { for i, az in local.azs : az => i }
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(local.pod_cidr, 2, each.value)          # 100.64.0/18 per AZ
  depends_on        = [aws_vpc_ipv4_cidr_block_association.pods]
  tags              = { Name = "pod-${each.key}" }
}

# Transit Gateway attachment — the ONLY way out of the VPC
resource "aws_ec2_transit_gateway_vpc_attachment" "corp" {
  transit_gateway_id = var.corp_tgw_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = [for s in aws_subnet.node : s.id]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "rt-private-data-platform" }
}

# Corp routes only. NOTE: there is deliberately no 0.0.0.0/0 route anywhere.
resource "aws_route" "to_corp" {
  for_each               = toset(local.corp_cidrs)
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = each.value
  transit_gateway_id     = var.corp_tgw_id
}

resource "aws_route_table_association" "node" {
  for_each       = aws_subnet.node
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "pod" {
  for_each       = aws_subnet.pod
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Flow logs — required evidence source for forensics (§7.5)
resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = var.flowlogs_bucket_arn
  max_aggregation_interval = 60
}

# Corp DNS integration: on-prem resolvers can resolve VPC endpoints & private zones
resource "aws_route53_resolver_endpoint" "inbound" {
  name               = "corp-inbound"
  direction          = "INBOUND"
  security_group_ids = [aws_security_group.resolver.id]
  dynamic "ip_address" {
    for_each = aws_subnet.node
    content { subnet_id = ip_address.value.id }
  }
}
```

### 4.3 VPC endpoints — CloudFormation (the air-gap lifeline)

Every AWS API the platform touches needs an endpoint. `Fn::ForEach` (LanguageExtensions transform) keeps the template short.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: 'AWS::LanguageExtensions'
Description: >-
  VPC endpoints for the air-gapped data platform. Without these, nothing works:
  no image pulls, no node joins, no SSM sessions, no logs, no metrics.

Parameters:
  VpcId:            { Type: 'AWS::EC2::VPC::Id' }
  EndpointSubnets:  { Type: 'List<AWS::EC2::Subnet::Id>' }
  PrivateRouteTables: { Type: CommaDelimitedList }
  VpcCidr:          { Type: String, Default: 10.20.0.0/16 }
  PodCidr:          { Type: String, Default: 100.64.0.0/16 }

Resources:
  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: HTTPS from nodes and pods to AWS service endpoints
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: !Ref VpcCidr }
        - { IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: !Ref PodCidr }

  # S3 is a GATEWAY endpoint — free, attached to route tables.
  # Carries: ECR image layers, AMI/package artifacts, flow logs, backups, model weights.
  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcEndpointType: Gateway
      ServiceName: !Sub com.amazonaws.${AWS::Region}.s3
      VpcId: !Ref VpcId
      RouteTableIds: !Ref PrivateRouteTables

  # Interface endpoints, one per service (logical IDs derived via &{})
  'Fn::ForEach::Endpoints':
    - Service
    - - ec2
      - ecr.api          # ECR auth/API
      - ecr.dkr          # ECR image pulls
      - sts              # IRSA / credential vending
      - eks              # aws eks CLI/API
      - eks-auth         # EKS Pod Identity
      - elasticloadbalancing
      - autoscaling
      - logs             # CloudWatch Logs
      - monitoring       # CloudWatch metrics
      - ssm
      - ssmmessages      # Session Manager
      - ec2messages
      - kms
      - secretsmanager
      - aps-workspaces   # Amazon Managed Prometheus (optional)
      - guardduty-data   # GuardDuty Runtime Monitoring
    - 'Endpoint&{Service}':
        Type: AWS::EC2::VPCEndpoint
        Properties:
          VpcEndpointType: Interface
          ServiceName: !Sub 'com.amazonaws.${AWS::Region}.${Service}'
          VpcId: !Ref VpcId
          SubnetIds: !Ref EndpointSubnets
          SecurityGroupIds: [ !Ref EndpointSecurityGroup ]
          PrivateDnsEnabled: true

Outputs:
  EndpointSg: { Value: !Ref EndpointSecurityGroup }
```

```bash
aws cloudformation deploy \
  --template-file vpc-endpoints.yaml \
  --stack-name data-platform-vpc-endpoints \
  --parameter-overrides VpcId=vpc-0abc... \
      "EndpointSubnets=subnet-a,subnet-b,subnet-c" \
      "PrivateRouteTables=rtb-0123..." \
  --capabilities CAPABILITY_AUTO_EXPAND
```

### 4.4 EKS cluster — Terraform (private endpoint, API auth mode, full audit logging)

```hcl
resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = [for s in aws_subnet.node : s.id]
    endpoint_private_access = true
    endpoint_public_access  = false            # air gap: API server reachable from corp only
    security_group_ids      = [aws_security_group.cluster.id]
  }

  access_config {
    authentication_mode                         = "API"   # access entries only; no aws-auth ConfigMap
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider { key_arn = aws_kms_key.eks.arn }
    resources = ["secrets"]
  }

  # api + audit are mandatory forensic evidence (§7.5); keep all five on
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  upgrade_policy { support_type = "STANDARD" }  # forces upgrade discipline; EXTENDED costs more
}

# Pinned managed add-ons — versions come from the internal change calendar
locals {
  addons = {
    vpc-cni = {
      version = "v1.20.x-eksbuild.y"
      config = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"   # pods on 100.64/16 subnets
          ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
        }
      })
    }
    coredns                = { version = "v1.12.x-eksbuild.y", config = null }
    kube-proxy             = { version = "v1.35.x-eksbuild.y", config = null }
    eks-pod-identity-agent = { version = "v1.3.x-eksbuild.y",  config = null }
    aws-ebs-csi-driver     = { version = "v1.5x.x-eksbuild.y", config = null }
  }
}

resource "aws_eks_addon" "this" {
  for_each                    = local.addons
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value.version
  configuration_values        = each.value.config
  resolve_conflicts_on_update = "PRESERVE"
}
```

`ENIConfig` per AZ (applied once, tells the CNI to place pod ENIs in the 100.64 subnets):

```yaml
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: us-east-1a                # must match the zone label value
spec:
  subnet: subnet-POD-A
  securityGroups: [sg-pods-default]
```

### 4.5 Managed node groups with **custom AMIs, taints and labels** — Terraform

The AMI ID comes from an SSM parameter the Image Builder pipeline publishes (§6.1). With a custom AMI (`ami_type = "CUSTOM"`), EKS does **not** inject bootstrap — the launch template must carry full AL2023 `nodeadm` user data.

```hcl
# AMI IDs published by the golden-AMI pipeline
data "aws_ssm_parameter" "ami_standard" { name = "/corp/ami/eks/1.35/al2023/standard/current" }
data "aws_ssm_parameter" "ami_gpu"      { name = "/corp/ami/eks/1.35/al2023/nvidia/current" }

locals {
  nodeadm_userdata = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${aws_eks_cluster.this.name}
        apiServerEndpoint: ${aws_eks_cluster.this.endpoint}
        certificateAuthority: ${aws_eks_cluster.this.certificate_authority[0].data}
        cidr: ${aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr}
      kubelet:
        config:
          shutdownGracePeriod: 60s
          serializeImagePulls: false
    --BOUNDARY--
  EOT
  )
}

resource "aws_launch_template" "general" {
  name_prefix   = "eks-general-"
  image_id      = data.aws_ssm_parameter.ami_standard.value
  user_data     = local.nodeadm_userdata
  ebs_optimized = true

  metadata_options {                       # IMDSv2 only, hop limit 1: pods cannot steal node creds
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 120
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = aws_kms_key.ebs.arn
    }
  }
  monitoring { enabled = true }
  tag_specifications {
    resource_type = "instance"
    tags = { Name = "eks-general", "corp:patch-group" = "eks-nodes" }
  }
}

resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "mng-general"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [for s in aws_subnet.node : s.id]
  ami_type        = "CUSTOM"
  instance_types  = ["m7i.2xlarge"]

  launch_template {
    id      = aws_launch_template.general.id
    version = aws_launch_template.general.latest_version
  }

  scaling_config {
    min_size     = 3
    desired_size = 4
    max_size     = 12
  }
  update_config  { max_unavailable_percentage = 25 }   # rolling-update blast radius

  labels = { "corp/workload" = "general" }
}

# Dedicated pool for Strimzi Kafka brokers + KRaft controllers — tainted so only Kafka lands here.
# Stateful: max one node disrupted at a time; Strimzi's PodDisruptionBudget adds a second guard.
resource "aws_eks_node_group" "kafka" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "mng-kafka"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [for s in aws_subnet.node : s.id]
  ami_type        = "CUSTOM"
  instance_types  = ["r7i.2xlarge"]

  launch_template {
    id      = aws_launch_template.kafka.id            # same pattern as "general" above
    version = aws_launch_template.kafka.latest_version
  }

  scaling_config {
    min_size     = 6                                   # 3 brokers + 3 controllers, one per AZ
    desired_size = 6
    max_size     = 12
  }
  update_config { max_unavailable = 1 }                # stateful: one node at a time

  labels = { "corp/workload" = "kafka" }
  taint {
    key    = "corp/workload"
    value  = "kafka"
    effect = "NO_SCHEDULE"
  }
}
```

Matching workload spec on the data-team side:

```yaml
tolerations:
  - { key: corp/workload, operator: Equal, value: kafka, effect: NoSchedule }
nodeSelector:
  corp/workload: kafka
# (For Strimzi these land in the Kafka CR pod template — see §4.9.1)
```

### 4.6 Air-gap image pulls — containerd mirror rewrite (baked into the AMI)

EKS AL2023 AMIs already set `config_path = "/etc/containerd/certs.d"`. The golden AMI drops `hosts.toml` files so that *any* public reference in a mirrored manifest resolves internally — no chart or YAML edits needed:

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://registry.corp.example.com/v2/dockerhub-proxy"]
  capabilities = ["pull", "resolve"]
  override_path = true
```

```toml
# /etc/containerd/certs.d/quay.io/hosts.toml   (Keycloak, Strimzi, ...)
server = "https://quay.io"

[host."https://registry.corp.example.com/v2/quay-proxy"]
  capabilities = ["pull", "resolve"]
  override_path = true
```

Repeat for `registry.k8s.io`, `ghcr.io`, `nvcr.io`, `public.ecr.aws`. The corp CA bundle is baked into the AMI trust store so containerd trusts Harbor. **Runtime pulls should still prefer ECR** (`<acct>.dkr.ecr.<region>.amazonaws.com/...`) — ECR is in-region, HA, and reachable purely via VPC endpoints, so a Harbor outage can't take the cluster down (see What-If 8.1).

### 4.7 Karpenter 1.x — elastic GPU capacity pinned to the golden AMI

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-inference
spec:
  amiFamily: AL2023
  amiSelectorTerms:                      # ONLY approved golden AMIs are eligible
    - tags:
        corp:approved: "true"
        corp:ami-family: "eks-1.35-al2023-nvidia"
  role: KarpenterNodeRole-data-platform
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: data-platform }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: data-platform }
  metadataOptions:
    httpTokens: required
    httpPutResponseHopLimit: 1
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 300Gi, volumeType: gp3, encrypted: true }
  tags:
    corp:workload: gpu-inference
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-inference
spec:
  template:
    metadata:
      labels: { corp/workload: gpu-inference }
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: gpu-inference }
      taints:
        - { key: nvidia.com/gpu, value: "true", effect: NoSchedule }
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
        - { key: node.kubernetes.io/instance-type, operator: In,
            values: ["g6.2xlarge", "g6.4xlarge", "g6e.2xlarge", "p5.4xlarge"] }
      expireAfter: 720h            # nodes never live > 30d → guarantees AMI freshness
  limits:
    nvidia.com/gpu: 32             # hard cost ceiling (see §6.10)
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      - nodes: "20%"                                        # normal churn cap
      - nodes: "0"
        schedule: "0 13 * * 1-5"                            # freeze disruption 13:00–21:00 UTC weekdays
        duration: 8h
        reasons: [Drifted, Underutilized]
```

When the golden-AMI pipeline re-tags a new AMI with `corp:approved=true`, Karpenter detects **drift** and rolls GPU nodes automatically within the disruption budget — that *is* the patching mechanism for this pool.

### 4.8 RBAC & Identity

**Layer 1 — IAM → cluster via EKS access entries** (break-glass and platform paths; survives a Keycloak outage):

```hcl
resource "aws_eks_access_entry" "platform_admins" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::111122223333:role/CloudPlatformAdmin"
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "platform_admins" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.platform_admins.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}

# Data-team CI role: edit rights ONLY in their namespaces
resource "aws_eks_access_entry" "data_ci" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::111122223333:role/DataTeamCI"
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "data_ci" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.data_ci.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
  access_scope {
    type       = "namespace"
    namespaces = ["nifi", "streaming", "ml-inference", "ml-training", "agents"]
  }
}
```

CLI equivalent (used in §5.10 for ad-hoc requests):

```bash
aws eks create-access-entry --cluster-name data-platform \
  --principal-arn arn:aws:iam::111122223333:role/DataAnalyst \
  --type STANDARD --kubernetes-groups corp:data-viewers

aws eks associate-access-policy --cluster-name data-platform \
  --principal-arn arn:aws:iam::111122223333:role/DataAnalyst \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=namespace,namespaces=streaming,namespaces=nifi
```

**Layer 2 — Humans via Keycloak OIDC** (groups-based, self-service through corp SSO):

```hcl
resource "aws_eks_identity_provider_config" "keycloak" {
  cluster_name = aws_eks_cluster.this.name
  oidc {
    identity_provider_config_name = "keycloak"
    issuer_url                    = "https://sso.corp.example.com/realms/data-platform"
    client_id                     = "kubernetes"
    groups_claim                  = "groups"
    groups_prefix                 = "keycloak:"
    username_claim                = "preferred_username"
  }
}
```

```yaml
# Kubernetes RBAC bound to Keycloak groups
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: data-engineers-edit, namespace: streaming }
subjects:
  - { kind: Group, name: "keycloak:data-engineers", apiGroup: rbac.authorization.k8s.io }
roleRef: { kind: ClusterRole, name: edit, apiGroup: rbac.authorization.k8s.io }
```

User kubeconfig (kubelogin binary from the mirror; the issuer is on corp DNS):

```yaml
users:
  - name: sso
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl
        args: [oidc-login, get-token,
               --oidc-issuer-url=https://sso.corp.example.com/realms/data-platform,
               --oidc-client-id=kubernetes, --oidc-extra-scope=groups]
```

**Layer 3 — Workloads via EKS Pod Identity** (needs the `eks-auth` endpoint from §4.3; no OIDC trust-policy sprawl):

```hcl
resource "aws_eks_pod_identity_association" "nifi_s3" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "nifi"
  service_account = "nifi"
  role_arn        = aws_iam_role.nifi_s3_rw.arn   # scoped to the data-lake buckets only
}
```

```bash
# Verify from inside any pod using the SA — no keys anywhere:
kubectl -n nifi exec deploy/nifi -- aws sts get-caller-identity
```

**Keycloak itself** runs on EKS (image `quay.io/keycloak/keycloak:26.x` via mirror), ≥2 replicas with a PDB, backed by a dedicated **CloudNativePG PostgreSQL cluster** (3 instances — §4.9.3), exposed through an internal NLB on corp DNS `sso.corp.example.com`, health-checked on the management port (`:9000/health/ready`). It federates corp LDAP/AD and issues OIDC for EKS, Grafana, NiFi, OpenSearch Dashboards, and the agent platform.

### 4.9 Data services — self-managed baselines (+ the one managed service)

Policy: **only Amazon OpenSearch Service is consumed as a managed AWS service.** Kafka, NiFi, and PostgreSQL are self-managed on two supported paths, both fed exclusively from the internal mirror:

| Path | Platform delivers | Data team delivers |
|---|---|---|
| **EKS (containerized)** | Operators (Strimzi, CloudNativePG), tainted node capacity, StorageClasses, PDB/quota baselines, monitoring scrape | `Kafka`/`KafkaTopic`/`KafkaUser`/`Cluster`/NiFi CRs & config, app tuning |
| **EC2 "data nodes" (VM)** | Hardened golden-AMI instances with **all prerequisites installed and validated** (§4.9.2), disks, SGs, patching | Software install (tarball/rpm from Artifactory), service config, app operations |

```yaml
# StorageClass used by every stateful service below — expansion enabled ON PURPOSE
# (it's the fix path for What-If 8.2 and 8.8)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-data
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  throughput: "250"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain          # data services: never auto-delete volumes
```

#### 4.9.1 Kafka on EKS — Strimzi (KRaft, Kafka 4.0.x)

Operator install (chart + images resolved from the mirror/ECR):

```bash
helm install strimzi corp-helm/strimzi-kafka-operator \
  --version 0.4x.y -n kafka --create-namespace \
  -f strimzi-airgap-values.yaml     # pins image.registry to <acct>.dkr.ecr.us-east-1.amazonaws.com
```

Cluster definition (platform reviews; data team owns topics/users):

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: kafka
  labels: { strimzi.io/cluster: dp }
spec:
  replicas: 3
  roles: [controller]
  storage:
    type: jbod
    volumes:
      - { id: 0, type: persistent-claim, size: 50Gi, class: gp3-data, deleteClaim: false }
  resources:
    requests: { cpu: "1", memory: 4Gi }
    limits:   { memory: 4Gi }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: kafka
  labels: { strimzi.io/cluster: dp }
spec:
  replicas: 3
  roles: [broker]
  storage:
    type: jbod
    volumes:
      - { id: 0, type: persistent-claim, size: 1Ti, class: gp3-data, deleteClaim: false }
  resources:
    requests: { cpu: "4", memory: 24Gi }
    limits:   { memory: 24Gi }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: dp
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 4.0.0
    # metadataVersion is bumped ONLY via the upgrade runbook (§6.5) after soak
    listeners:
      - { name: plain, port: 9092, type: internal, tls: false }   # cluster-internal only
      - { name: tls,   port: 9093, type: internal, tls: true,
          authentication: { type: scram-sha-512 } }
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
      auto.create.topics.enable: false
      log.retention.hours: 72
      # rack-aware follower fetching — the inter-AZ cost fix in What-If 8.9
      replica.selector.class: org.apache.kafka.common.replica.RackAwareReplicaSelector
    rack:
      topologyKey: topology.kubernetes.io/zone
    template:
      pod:
        tolerations:
          - { key: corp/workload, operator: Equal, value: kafka, effect: NoSchedule }
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - { key: corp/workload, operator: In, values: [kafka] }
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom: { configMapKeyRef: { name: kafka-metrics, key: kafka-metrics.yaml } }
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

Data-team self-service objects (namespaced, GitOps-reviewed):

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata: { name: telemetry-raw, namespace: kafka, labels: { strimzi.io/cluster: dp } }
spec:
  partitions: 12
  replicas: 3
  config: { retention.ms: "259200000", compression.type: producer }
```

#### 4.9.2 EC2 "data node" vending — base Linux machines with prerequisites

This is the contract for teams who install Kafka/NiFi/Postgres directly on EC2. The platform vends the machine **ready to receive the software**; the team never needs root-level OS work.

**Terraform module call** (per team request, via PR):

```hcl
module "kafka_brokers_ec2" {
  source = "git::https://git.corp.example.com/platform/tf-data-node.git?ref=v2.4.0"

  role            = "kafka"            # kafka | postgres | nifi  → drives prereqs, SG, ports
  name_prefix     = "analytics-kafka"
  instance_count  = 3                  # one per AZ
  instance_type   = "r7i.2xlarge"
  data_volume_gib = 2000               # dedicated gp3 volume → /data (XFS)
  ami_id          = data.aws_ssm_parameter.ami_standard.value
  subnet_ids      = [for s in aws_subnet.node : s.id]
  team            = "data-analytics"   # tags: corp:team, corp:role, corp:patch-group=datanode-kafka
}
```

The module creates: launch template (IMDSv2, encrypted gp3 root + data volume), instances spread across AZs, role-specific security group (e.g. 9092/9093 from app subnets only), instance profile (SSM core + CloudWatch agent + role-scoped S3), CloudWatch disk/memory alarms, **and an SSM State Manager association** that applies and continuously re-applies the prerequisite document below (drift shows up as association non-compliance — checked daily in §5.13).

**Prerequisite document — CloudFormation** (the actual "configure base Linux machines" artifact):

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: corp-datanode-prereqs — prepares a golden-AMI instance for team-installed data software

Resources:
  DataNodePrereqs:
    Type: AWS::SSM::Document
    Properties:
      Name: corp-datanode-prereqs
      DocumentType: Command
      DocumentFormat: YAML
      UpdateMethod: NewVersion
      Content:
        schemaVersion: '2.2'
        description: Install and enforce prerequisites for self-managed Kafka/NiFi/Postgres
        parameters:
          Role:
            type: String
            allowedValues: [kafka, nifi, postgres]
        mainSteps:
          - action: aws:runShellScript
            name: prereqs
            inputs:
              runCommand:
                - |
                  #!/usr/bin/env bash
                  set -euo pipefail
                  ROLE="{{ Role }}"

                  # 1. Packages — internal mirror only (AL2023 repos are S3-backed and reachable
                  #    via the S3 gateway endpoint; corp policy may still pin to Artifactory)
                  dnf -y install java-21-amazon-corretto-headless chrony jq lvm2

                  # 2. Dedicated data volume → /data (XFS, noatime)
                  DEV=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | grep -v "$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')" | head -1)
                  if ! blkid "$DEV" >/dev/null 2>&1; then mkfs.xfs -f "$DEV"; fi
                  mkdir -p /data
                  grep -q '/data' /etc/fstab || echo "UUID=$(blkid -s UUID -o value $DEV) /data xfs defaults,noatime,nofail 0 2" >> /etc/fstab
                  mountpoint -q /data || mount /data

                  # 3. Kernel & limits tuning
                  cat > /etc/sysctl.d/90-datanode.conf <<'SYSCTL'
                  vm.swappiness = 1
                  vm.max_map_count = 262144
                  vm.dirty_ratio = 60
                  net.core.somaxconn = 4096
                  net.ipv4.tcp_max_syn_backlog = 4096
                  fs.file-max = 2097152
                  SYSCTL
                  sysctl --system >/dev/null
                  cat > /etc/security/limits.d/90-datanode.conf <<LIMITS
                  ${ROLE} soft nofile 262144
                  ${ROLE} hard nofile 262144
                  ${ROLE} soft nproc  65536
                  ${ROLE} hard nproc  65536
                  LIMITS

                  # 4. Transparent Huge Pages off (Kafka/Postgres best practice)
                  echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
                  swapoff -a || true

                  # 5. Service user + layout the team will install into
                  id "$ROLE" >/dev/null 2>&1 || useradd -r -m -d /opt/$ROLE -s /sbin/nologin $ROLE
                  mkdir -p /data/$ROLE /var/log/$ROLE
                  chown -R $ROLE:$ROLE /data/$ROLE /var/log/$ROLE /opt/$ROLE

                  # 6. systemd unit skeleton (team fills ExecStart/Environment)
                  cat > /etc/systemd/system/${ROLE}.service <<UNIT
                  [Unit]
                  Description=${ROLE} (team-managed data service)
                  After=network-online.target
                  [Service]
                  User=${ROLE}
                  EnvironmentFile=-/etc/sysconfig/${ROLE}
                  ExecStart=/opt/${ROLE}/current/bin/start.sh
                  LimitNOFILE=262144
                  Restart=on-failure
                  RestartSec=5
                  [Install]
                  WantedBy=multi-user.target
                  UNIT
                  systemctl daemon-reload

                  # 7. Preflight validator the team runs before installing
                  cat > /opt/corp/preflight.sh <<'PRE'
                  #!/usr/bin/env bash
                  R=${1:?role}; ok(){ echo "PASS  $*"; }; bad(){ echo "FAIL  $*"; RC=1; }; RC=0
                  java -version 2>&1 | grep -q '21\.' && ok java21 || bad java21
                  mountpoint -q /data && ok /data-mounted || bad /data-mounted
                  [ "$(cat /proc/sys/vm/swappiness)" -le 1 ] && ok swappiness || bad swappiness
                  grep -q '\[never\]\|never$' /sys/kernel/mm/transparent_hugepage/enabled && ok thp-off || bad thp-off
                  sudo -u $R bash -c 'ulimit -n' | grep -q 262144 && ok nofile || bad nofile
                  timedatectl show -p NTPSynchronized --value | grep -q yes && ok ntp || bad ntp
                  getent hosts artifacts.corp.example.com >/dev/null && ok mirror-dns || bad mirror-dns
                  exit $RC
                  PRE
                  chmod +x /opt/corp/preflight.sh
                  echo "PREREQS-OK role=$ROLE"
```

```bash
aws cloudformation deploy --template-file datanode-prereqs.yaml --stack-name corp-datanode-prereqs

# Ad-hoc (re)apply + validate on a fleet:
aws ssm send-command --document-name corp-datanode-prereqs \
  --parameters Role=kafka \
  --targets Key=tag:corp:role,Values=kafka \
  --comment "re-apply kafka prereqs"

# Team-side, before installing the tarball:
sudo /opt/corp/preflight.sh kafka && echo "machine ready — install away"
```

**Handover contract**

| Platform guarantees (SLO'd) | Team owns after handover |
|---|---|
| Golden AMI currency + OS patching (§6.3), SSM/CW agents, prereqs enforced by State Manager, `/data` sized/expandable, SG opened per role, DNS records, disk/mem alarms wired to team channel | Downloading Kafka/NiFi/Postgres from Artifactory, service config, `systemctl enable --now kafka`, app-level monitoring, capacity requests via PR |

#### 4.9.3 PostgreSQL — CloudNativePG on EKS

Platform runs CNPG clusters for shared services (Keycloak, Grafana); data teams request their own via the same CR pattern. EC2 + Patroni is the VM alternative and rides the §4.9.2 vending pattern (`role = "postgres"`).

```bash
helm install cnpg corp-helm/cloudnative-pg --version 0.2x.y -n cnpg-system --create-namespace \
  -f cnpg-airgap-values.yaml
```

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-db
  namespace: keycloak
spec:
  instances: 3
  imageName: 111122223333.dkr.ecr.us-east-1.amazonaws.com/mirrored/cloudnative-pg/postgresql:17.5
  primaryUpdateStrategy: unsupervised     # operator performs switchover on rolling updates
  minSyncReplicas: 1
  maxSyncReplicas: 1
  storage:    { size: 100Gi, storageClass: gp3-data }
  walStorage: { size: 20Gi,  storageClass: gp3-data }
  postgresql:
    parameters:
      max_connections: "400"
      shared_preload_libraries: "pg_stat_statements"
      idle_in_transaction_session_timeout: "300000"
      log_min_duration_statement: "500"
  monitoring: { enablePodMonitor: true }
  backup:
    barmanObjectStore:                    # S3 via the gateway endpoint — air-gap safe
      destinationPath: s3://corp-db-backups/keycloak
      s3Credentials: { inheritFromIAMRole: true }   # EKS Pod Identity on the cluster SA
      wal: { compression: gzip }
    retentionPolicy: "14d"
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata: { name: keycloak-db-nightly, namespace: keycloak }
spec:
  cluster: { name: keycloak-db }
  schedule: "0 0 5 * * *"                 # 05:00 UTC daily
  backupOwnerReference: self
```

#### 4.9.4 Amazon OpenSearch Service — the managed exception (Terraform)

```hcl
resource "aws_opensearch_domain" "main" {
  domain_name    = "data-search"
  engine_version = "OpenSearch_2.19"       # verify latest supported (3.x track available)

  cluster_config {
    instance_type            = "r7g.xlarge.search"
    instance_count           = 6
    zone_awareness_enabled   = true
    dedicated_master_enabled = true
    dedicated_master_type    = "m7g.large.search"
    dedicated_master_count   = 3
    zone_awareness_config {
      availability_zone_count = 3
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 512
    volume_type = "gp3"
    throughput  = 250
  }

  vpc_options {
    subnet_ids         = [for s in aws_subnet.node : s.id]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = aws_kms_key.os.key_id
  }
  node_to_node_encryption { enabled = true }
  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-PFS-2023-10"
  }

  advanced_security_options {              # FGAC; Dashboards SSO via Keycloak SAML/OIDC
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = "os-admin"
      master_user_password = var.os_admin_pw
    }
  }

  log_publishing_options {
    log_type                 = "ES_APPLICATION_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.os.arn
  }

  software_update_options { auto_software_update_enabled = false }  # we schedule these (§6.6/§7.2)
}
```

### 4.10 GitLab CI/CD — cloud runners and IAM roles

GitLab (server) is corp-hosted and reached over the TGW; **everything that executes lives in the VPC** and follows every rule above: images from ECR only, cache to S3 through the gateway endpoint, hosts on the golden AMI, no internet.

#### 4.10.1 Kubernetes-executor fleet on EKS

```yaml
# corp-helm/gitlab-runner — values-airgap.yaml (chart + images mirrored)
gitlabUrl: https://gitlab.corp.example.com
rbac: { create: true }
serviceAccount: { name: gitlab-runner }        # EKS Pod Identity → role "ci-runner-base" (4.10.3)
runners:
  secret: gitlab-runner-token                  # runner AUTHENTICATION token (created in GitLab, stored as k8s Secret)
  config: |
    concurrent = 30
    check_interval = 3
    [[runners]]
      executor = "kubernetes"
      [runners.kubernetes]
        namespace = "ci-jobs"
        service_account = "ci-job"
        image = "111122223333.dkr.ecr.us-east-1.amazonaws.com/tools/ci-base:al2023"
        # CRITICAL air-gap pin — the default helper pulls from registry.gitlab.com and hangs forever.
        # Keep the tag in lockstep with the chart version (§6.13):
        helper_image = "111122223333.dkr.ecr.us-east-1.amazonaws.com/mirrored/gitlab-org/gitlab-runner-helper:x86_64-v<runner-version>"
        pull_policy = ["if-not-present"]
        privileged = false                     # no docker-in-docker — image builds use kaniko → Harbor
        [runners.kubernetes.node_selector]
          "corp/workload" = "general"
      [runners.cache]
        Type = "s3"
        Shared = true
        [runners.cache.s3]
          ServerAddress = "s3.us-east-1.amazonaws.com"   # rides the S3 gateway endpoint
          BucketName = "corp-ci-cache"                   # lifecycle: expire objects after 14d
          BucketLocation = "us-east-1"
          AuthenticationType = "iam"
```

Deploy one release per runner class — `general`, `gpu` (tolerates `nvidia.com/gpu`, requests one GPU, tag `gpu`), and `builds` (kaniko, higher resources) — each with its own tags so teams select capacity with `tags:` in their jobs. The `ci-jobs` namespace carries a default-deny egress NetworkPolicy allowing only ECR/S3/STS endpoints and GitLab.

#### 4.10.2 EC2 autoscaling runners (fleeting) — full-VM jobs

For jobs needing a whole machine (kernel modules, heavyweight integration tests), a runner manager drives an ASG of golden-AMI instances via the AWS fleeting plugin:

```toml
[[runners]]
  executor = "instance"
  [runners.autoscaler]
    plugin = "fleeting-plugin-aws"
    capacity_per_instance = 1
    max_use_count = 1                # fresh VM per job — zero cross-job contamination
    max_instances = 10
    [runners.autoscaler.plugin_config]
      name = "ci-runner-asg"         # ASG launch template pinned to /corp/ami/.../current
    [[runners.autoscaler.policy]]
      idle_count = 1
      idle_time  = "20m"
```

Instances carry `corp:role=ci-runner` (tag-targeted by SSM), instance profile `ci-runner-base`, and refresh onto each promoted AMI via `start-instance-refresh` (§6.13).

#### 4.10.3 IAM roles for runners and pipelines — two supported patterns

**Pattern 1 — OIDC federation (preferred; zero stored cloud credentials).** AWS IAM must fetch GitLab's OIDC discovery + JWKS to validate job tokens. GitLab stays corp-only: publish *just* the two read-only documents (`/.well-known/openid-configuration`, `/oauth/discovery/keys`) at the issuer URL via CloudFront/S3 or a reverse proxy exposing nothing else. If corp policy forbids even that, use Pattern 2.

```hcl
resource "aws_iam_openid_connect_provider" "gitlab" {
  url            = "https://gitlab.corp.example.com"
  client_id_list = ["https://gitlab.corp.example.com"]   # must equal the job's aud claim
}

# Per-team deploy role — trust scoped to project path + protected branch
data "aws_iam_policy_document" "gitlab_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "gitlab.corp.example.com:aud"
      values   = ["https://gitlab.corp.example.com"]
    }
    condition {
      test     = "StringLike"
      variable = "gitlab.corp.example.com:sub"
      values   = ["project_path:data-analytics/*:ref_type:branch:ref:main"]
    }
  }
}

resource "aws_iam_role" "ci_deploy_analytics" {
  name                 = "data-analytics-deploy"
  path                 = "/ci/"
  assume_role_policy   = data.aws_iam_policy_document.gitlab_trust.json
  max_session_duration = 3600
  # Attached permissions stay least-priv: ECR push to the team prefix, the team's
  # namespaced EKS access policy, S3 to the team artifact prefix — nothing else.
}
```

Job side (this snippet ships in the shared `corp/ci-templates` so teams never hand-roll it):

```yaml
deploy:
  id_tokens:
    AWS_ID_TOKEN: { aud: "https://gitlab.corp.example.com" }
  environment: production          # protected environment → only protected refs may run this
  script:
    - >
      export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s"
      $(aws sts assume-role-with-web-identity
      --role-arn arn:aws:iam::111122223333:role/ci/data-analytics-deploy
      --role-session-name "gl-${CI_PROJECT_ID}-${CI_PIPELINE_ID}"
      --web-identity-token "$AWS_ID_TOKEN" --duration-seconds 3600
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text))
    - aws sts get-caller-identity
```

The session-name convention **`gl-<project>-<pipeline>`** makes every CloudTrail event attributable to an exact pipeline, commit, and author — the audit hook used in §6.13 and §8.12.

**Pattern 2 — fully closed (no public JWKS at all).** The runner's infrastructure identity (Pod Identity for the EKS fleet, instance profile for the ASG fleet) is a base role that can do exactly one thing:

```hcl
resource "aws_iam_role_policy" "runner_base" {
  role = aws_iam_role.ci_runner_base.id
  name = "assume-team-deploy-roles-only"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::111122223333:role/ci/*"
    }]
  })
}
```

Each `ci/<team>-deploy` role trusts `ci-runner-base` **plus a per-project `sts:ExternalId`** stored as a *protected + masked* CI variable — so only pipelines on protected refs of that project can assume it:

```bash
aws sts assume-role --role-arn arn:aws:iam::111122223333:role/ci/data-analytics-deploy   --external-id "$CI_EXTERNAL_ID" --role-session-name "gl-${CI_PROJECT_ID}-${CI_PIPELINE_ID}"
```

Runner separation completes the control: deploy-capable runners are registered as **protected runners** with distinct tags, so unprotected/MR pipelines physically never land on them.

#### 4.10.4 Roles for users

GitLab SSO is Keycloak OIDC (§4.8). The same groups that drive EKS RBAC drive GitLab membership, so the quarterly review (§6.11) covers both systems in one pass:

| Keycloak group | GitLab role | EKS (via §4.8) |
|---|---|---|
| `platform-admins` | Owner on the platform group; Maintainer elsewhere | admin access policies |
| `data-engineers` | Developer on `data-analytics/*` | edit in team namespaces |
| `data-analysts` | Reporter | view |
| `security` | Auditor (instance-wide read) | view + audit logs |

Platform-owned guardrails: protected branches (`main`, `release/*`) and the `production` protected environment gate merges and deploys behind Maintainer approval; ExternalIds live only in protected+masked variables; `.gitlab-ci.yml` on protected branches requires code-owner approval (enforced check in §8.12 prevention).

---
## 5. Day-to-Day Runbooks

All commands assume: corp workstation or ops runner with `aws` CLI v2, `kubectl`, `helm`, `velero`, `jq` from the mirror; kubeconfig via Keycloak OIDC (humans) or IAM access entry (automation); `AWS_REGION=us-east-1`.

### 5.1 Morning health sweep (D1/D13/D14 — run automated at 07:00, human-reviewed)

```bash
#!/usr/bin/env bash
# morning-sweep.sh — one screen of truth. PASS/WARN/FAIL lines only.
set -uo pipefail
C=data-platform
PROM=http://prometheus.monitoring.svc.corp.example.com:9090   # corp-routable Prometheus
q(){ curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[]?|[.metric.pod // .metric.instance // "-", .value[1]]|@tsv'; }

echo "== EKS control plane & node groups =="
aws eks describe-cluster --name $C \
  --query 'cluster.{status:status,version:version,health:health.issues}' --output json
for ng in $(aws eks list-nodegroups --cluster-name $C --query 'nodegroups[]' --output text); do
  aws eks describe-nodegroup --cluster-name $C --nodegroup-name $ng \
    --query 'nodegroup.{ng:nodegroupName,status:status,issues:health.issues[].code}' --output json
done
kubectl get nodes --no-headers | awk '$2!="Ready"{print "FAIL NotReady:",$1}'
kubectl get pods -A --field-selector=status.phase=Pending --no-headers | awk '{print "WARN Pending:",$1"/"$2}'
kubectl get pods -A --no-headers | awk '$5+0>5{print "WARN restarts:",$1"/"$2,"x"$5}'
kubectl get pdb -A -o json | jq -r '.items[]|select(.status.disruptionsAllowed==0)|"WARN PDB-blocked: \(.metadata.namespace)/\(.metadata.name)"'
kubectl get nodeclaims 2>/dev/null | awk 'NR>1 && $2!="True"{print "WARN karpenter nodeclaim:",$1}'

echo "== Kafka (Strimzi) =="
kubectl -n kafka get kafka dp -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
kubectl -n kafka get pods -l strimzi.io/cluster=dp --no-headers | awk '$3!="Running"{print "FAIL",$1,$3}'
q 'sum(kafka_server_replicamanager_underreplicatedpartitions)' | awk '$2>0{print "FAIL under-replicated partitions:",$2}'
q 'max by(persistentvolumeclaim)(kubelet_volume_stats_used_bytes{namespace="kafka"}/kubelet_volume_stats_capacity_bytes{namespace="kafka"})' \
  | awk '$2>0.80{printf "WARN kafka PVC %s at %.0f%%\n",$1,$2*100}'

echo "== Postgres (CNPG) =="
kubectl get clusters.postgresql.cnpg.io -A --no-headers | awk '$4!~"healthy"{print "FAIL",$1"/"$2,$4}'
q 'cnpg_pg_replication_lag' | awk '$2>30{print "WARN repl lag(s):",$1,$2}'

echo "== OpenSearch (managed) =="
aws opensearch describe-domain-health --domain-name data-search \
  --query '{color:ClusterHealth,az:ActiveAvailabilityZoneCount,master:MasterEligibleNodeCount}' --output json
aws opensearch describe-domain --domain-name data-search \
  --query 'DomainStatus.{processing:Processing,upgrading:UpgradeProcessing}' --output json

echo "== NiFi =="
NT=$(curl -sk -X POST https://nifi.corp.example.com/nifi-api/access/token \
     -d "username=$NIFI_SVC_USER&password=$NIFI_SVC_PW")
curl -sk -H "Authorization: Bearer $NT" https://nifi.corp.example.com/nifi-api/flow/status \
  | jq -r '"queued=\(.controllerStatus.queued) threads=\(.controllerStatus.activeThreadCount)"'

echo "== Keycloak =="
kubectl -n keycloak exec deploy/keycloak -- \
  curl -sf http://localhost:9000/health/ready >/dev/null && echo PASS keycloak || echo FAIL keycloak

echo "== EC2 data-node fleet =="
aws ssm describe-instance-information \
  --filters "Key=tag:corp:role,Values=kafka,postgres,nifi" \
  --query 'InstanceInformationList[?PingStatus!=`Online`].[InstanceId,PingStatus]' --output text \
  | sed 's/^/FAIL ssm-offline: /'
aws cloudwatch describe-alarms --alarm-name-prefix datanode- --state-value ALARM \
  --query 'MetricAlarms[].[AlarmName,StateReason]' --output text | sed 's/^/FAIL alarm: /'

echo "== Backups (last 24h) =="
aws backup list-backup-jobs --by-state FAILED \
  --by-created-after $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --query 'BackupJobs[].[BackupJobId,ResourceArn]' --output text | sed 's/^/FAIL backup: /'
velero backup get 2>/dev/null | tail -3
kubectl get backups.postgresql.cnpg.io -A --sort-by=.metadata.creationTimestamp \
  --no-headers 2>/dev/null | tail -3

echo "== Security & networking =="
GD=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)
aws guardduty get-findings-statistics --detector-id $GD \
  --finding-criteria '{"Criterion":{"updatedAt":{"Gte":'$(( ($(date +%s)-86400)*1000 ))'}}}' \
  --finding-statistic-types COUNT_BY_SEVERITY --query 'FindingStatistics' --output json
aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'VpcEndpoints[?State!=`available`].[ServiceName,State]' --output text | sed 's/^/FAIL vpce: /'
```

Anything `FAIL` becomes a ticket before standup; `WARN` goes on the day board.

### 5.2 Pod triage — the four tickets you'll actually get (D2)

**A. `ImagePullBackOff` (air-gap classic — full scenario in §8.1)**

```bash
kubectl -n nifi describe pod nifi-0 | sed -n '/Events:/,$p'
# "failed to resolve reference registry.corp.example.com/..." → mirror problem
# "401/403" → robot creds/pull secret; "no space left" → node disk

# Reproduce on the exact node, through containerd (not curl!):
NODE=$(kubectl -n nifi get pod nifi-0 -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE -it --image=111122223333.dkr.ecr.us-east-1.amazonaws.com/tools/netshoot -- \
  chroot /host crictl pull registry.corp.example.com/apache/nifi:2.4.0
# Check the rewrite config the AMI baked in:
kubectl debug node/$NODE -it --image=...tools/netshoot -- chroot /host cat /etc/containerd/certs.d/docker.io/hosts.toml
```

**B. `Pending` — taints/GPU/capacity**

```bash
kubectl -n ml-inference describe pod vllm-0 | grep -A6 Events
#  "node(s) had untolerated taint {nvidia.com/gpu: true}"  → missing toleration (data team fix)
#  "Insufficient nvidia.com/gpu"                            → capacity or device plugin (§8.6)
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key,GPU:.status.allocatable.nvidia\.com/gpu'
# Managed node group headroom bump (temporary; PR follows):
aws eks update-nodegroup-config --cluster-name data-platform --nodegroup-name mng-general \
  --scaling-config minSize=3,maxSize=12,desiredSize=6
```

**C. `CrashLoopBackOff` / OOM**

```bash
kubectl -n streaming logs deploy/enricher --previous | tail -50
kubectl -n streaming get pod -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{end}'
# exit 137 → OOMKilled: compare usage vs limits
kubectl -n streaming top pod
```

**D. Evictions / node `DiskPressure`**

```bash
kubectl get events -A --field-selector reason=Evicted --sort-by=.lastTimestamp | tail
kubectl debug node/$NODE -it --image=...tools/netshoot -- chroot /host sh -c 'df -h /var/lib/containerd; crictl images | wc -l'
# One-off relief (kubelet GC will follow): chroot /host crictl rmi --prune
```

### 5.3 Node lifecycle hygiene (D3)

```bash
# Recycle one bad node — MNG's ASG replaces it on the same launch-template version
kubectl cordon ip-10-20-1-45.ec2.internal
kubectl drain ip-10-20-1-45.ec2.internal --ignore-daemonsets --delete-emptydir-data --timeout=10m
aws ec2 terminate-instances --instance-ids i-0abc123def456
kubectl get nodes -w   # replacement joins in ~2-4 min

# If drain hangs: find the PDB holding it
kubectl get pdb -A -o json | jq -r '.items[]|select(.status.disruptionsAllowed==0)|"\(.metadata.namespace)/\(.metadata.name)"'
```

### 5.4 Kafka daily (D4) — Strimzi path and EC2 path

```bash
# --- Strimzi on EKS ---
kubectl -n kafka get kafka,kafkanodepools,kafkatopics.kafka.strimzi.io -o wide | head
kubectl -n kafka logs deploy/strimzi-cluster-operator --since=12h | grep -iE 'error|failed' | tail

# Under-replicated / ISR (run inside a broker; plain listener is cluster-internal only)
kubectl -n kafka exec dp-broker-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions

# Consumer lag — flag anything > 100k messages
kubectl -n kafka exec dp-broker-0 -c kafka -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups 2>/dev/null \
  | awk 'NR>1 && $6+0>100000 {print "WARN lag",$1,$2,$3,"lag="$6}'

# Disk per broker PVC
for p in $(kubectl -n kafka get pods -l strimzi.io/pool-name=broker -o name); do
  echo -n "$p: "; kubectl -n kafka exec ${p#pod/} -c kafka -- df -h /var/lib/kafka/data-0 | awk 'NR==2{print $5,$4" free"}'
done

# Controlled rolling restart of one broker (never `kubectl delete pod` blind):
kubectl -n kafka annotate pod dp-broker-1 strimzi.io/manual-rolling-update=true

# --- EC2 tarball path (team-managed brokers on data nodes) ---
aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:corp:role,Values=kafka \
  --parameters 'commands=[
    "systemctl is-active kafka",
    "df -h /data | tail -1",
    "/opt/kafka/current/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions | head -5"
  ]' --query 'Command.CommandId' --output text
# then: aws ssm list-command-invocations --command-id <id> --details \
#         --query 'CommandInvocations[].[InstanceId,CommandPlugins[0].Output]' --output text
```

### 5.5 OpenSearch daily (D5)

```bash
DOMAIN=https://vpc-data-search-xxxx.us-east-1.es.amazonaws.com
AUTH='-u os-admin:REDACTED'          # FGAC internal user; or SigV4 via awscurl for IAM users

aws opensearch describe-domain-health --domain-name data-search --output table
curl -sk $AUTH "$DOMAIN/_cluster/health?pretty" | jq '{status,unassigned_shards,active_shards_percent_as_number}'
curl -sk $AUTH "$DOMAIN/_cat/indices?h=health,index,pri,rep,store.size&s=store.size:desc" | head
curl -sk $AUTH "$DOMAIN/_cat/allocation?v"                       # disk skew across nodes
curl -sk $AUTH "$DOMAIN/_nodes/stats/jvm" | jq '[.nodes[]|{name:.name,heap:.jvm.mem.heap_used_percent}]'
# ISM (rollover/retention) failures — the silent disk filler:
curl -sk $AUTH "$DOMAIN/_plugins/_ism/explain" | jq '[to_entries[]|select(.value.step?.step_status=="failed")|.key]'
```

### 5.6 Postgres daily (D6) — CNPG and EC2

```bash
kubectl get clusters.postgresql.cnpg.io -A
kubectl cnpg status keycloak-db -n keycloak          # plugin from the mirror: primary, repl lag, WAL

PSQL='kubectl -n keycloak exec keycloak-db-1 -c postgres -- psql -U postgres -Atc'
$PSQL "SELECT state, count(*) FROM pg_stat_activity GROUP BY 1"
$PSQL "SELECT max(now()-xact_start) FROM pg_stat_activity WHERE state='idle in transaction'"
$PSQL "SELECT calls, round(total_exec_time)::bigint ms, left(query,70)
       FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5"
kubectl -n keycloak exec keycloak-db-1 -c postgres -- df -h /var/lib/postgresql/data /var/lib/postgresql/wal

# EC2/Patroni fleet — same questions over SSM:
aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:corp:role,Values=postgres \
  --parameters 'commands=["patronictl -c /etc/patroni.yml list || systemctl is-active postgresql","df -h /data | tail -1"]'
```

### 5.7 NiFi daily (D7)

```bash
NIFI=https://nifi.corp.example.com/nifi-api
T=$(curl -sk -X POST $NIFI/access/token -d "username=$NIFI_SVC_USER&password=$NIFI_SVC_PW")
H="Authorization: Bearer $T"

curl -sk -H "$H" $NIFI/flow/status | jq '.controllerStatus|{queued,activeThreadCount,flowFilesQueued}'
# Connections at/near backpressure (>80% by count or bytes)
curl -sk -H "$H" "$NIFI/flow/process-groups/root/status?recursive=true" \
 | jq -r '..|.connectionStatusSnapshots?[]?.connectionStatusSnapshot
          | select((.percentUseCount>=80) or (.percentUseBytes>=80))
          | "\(.name): count=\(.percentUseCount)% bytes=\(.percentUseBytes)%"'
curl -sk -H "$H" "$NIFI/flow/bulletin-board?limit=20" | jq -r '.bulletinBoard.bulletins[]?.bulletin|"\(.level) \(.sourceName): \(.message)"' | sort | uniq -c | sort -rn | head
# Repos disk (the three that fill up)
kubectl -n nifi exec nifi-0 -- df -h /opt/nifi/nifi-current/content_repository \
  /opt/nifi/nifi-current/provenance_repository /opt/nifi/nifi-current/flowfile_repository
```

### 5.8 AI / GPU daily (D8)

```bash
kubectl -n kube-system get ds nvidia-device-plugin -o wide          # desired == ready
kubectl get nodes -l corp/workload=gpu-inference \
  -o custom-columns='NODE:.metadata.name,ALLOC:.status.allocatable.nvidia\.com/gpu,VER:.metadata.labels.nvidia\.com/cuda\.driver\.major'
# Requested vs allocatable GPUs (capacity headroom)
kubectl get pods -A -o json | jq '[.items[].spec.containers[].resources.requests["nvidia.com/gpu"]//0|tonumber]|add'

# Utilization + serving health (DCGM exporter + vLLM metrics in Prometheus)
q(){ curl -sG $PROM/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[]|[.metric.exported_pod//.metric.pod,.value[1]]|@tsv'; }
q 'avg by(exported_pod)(DCGM_FI_DEV_GPU_UTIL)'
q 'sum(vllm:num_requests_waiting)'      # inference queue depth
q 'histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))'

# 60-second GPU smoke test (also the gate in the AMI pipeline, §6.1)
kubectl run gpu-smoke --rm -it --restart=Never \
  --image=111122223333.dkr.ecr.us-east-1.amazonaws.com/mirrored/nvidia/cuda:12.6-base \
  --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists"}],"nodeSelector":{"corp/workload":"gpu-inference"},"containers":[{"name":"s","image":"111122223333.dkr.ecr.us-east-1.amazonaws.com/mirrored/nvidia/cuda:12.6-base","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
```

### 5.9 Keycloak daily (D9)

```bash
kubectl -n keycloak get pods,pdb
kubectl -n keycloak exec deploy/keycloak -- curl -sf http://localhost:9000/health/ready && echo OK

KC=/opt/keycloak/bin/kcadm.sh
kubectl -n keycloak exec deploy/keycloak -- bash -c "
  $KC config credentials --server http://localhost:8080 --realm master --user \$KC_ADMIN --password \$KC_PW >/dev/null
  $KC get events -r data-platform -q type=LOGIN_ERROR -q max=200" | jq length
# > 50 failed logins/day → check for lockouts or spraying; correlate ipAddress field
```

### 5.10 Access-request fulfilment (D10) — 5-minute SOP

```bash
# 1. Keycloak group (drives OIDC groups claim → K8s RBAC + app roles)
kubectl -n keycloak exec deploy/keycloak -- bash -c '
  KC=/opt/keycloak/bin/kcadm.sh; $KC config credentials --server http://localhost:8080 --realm master --user $KC_ADMIN --password $KC_PW >/dev/null
  UID=$($KC get users -r data-platform -q username=jdoe --fields id --format csv --noquotes)
  GID=$($KC get groups -r data-platform -q search=data-engineers --fields id --format csv --noquotes | head -1)
  $KC update users/$UID/groups/$GID -r data-platform -s realm=data-platform -s userId=$UID -s groupId=$GID -n'

# 2. (Automation/CI principals only) IAM → EKS access entry, namespace-scoped
aws eks create-access-entry --cluster-name data-platform \
  --principal-arn arn:aws:iam::111122223333:role/AgentsCI --type STANDARD
aws eks associate-access-policy --cluster-name data-platform \
  --principal-arn arn:aws:iam::111122223333:role/AgentsCI \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces=agents

# 3. Verify before closing the ticket — never skip
kubectl auth can-i create deployments -n agents --as jdoe --as-group keycloak:data-engineers   # yes
kubectl auth can-i get secrets -n kube-system --as jdoe --as-group keycloak:data-engineers     # no
```

### 5.11 Supply-chain daily (D11)

```bash
# Harbor → ECR replication executions (mirror is the vetting gate, ECR is the runtime registry)
curl -sk -u "$HARBOR_ROBOT" \
  "https://registry.corp.example.com/api/v2.0/replication/executions?policy_id=3&page_size=5" \
  | jq -r '.[]|"\(.status) \(.start_time) succeed=\(.succeed) failed=\(.failed)"'

# New CRITICAL findings on runtime images since yesterday (Inspector enhanced scanning on ECR)
aws inspector2 list-findings --filter-criteria '{
  "severity":[{"comparison":"EQUALS","value":"CRITICAL"}],
  "ecrImageRegistry":[{"comparison":"EQUALS","value":"111122223333"}],
  "updatedAt":[{"startInclusive":'$(date -d yesterday +%s)'}]}' \
  --query 'findings[].{cve:vulnerabilityId,repo:resources[0].details.awsEcrContainerImage.repositoryName,sev:severity}' --output table
```

### 5.12 Cost daily (D12)

```bash
aws ce get-anomalies --date-interval StartDate=$(date -d '2 days ago' +%F),EndDate=$(date +%F) \
  --query 'Anomalies[].{svc:RootCauses[0].Service,impact:Impact.TotalImpact,score:AnomalyScore.CurrentScore}' --output table

aws ce get-cost-and-usage --time-period Start=$(date -d yesterday +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups|sort_by(@,&Metrics.UnblendedCost.Amount)|reverse(@)[:8].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
# Cross-check GPU $ (EC2 g6/p5 usage types) against yesterday's avg DCGM_FI_DEV_GPU_UTIL (§5.8) — idle GPUs get flagged to the team same day.
```

### 5.13 EC2 data-node fleet daily (D15)

```bash
# Heartbeat + agent currency
aws ssm describe-instance-information --filters "Key=tag:corp:patch-group,Values=datanode-kafka,datanode-postgres,datanode-nifi" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformVersion,IsLatestVersion]' --output table

# Prereq drift — the State Manager association from §4.9.2 must be Compliant everywhere
aws ssm list-compliance-summaries \
  --filters Key=ComplianceType,Values=Association \
  --query 'ComplianceSummaryItems[?NonCompliantSummary.NonCompliantCount>`0`]'

# Failed units across the fleet (catches half-dead team services before the team does)
aws ssm send-command --document-name AWS-RunShellScript \
  --targets "Key=tag:corp:role,Values=kafka,postgres,nifi" \
  --parameters 'commands=["systemctl --failed --no-legend || true","df -h /data | tail -1"]'
```

### 5.14 GitLab runner fleet daily (D16)

```bash
GL=https://gitlab.corp.example.com/api/v4          # q() = Prometheus helper from §5.1

# Kubernetes-executor fleet
kubectl -n gitlab-runners get pods -o wide
kubectl -n ci-jobs get pods --field-selector=status.phase=Pending --no-headers | wc -l   # stuck job pods

# GitLab's view — offline/stale runners (admin PAT, read_api scope):
curl -s --header "PRIVATE-TOKEN: $GL_ADMIN_TOKEN" "$GL/runners/all?status=offline"   | jq -r '.[] | "\(.id) \(.description) last=\(.contacted_at)"'

# Queue pressure & saturation (runner Prometheus metrics):
q 'sum(gitlab_runner_jobs{state="running"})'
q 'sum(gitlab_runner_concurrent) - sum(gitlab_runner_jobs{state="running"})'   # free slots
q 'histogram_quantile(0.95, sum(rate(gitlab_runner_job_queue_duration_seconds_bucket[1h])) by (le))'

# EC2 autoscaling fleet
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ci-runner-asg   --query 'AutoScalingGroups[0].{desired:DesiredCapacity,healthy:length(Instances[?HealthStatus==`Healthy`])}'

# Cache bucket reachable from inside a job pod (proves the S3 gateway path):
kubectl -n ci-jobs run cache-probe --rm -i --restart=Never   --image=111122223333.dkr.ecr.us-east-1.amazonaws.com/tools/ci-base:al2023   -- aws s3 ls s3://corp-ci-cache --page-size 1 >/dev/null && echo PASS cache || echo FAIL cache
```

Most common finding: runner pods CrashLooping right after a token rotation — re-sync the `gitlab-runner-token` Secret and `rollout restart` (§6.13 step 2 does it in order).

---
## 6. Periodic Runbooks

### 6.1 Golden AMI pipeline — EC2 Image Builder (CloudFormation, monthly + on-CVE)

Parents are the **EKS-optimized AL2023** AMIs (standard + NVIDIA variant) resolved from public SSM parameters — reachable air-gapped because the parameter store and the AMI artifacts ride the SSM/S3 endpoints. The pipeline layers corp hardening, agents, the containerd mirror rewrites, and forensic tooling, then scans, tags, and publishes the AMI ID to SSM.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Golden EKS node AMI pipeline (standard). GPU pipeline is identical but uses the
  nvidia parent parameter and adds a nvidia-smi validation phase.

Parameters:
  K8sVersion:     { Type: String, Default: '1.35' }
  BuildSubnetId:  { Type: 'AWS::EC2::Subnet::Id' }
  BuildSgId:      { Type: 'AWS::EC2::SecurityGroup::Id' }
  InstanceProfile:{ Type: String }   # SSM + S3(mirror artifacts) + logs

Resources:
  CorpBaselineComponent:
    Type: AWS::ImageBuilder::Component
    Properties:
      Name: corp-eks-node-baseline
      Platform: Linux
      Version: '1.4.0'
      Data: |
        name: corp-eks-node-baseline
        schemaVersion: 1.0
        phases:
          - name: build
            steps:
              - name: repos
                action: ExecuteBash
                inputs:
                  commands:
                    - install -d /etc/corp
                    - |
                      cat > /etc/yum.repos.d/corp.repo <<'EOF'
                      [corp-al2023]
                      name=Corp AL2023 mirror
                      baseurl=https://artifacts.corp.example.com/artifactory/al2023-mirror/$releasever/$basearch/
                      enabled=1
                      gpgcheck=1
                      EOF
              - name: packages
                action: ExecuteBash
                inputs:
                  commands:
                    - dnf -y update --security
                    - dnf -y install amazon-cloudwatch-agent avml jq   # avml = memory capture (§7.5)
              - name: registry-mirrors
                action: ExecuteBash
                inputs:
                  commands:
                    - install -d /etc/containerd/certs.d/docker.io /etc/containerd/certs.d/quay.io /etc/containerd/certs.d/registry.k8s.io /etc/containerd/certs.d/ghcr.io /etc/containerd/certs.d/nvcr.io
                    - |
                      for r in docker.io quay.io registry.k8s.io ghcr.io nvcr.io; do
                      cat > /etc/containerd/certs.d/$r/hosts.toml <<EOF
                      server = "https://$r"
                      [host."https://registry.corp.example.com/v2/${r%%.*}-proxy"]
                        capabilities = ["pull", "resolve"]
                        override_path = true
                      EOF
                      done
                    - cp /etc/corp/corp-root-ca.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust
              - name: hardening
                action: ExecuteBash
                inputs:
                  commands:
                    - passwd -l root
                    - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                    - echo 'kernel.dmesg_restrict = 1' > /etc/sysctl.d/80-corp.conf
          - name: validate
            steps:
              - name: verify
                action: ExecuteBash
                inputs:
                  commands:
                    - systemctl is-enabled amazon-ssm-agent
                    - test -s /etc/containerd/certs.d/docker.io/hosts.toml
                    - grep -q corp-al2023 /etc/yum.repos.d/corp.repo

  NodeRecipe:
    Type: AWS::ImageBuilder::ImageRecipe
    Properties:
      Name: corp-eks-node-al2023
      Version: '1.4.0'
      ParentImage: !Sub '{{resolve:ssm:/aws/service/eks/optimized-ami/${K8sVersion}/amazon-linux-2023/x86_64/standard/recommended/image_id}}'
      Components:
        - ComponentArn: !Ref CorpBaselineComponent
      BlockDeviceMappings:
        - DeviceName: /dev/xvda
          Ebs: { VolumeSize: 120, VolumeType: gp3, Encrypted: true, DeleteOnTermination: true }

  Infra:
    Type: AWS::ImageBuilder::InfrastructureConfiguration
    Properties:
      Name: corp-eks-node-infra
      InstanceProfileName: !Ref InstanceProfile
      SubnetId: !Ref BuildSubnetId
      SecurityGroupIds: [ !Ref BuildSgId ]
      TerminateInstanceOnFailure: true

  Dist:
    Type: AWS::ImageBuilder::DistributionConfiguration
    Properties:
      Name: corp-eks-node-dist
      Distributions:
        - Region: !Ref AWS::Region
          AmiDistributionConfiguration:
            Name: 'corp-eks-node-al2023-{{ imagebuilder:buildDate }}'
            AmiTags:
              corp:approved: 'pending-canary'          # flips to "true" only after §6.2 canary
              corp:ami-family: !Sub 'eks-${K8sVersion}-al2023-standard'
          SsmParameterConfigurations:
            - ParameterName: !Sub '/corp/ami/eks/${K8sVersion}/al2023/standard/candidate'
              DataType: aws:ec2:image

  Pipeline:
    Type: AWS::ImageBuilder::ImagePipeline
    Properties:
      Name: corp-eks-node-monthly
      ImageRecipeArn: !Ref NodeRecipe
      InfrastructureConfigurationArn: !Ref Infra
      DistributionConfigurationArn: !Ref Dist
      ImageScanningConfiguration: { ImageScanningEnabled: true }   # Inspector scans every build
      ImageTestsConfiguration: { ImageTestsEnabled: true }
      Schedule:
        ScheduleExpression: 'cron(0 4 1 * ? *)'                    # 1st of month 04:00 UTC
        PipelineExecutionStartCondition: EXPRESSION_MATCH_ONLY
```

```bash
# Out-of-band build (zero-day fast path, §7.3):
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn arn:aws:imagebuilder:us-east-1:111122223333:image-pipeline/corp-eks-node-monthly
aws imagebuilder list-image-pipeline-images --image-pipeline-arn <arn> \
  --query 'imageSummaries[0].{state:state.status,ami:outputResources.amis[0].image}'
```

### 6.2 AMI rollout — canary → waves → (auto) Karpenter drift (P2, monthly)

```bash
K=1.35
CAND=$(aws ssm get-parameter --name /corp/ami/eks/$K/al2023/standard/candidate --query 'Parameter.Value' --output text)

# 1. Canary: dedicated 2-node MNG runs the candidate for 24h with synthetic workloads
aws ec2 create-launch-template-version --launch-template-name eks-canary \
  --source-version '$Latest' --launch-template-data "{\"ImageId\":\"$CAND\"}"
aws eks update-nodegroup-version --cluster-name data-platform --nodegroup-name mng-canary \
  --launch-template name=eks-canary,version='$Latest'
# Gate: §5.1 sweep green + GPU smoke (§5.8) on the GPU canary + no new Inspector CRITICALs

# 2. Promote: candidate → current, and tag for Karpenter
aws ssm put-parameter --name /corp/ami/eks/$K/al2023/standard/current --type String \
  --value "$CAND" --overwrite
aws ec2 create-tags --resources "$CAND" --tags Key=corp:approved,Value=true

# 3. Waves across MNGs (Terraform bumps LT to the new SSM value; or CLI):
for ng in mng-system mng-general mng-kafka; do
  aws eks update-nodegroup-version --cluster-name data-platform --nodegroup-name $ng \
    --launch-template name=eks-$ng,version='$Latest'
  aws eks wait nodegroup-active --cluster-name data-platform --nodegroup-name $ng
done
# mng-kafka rolls one node at a time (update_config) and Strimzi's PDB keeps min.insync safe.

# 4. Karpenter: the corp:approved=true tag makes existing GPU nodes "Drifted" —
#    they roll automatically inside the NodePool disruption budget. Watch:
kubectl get nodeclaims -o custom-columns='NAME:.metadata.name,DRIFTED:.status.conditions[?(@.type=="Drifted")].status'

# Rollback = previous LT version:
aws eks update-nodegroup-version --cluster-name data-platform --nodegroup-name mng-general \
  --launch-template name=eks-mng-general,version=7   # N-1
```

> **EKS nodes are cattle — patch by replacement.** The only in-place patching in this platform is (a) the EC2 data-node fleet below and (b) declared zero-day hotfixes (§7.4), which always get chased by an AMI roll.

### 6.3 EC2 estate patching — SSM Patch Manager with service-aware orchestration (P3)

Patch baseline + maintenance windows (CloudFormation):

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  Al2023Baseline:
    Type: AWS::SSM::PatchBaseline
    Properties:
      Name: corp-al2023-datanodes
      OperatingSystem: AMAZON_LINUX_2023
      PatchGroups: [datanode-kafka, datanode-postgres, datanode-nifi, utility]
      ApprovalRules:
        PatchRules:
          - ApproveAfterDays: 3
            ComplianceLevel: CRITICAL
            PatchFilterGroup:
              PatchFilters:
                - { Key: CLASSIFICATION, Values: [Security] }
                - { Key: SEVERITY, Values: [Critical, Important] }
          - ApproveAfterDays: 7
            ComplianceLevel: MEDIUM
            PatchFilterGroup:
              PatchFilters:
                - { Key: CLASSIFICATION, Values: [Security, Bugfix] }

  KafkaWindow:
    Type: AWS::SSM::MaintenanceWindow
    Properties: { Name: mw-datanode-kafka, Schedule: 'cron(0 6 ? * SUN *)',
                  Duration: 4, Cutoff: 1, AllowUnassociatedTargets: false }
  KafkaTarget:
    Type: AWS::SSM::MaintenanceWindowTarget
    Properties:
      WindowId: !Ref KafkaWindow
      ResourceType: INSTANCE
      Targets: [{ Key: 'tag:corp:patch-group', Values: [datanode-kafka] }]
  KafkaScan:                                   # window SCANS; the orchestrator below INSTALLS
    Type: AWS::SSM::MaintenanceWindowTask
    Properties:
      WindowId: !Ref KafkaWindow
      Targets: [{ Key: WindowTargetIds, Values: [!Ref KafkaTarget] }]
      TaskType: RUN_COMMAND
      TaskArn: AWS-RunPatchBaseline
      Priority: 1
      MaxConcurrency: '100%'
      MaxErrors: '0'
      TaskInvocationParameters:
        MaintenanceWindowRunCommandParameters:
          Parameters: { Operation: [Scan] }
```

**Why scan-only in the window?** Kafka/Postgres brokers can't reboot in parallel. The install pass is a **serial, service-aware orchestrator** run by the platform on-call inside the window:

```bash
#!/usr/bin/env bash
# patch-kafka-fleet.sh — one broker at a time, ISR-gated. Same pattern for postgres
# (patronictl switchover before patching the primary) and nifi (offload node via API first).
set -euo pipefail
run(){ local i=$1; shift; id=$(aws ssm send-command --instance-ids "$i" \
       --document-name AWS-RunShellScript --parameters "commands=$1" \
       --query 'Command.CommandId' --output text)
       aws ssm wait command-executed --command-id $id --instance-id $i 2>/dev/null || true
       aws ssm get-command-invocation --command-id $id --instance-id $i \
         --query '[Status,StandardOutputContent]' --output text; }

for i in $(aws ec2 describe-instances \
    --filters "Name=tag:corp:patch-group,Values=datanode-kafka" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text); do
  echo "=== $i ==="
  run $i '["/opt/kafka/current/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions | wc -l"]' \
    | grep -q ' 0$' || { echo "URP != 0 — fleet not healthy, aborting"; exit 1; }
  run $i '["systemctl stop kafka"]'
  id=$(aws ssm send-command --instance-ids $i --document-name AWS-RunPatchBaseline \
        --parameters 'Operation=Install,RebootOption=RebootIfNeeded' --query 'Command.CommandId' --output text)
  until [[ $(aws ssm get-command-invocation --command-id $id --instance-id $i --query Status --output text 2>/dev/null) =~ Success|Failed ]]; do sleep 20; done
  aws ec2 wait instance-status-ok --instance-ids $i          # covers the reboot
  run $i '["systemctl start kafka"]'
  until run $i '["/opt/kafka/current/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions | wc -l"]' | grep -q ' 0$'; do
    echo "waiting for ISR rejoin..."; sleep 30
  done
done

# Compliance evidence for the monthly report:
aws ssm describe-instance-patch-states-for-patch-group --patch-group datanode-kafka \
  --query 'InstancePatchStates[].[InstanceId,FailedCount,MissingCount,OperationEndTime]' --output table
```

### 6.4 EKS minor upgrade (P5 — quarterly candidate; e.g. 1.35 → 1.36)

```bash
C=data-platform; TARGET=1.36

# 1. Pre-flight
aws eks list-insights --cluster-name $C \
  --filter kubernetesVersions=$TARGET \
  --query 'insights[?insightStatus.status!=`PASSING`].[name,insightStatus.status]' --output table
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis | grep -v ' 0$'   # deprecated API usage
for a in vpc-cni coredns kube-proxy aws-ebs-csi-driver eks-pod-identity-agent; do
  aws eks describe-addon-versions --kubernetes-version $TARGET --addon-name $a \
    --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion].addonVersion' --output text
done
velero backup create pre-$TARGET-$(date +%F) --include-cluster-resources --wait

# 2. Control plane (nodes keep running; API blips only)
aws eks update-cluster-version --name $C --kubernetes-version $TARGET
aws eks wait cluster-active --name $C
# Safety net: in-place upgrades can be ROLLED BACK to the prior minor within 7 days
# (update-cluster-version back to 1.35) — verify current constraints in the EKS docs first.

# 3. Add-ons to the compatible versions from step 1
aws eks update-addon --cluster-name $C --addon-name coredns \
  --addon-version v1.12.x-eksbuild.y --resolve-conflicts PRESERVE
# ...repeat per add-on

# 4. Data plane: build 1.36 AMIs (K8sVersion param in §6.1), then §6.2 canary→waves;
#    Karpenter EC2NodeClass amiSelectorTerms tag flips to corp:ami-family=eks-1.36-* → drift roll.

# 5. Post: full §5.1 sweep, PDB check, Strimzi/CNPG operator logs clean, GPU smoke test.
```

### 6.5 Kafka version upgrades (P6) — Strimzi path and EC2 path

```bash
# --- Strimzi (e.g. 4.0.0 → 4.1.0) ---
# 1. Upgrade the operator FIRST (must support both versions):
helm upgrade strimzi corp-helm/strimzi-kafka-operator --version 0.4x.z -n kafka -f strimzi-airgap-values.yaml
# 2. Bump the broker version — operator rolls pods one at a time, respecting the PDB:
kubectl -n kafka patch kafka dp --type merge -p '{"spec":{"kafka":{"version":"4.1.0"}}}'
kubectl -n kafka get pods -l strimzi.io/cluster=dp -w
# 3. Soak with clients (lag normal, no URP), THEN finalize the KRaft metadata (irreversible):
kubectl -n kafka patch kafka dp --type merge -p '{"spec":{"kafka":{"metadataVersion":"4.1-IV0"}}}'
#    (use the exact metadataVersion string the Strimzi release notes give for that Kafka version)

# --- EC2 tarball fleet (platform-supported, team-executed) ---
# Per broker, serially: stop → flip symlink → start → wait ISR (reuse §6.3 gate):
#   systemctl stop kafka
#   ln -sfn /opt/kafka/kafka_2.13-4.1.0 /opt/kafka/current      # tarball pre-staged from Artifactory
#   systemctl start kafka
# After ALL brokers run 4.1 and soak passes, finalize cluster-wide:
/opt/kafka/current/bin/kafka-features.sh --bootstrap-server localhost:9092 upgrade --release-version 4.1
```

### 6.6 OpenSearch engine upgrade (P7)

```bash
aws opensearch get-compatible-versions --domain-name data-search
# 1. Snapshot first (manual repo from §6.8), 2. Dry run, 3. Real run:
aws opensearch upgrade-domain --domain-name data-search --target-version OpenSearch_3.1 --perform-check-only
aws opensearch upgrade-domain --domain-name data-search --target-version OpenSearch_3.1
watch -n60 aws opensearch get-upgrade-status --domain-name data-search
# Managed blue/green under the hood — verify shard count == pre-upgrade and Dashboards SSO works.
```

### 6.7 PostgreSQL upgrades (P8)

```bash
# CNPG MINOR (17.5 → 17.6): rolling with automatic switchover
kubectl -n keycloak patch cluster keycloak-db --type merge \
  -p '{"spec":{"imageName":"111122223333.dkr.ecr.us-east-1.amazonaws.com/mirrored/cloudnative-pg/postgresql:17.6"}}'
kubectl cnpg status keycloak-db -n keycloak   # replicas update first, then switchover, then old primary

# CNPG MAJOR (17 → 18): blue/green via logical import — zero-risk rollback
#   1. New Cluster "keycloak-db-18" with bootstrap.initdb.import (type: monolith) pointing at
#      the 17 cluster as externalCluster; CNPG copies schema+data logically.
#   2. Freeze writes (maintenance window) → final sync → repoint the app Service/secret.
#   3. Keep the 17 cluster paused for 7 days as rollback.
# EC2/Patroni majors: classic `pg_upgrade --link` on the primary with a rehearsed rollback snapshot.
```

### 6.8 Backups & the quarterly DR drill (P9)

```hcl
# AWS Backup — EBS data volumes of the EC2 data-node fleet (by tag), 35-day retention
resource "aws_backup_vault" "data" {
  name        = "datanode-vault"
  kms_key_arn = aws_kms_key.backup.arn
}
resource "aws_backup_plan" "datanodes" {
  name = "datanodes-daily"
  rule {
    rule_name         = "daily-0500"
    target_vault_name = aws_backup_vault.data.name
    schedule          = "cron(0 5 * * ? *)"
    lifecycle { delete_after = 35 }
  }
}
resource "aws_backup_selection" "datanodes" {
  name         = "by-tag"
  plan_id      = aws_backup_plan.datanodes.id
  iam_role_arn = aws_iam_role.backup.arn
  selection_tag {
    type  = "STRINGEQUALS"
    key   = "corp:backup"
    value = "daily"
  }
}
```

```bash
# OpenSearch manual snapshots — register an S3 repo once (S3 gateway endpoint carries it):
curl -sk -u os-admin:REDACTED -H 'Content-Type: application/json' -XPUT \
  "$DOMAIN/_snapshot/corp-s3" -d '{"type":"s3","settings":{
    "bucket":"corp-os-snapshots","region":"us-east-1",
    "role_arn":"arn:aws:iam::111122223333:role/OpenSearchSnapshotRole"}}'
curl -sk -u os-admin:REDACTED -XPUT "$DOMAIN/_snapshot/corp-s3/nightly-$(date +%F)"

# Velero (charts/images from mirror; S3 via gateway endpoint) — K8s objects + PVs
velero schedule create nightly --schedule "0 4 * * *" --include-namespaces nifi,kafka,keycloak,agents

# ---- Quarterly drill (timed, evidence in the ticket) ----
# 1. CNPG PITR into a throwaway cluster (bootstrap: recovery from barmanObjectStore) → row counts match
# 2. EBS: aws backup start-restore-job (latest recovery point of one kafka data node) → mount → verify segments
# 3. OpenSearch: POST _snapshot/corp-s3/<snap>/_restore {"indices":"telemetry-2026.06*","rename_pattern":"(.+)","rename_replacement":"drill-$1"}
# 4. Velero: velero restore create --from-backup nightly-<date> --namespace-mappings nifi:nifi-drill
# Pass = all four restored & validated < 4h. Log actuals; they are your real RTO.
```

### 6.9 Certificate & secret rotation (P10)

```bash
# ACM Private CA issues everything internal (Harbor, NiFi, Grafana ingress) via cert-manager AWSPCA issuer.
# Find anything expiring < 30 days:
kubectl get certificates -A -o json | jq -r \
  '.items[]|select(.status.notAfter!=null and (.status.notAfter|fromdate) < (now+2592000))|"\(.metadata.namespace)/\(.metadata.name) \(.status.notAfter)"'
aws acm list-certificates --includes keyTypes=RSA_2048,EC_prime256v1 \
  --query 'CertificateSummaryList[?NotAfter<=`'$(date -d +30days +%F)'`].[DomainName,NotAfter]' --output table

# Strimzi rotates its own CAs; watch for renewal windows (rolling restarts!) and never let them surprise a release day:
kubectl -n kafka get secret dp-cluster-ca-cert -o jsonpath='{.metadata.annotations.strimzi\.io/ca-cert-generation}'

# Secrets Manager rotation status (rotation Lambdas run in-VPC):
aws secretsmanager list-secrets \
  --query 'SecretList[?RotationEnabled==`false`].[Name]' --output table   # should be empty for DB creds

# Keycloak realm signing keys: add new key → keep old for token overlap → retire (kcadm components CRUD).
```

### 6.10 Cost governance (P11)

```hcl
resource "aws_budgets_budget" "data_platform" {
  name         = "data-platform-monthly"
  budget_type  = "COST"
  limit_amount = "85000"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:corp:team$data-analytics"]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.finops.arn]
  }
}
```

```sql
-- CUR 2.0 in Athena. (1) Spend by team tag this month:
SELECT resource_tags['corp:team'] team, round(sum(line_item_unblended_cost),2) usd
FROM cur WHERE billing_period = date_trunc('month', current_date)
GROUP BY 1 ORDER BY 2 DESC;

-- (2) Inter-AZ transfer — self-managed Kafka's signature cost (fix in What-If 8.9):
SELECT line_item_usage_type, round(sum(line_item_unblended_cost),2) usd
FROM cur WHERE line_item_usage_type LIKE '%DataTransfer-Regional-Bytes%'
  AND billing_period = date_trunc('month', current_date)
GROUP BY 1 ORDER BY 2 DESC;

-- (3) Pod-level EKS cost (enable "Split Cost Allocation Data" in Billing prefs):
SELECT split_line_item_split_usage_ratio, resource_tags['corp:team'] team,
       round(sum(split_line_item_split_cost),2) usd
FROM cur WHERE product_servicecode='AmazonEKS' GROUP BY 1,2 ORDER BY 3 DESC LIMIT 20;
```

```bash
# Monthly hygiene sweep:
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table            # unattached EBS
aws ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[?StartTime<=`'$(date -d -180days +%F)'`]|length(@)'   # stale snapshots
aws ec2 describe-volumes --filters Name=volume-type,Values=gp2 --query 'Volumes|length(@)'  # gp2 stragglers → gp3
# Idle-GPU report: avg DCGM_FI_DEV_GPU_UTIL < 10% for 7d → name-and-notify the owning team.
# Kubecost/OpenCost (self-hosted from the mirror) gives namespace showback in Grafana.
```

### 6.11 Quarterly access review (P12)

```bash
# 1. Every IAM principal with cluster access + its scope:
for arn in $(aws eks list-access-entries --cluster-name data-platform --query 'accessEntries[]' --output text); do
  aws eks list-associated-access-policies --cluster-name data-platform --principal-arn "$arn" \
    --query 'associatedAccessPolicies[].{p:policyArn,scope:accessScope}' --output json | jq --arg a "$arn" '{principal:$a,policies:.}'
done > access-entries-$(date +%F).json

# 2. Keycloak group membership export:
kubectl -n keycloak exec deploy/keycloak -- bash -c '
  KC=/opt/keycloak/bin/kcadm.sh; $KC config credentials --server http://localhost:8080 --realm master --user $KC_ADMIN --password $KC_PW >/dev/null
  for g in $($KC get groups -r data-platform --fields id --format csv --noquotes); do
    $KC get groups/$g/members -r data-platform --fields username; done' > kc-members-$(date +%F).json

# 3. Diff both against the HR feed → produce removals; leavers exit SAME DAY:
aws eks delete-access-entry --cluster-name data-platform --principal-arn arn:aws:iam::...:role/OldContractorRole

# 4. RBAC landmine scan — nobody but platform holds cluster-admin:
kubectl get clusterrolebindings -o json | jq -r \
  '.items[]|select(.roleRef.name=="cluster-admin")|"\(.metadata.name): \(.subjects)"'
```

### 6.12 Capacity & right-sizing (P13)

```bash
# PVC growth forecast — anything filling within 30 days gets a resize PR now:
q 'predict_linear(kubelet_volume_stats_available_bytes{namespace=~"kafka|nifi|keycloak"}[7d], 86400*30) < 0'
# Node group utilization percentiles (requests vs allocatable) → resize instance types quarterly
# Kafka: partitions per broker < ~4000; disk forecast from topic bytes-in growth
# OpenSearch: keep shards 10–50 GiB and ≤ ~25 shards per GiB of heap; merge small indices via ISM
aws compute-optimizer get-ec2-instance-recommendations \
  --filters name=Finding,values=Overprovisioned \
  --query 'instanceRecommendations[].[instanceArn,currentInstanceType,recommendationOptions[0].instanceType]' --output table
```

### 6.13 GitLab runner lifecycle (P17)

```bash
GL=https://gitlab.corp.example.com/api/v4

# 1. Version: bump runners the same week the corp GitLab team upgrades the server —
#    runner minor tracks the GitLab minor. Re-check the helper_image pin, then gate:
helm upgrade gitlab-runner corp-helm/gitlab-runner --version <chart> -n gitlab-runners -f values-airgap.yaml
#    Canary pipeline (corp/ci-templates canary project: build → cache → assume-role → deploy-dryrun)
#    must pass before upgrading the remaining runner classes.

# 2. Rotate runner authentication tokens (quarterly, or immediately on suspicion):
NEW=$(curl -s -X POST --header "PRIVATE-TOKEN: $GL_ADMIN_TOKEN"   "$GL/runners/$RUNNER_ID/reset_authentication_token" | jq -r .token)
kubectl -n gitlab-runners create secret generic gitlab-runner-token   --from-literal=runner-token=$NEW --dry-run=client -o yaml | kubectl apply -f -
kubectl -n gitlab-runners rollout restart deploy/gitlab-runner

# 3. EC2 fleet onto the current golden AMI (rides the §6.2 promotion):
aws autoscaling start-instance-refresh --auto-scaling-group-name ci-runner-asg   --preferences '{"MinHealthyPercentage":50}'

# 4. CI deploy-role audit (joins the §6.11 review):
aws iam list-roles --path-prefix /ci/   --query 'Roles[].[RoleName,MaxSessionDuration]' --output table
#    Athena/CloudTrail: sessions with role-session-name prefix "gl-" → project→role usage map;
#    delete roles unused 90d; verify every trust still pins project_path + protected ref
#    (Pattern 1) or a per-project ExternalId (Pattern 2). Wildcard subs are a finding.
```

---
## 7. Zero-Day Response & Forensics

### 7.1 Intake, severity, and the exposure census (Z1)

| Severity | Definition | Clock |
|---|---|---|
| **SEV-1** | Remotely exploitable, present on internet…no — *corp-reachable* attack surface, or active exploitation reported | Mitigate < 24h, remediate < 72h |
| **SEV-2** | Exploitable with auth/local access; present in fleet | Remediate < 7d (next emergency AMI/patch cycle) |
| **SEV-3** | Present but mitigated by config/air-gap | Fold into monthly cycle (§6.1/§6.3) |

The air gap **reduces** exposure (no inbound internet, all software mirrored) but does not eliminate it: corp network users, poisoned upstream artifacts that passed vetting, and lateral movement are the realistic vectors. Assess against *corp* reachability, not internet reachability.

**Exposure census — answer "where does the bad version run?" in minutes:**

```bash
CVE=CVE-2026-XXXXX; PKG=openssl; BADVER='3.0.'

# 1. OS packages across every EC2 (EKS nodes + data nodes) — SSM Inventory:
aws ssm get-inventory --filters "Key=AWS:Application.Name,Values=$PKG,Type=Equal" \
  --query 'Entities[].{id:Id,ver:Data."AWS:Application".Content[0].Version}' --output table

# 2. Tarball installs SSM Inventory can't see (team-installed Kafka/NiFi under /opt) — live sweep:
aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:corp:role,Values=kafka,nifi,postgres \
  --parameters 'commands=["find /opt /data -maxdepth 3 \\( -name \"kafka_*\" -o -name \"nifi-*\" -o -name \"log4j-core-*.jar\" \\) 2>/dev/null","java -version 2>&1 | head -1"]'

# 3. Container images actually RUNNING (not just stored):
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort | uniq -c | sort -rn > running-images.txt

# 4. Which stored images carry the CVE — Inspector on ECR:
aws inspector2 list-findings --filter-criteria "{
  \"vulnerabilityId\":[{\"comparison\":\"EQUALS\",\"value\":\"$CVE\"}]}" \
  --query 'findings[].resources[0].details.awsEcrContainerImage.[repositoryName,imageTags[0]]' --output table
# Join 3⨝4 = the pods that must move. Also query Harbor's scanner for not-yet-replicated tags.
```

### 7.2 Decision tree — who patches what

```
Vulnerable layer?
├─ EKS control plane / managed-service software ────────► AWS patches. Our job: read the
│   (OpenSearch service binaries)                        notification, schedule/force it:
│                                                        aws opensearch start-service-software-update \
│                                                          --domain-name data-search
├─ Node OS / kernel / containerd / kubelet ─────────────► §7.3 emergency AMI (replace),
│                                                        §7.4 hotfix only if exploitation is active
├─ EC2 data-node OS ────────────────────────────────────► §7.4 targeted SSM install via the
│                                                        §6.3 orchestrator, out of window
├─ Container image contents (JDK, libs, Strimzi, NiFi) ─► Mirror pulls/rebuilds patched images →
│                                                        Harbor scan → ECR → rolling restarts
├─ Team-installed tarball (Kafka/NiFi on EC2) ──────────► Team upgrades from Artifactory;
│                                                        platform provides §6.3/§6.5 orchestration
├─ K8s workload manifests / Helm charts ────────────────► GitOps PR + rollout
└─ Model / dataset artifact ────────────────────────────► §7.6(c): freeze, verify hashes, re-pull
```

### 7.3 Emergency AMI fast path (Z2) — compressed §6.1→§6.2

```bash
# T+0h  Build now (both variants if kernel/containerd class):
aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <standard-arn>
aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <gpu-arn>
# T+2h  Candidate in SSM → canary MNG (24h soak collapses to 2h synthetic + §5.8 GPU smoke)
# T+4h  Promote + roll, with throughput raised for the event:
aws eks update-nodegroup-config --cluster-name data-platform --nodegroup-name mng-general \
  --update-config maxUnavailablePercentage=33
kubectl patch nodepool gpu-inference --type merge \
  -p '{"spec":{"disruption":{"budgets":[{"nodes":"50%"}]}}}'      # temporary; revert after
# mng-kafka stays at max_unavailable=1 regardless — Strimzi PDB + ISR gate protect it.
# T+72h Fleet done; restore normal budgets; attach Inspector before/after diff to the ticket.
```

### 7.4 In-place hotfix (only when replacement can't wait)

```bash
# Data nodes / utility hosts — targeted package update by patch group:
aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:corp:patch-group,Values=datanode-kafka \
  --max-concurrency 1 --max-errors 0 \
  --parameters 'commands=["dnf -y update openssl --refresh","systemctl restart kafka"]'
# EKS nodes may be hotfixed the same way in a true emergency, but ALWAYS chase with an AMI
# roll (§7.3): hand-patched cattle are drift, and the next scale-up resurrects the CVE.
```

### 7.5 Compromise containment & forensics (Z4/Z5) — ordered by volatility

Trigger: GuardDuty Runtime Monitoring finding (e.g. `Execution:Runtime/NewBinaryExecuted`, `CryptoCurrency:Runtime/BitcoinTool.B!DNS`), CloudTrail anomaly, or team report. **Preserve first, destroy last.** Open a case ID; every artifact gets `Key=CaseId,Value=IR-2026-NNN`.

```bash
I=i-0abc123def456; CASE=IR-2026-001
NODE=$(aws ec2 describe-instances --instance-ids $I \
  --query 'Reservations[0].Instances[0].PrivateDnsName' --output text)

# 1. STOP THE BLEEDING without destroying evidence
aws autoscaling set-instance-protection --instance-ids $I \
  --auto-scaling-group-name $(aws autoscaling describe-auto-scaling-instances --instance-ids $I \
    --query 'AutoScalingInstances[0].AutoScalingGroupName' --output text) \
  --protected-from-scale-in                      # ASG must not "heal" the evidence away
kubectl cordon $NODE
kubectl label node $NODE corp/quarantine=true --overwrite
cat <<'EOF' | kubectl apply -f -                 # freeze pod egress on the node's pods' namespaces as needed
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: ir-deny-all, namespace: suspect-ns }
spec: { podSelector: {}, policyTypes: [Ingress, Egress] }
EOF

# 2. VOLATILE CAPTURE over SSM (no SSH, no interactive shell on the box)
aws ssm send-command --instance-ids $I --document-name AWS-RunShellScript --parameters 'commands=[
  "date -u; uptime; who -a",
  "ss -pantu | head -100",
  "ps auxfww --sort=-%cpu | head -60",
  "crictl ps -a 2>/dev/null | head -40",
  "ls -la /proc/*/exe 2>/dev/null | grep deleted",
  "iptables-save | head -80"]' --output-s3-bucket-name corp-forensics --output-s3-key-prefix $CASE/volatile

# 3. MEMORY IMAGE (avml is baked into the AMI — §6.1) then disk snapshots
aws ssm send-command --instance-ids $I --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/bin/avml /tmp/mem.lime","aws s3 cp /tmp/mem.lime s3://corp-forensics/'$CASE'/mem.lime --expected-size $(stat -c%s /tmp/mem.lime)"]'
for v in $(aws ec2 describe-instances --instance-ids $I \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[].Ebs.VolumeId' --output text); do
  aws ec2 create-snapshot --volume-id $v \
    --description "$CASE $I $v" --tag-specifications "ResourceType=snapshot,Tags=[{Key=CaseId,Value=$CASE}]"
done
# Share snapshots to the security account (grant on the EBS KMS key first, or they can't decrypt):
aws ec2 modify-snapshot-attribute --snapshot-id snap-0123 --attribute createVolumePermission \
  --operation-type add --user-ids 999988887777

# 4. NETWORK ISOLATION — one SG that only allows 443 to the SSM endpoints (keeps capture alive),
#    then full-deny once capture is done:
aws ec2 modify-instance-attribute --instance-id $I --groups sg-0quarantine-capture
aws ec2 modify-instance-attribute --instance-id $I --groups sg-0quarantine-full

# 5. CREDENTIAL REVOCATION — the node role's existing sessions are the blast radius
aws iam put-role-policy --role-name eks-node-data-platform --policy-name AWSRevokeOlderSessions \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*",
    "Condition":{"DateLessThan":{"aws:TokenIssueTime":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}}]}'
# Healthy nodes re-auth automatically; the frozen instance's stolen creds die.
# Rotate every secret a pod on that node could read:
kubectl get pods -A --field-selector spec.nodeName=$NODE \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.spec.serviceAccountName}{"\n"}{end}' | sort -u
aws eks list-pod-identity-associations --cluster-name data-platform   # map SAs → IAM roles → rotate
aws secretsmanager rotate-secret --secret-id prod/agents/api-key

# 6. SCOPE THE BLAST RADIUS
# 6a. K8s audit (CloudWatch Logs Insights, log group /aws/eks/data-platform/cluster):
#   fields @timestamp, user.username, verb, requestURI
#   | filter requestURI like /exec/ or (objectRef.resource = "secrets" and verb = "get")
#   | filter sourceIPs.0 like /10\.20\./ | sort @timestamp desc | limit 200
# 6b. VPC Flow Logs in Athena — who did the instance talk to:
#   SELECT dstaddr, dstport, sum(bytes) b FROM vpc_flow_logs
#   WHERE srcaddr='10.20.1.45' AND day >= '2026/07/01'
#   GROUP BY 1,2 ORDER BY b DESC LIMIT 50;
# 6c. CloudTrail — API calls made with the instance's role session:
#   SELECT eventtime, eventname, errorcode FROM cloudtrail
#   WHERE useridentity.arn LIKE '%eks-node-data-platform%i-0abc123def456%'
#   ORDER BY eventtime DESC LIMIT 100;
aws guardduty list-findings --detector-id $GD --finding-criteria \
  '{"Criterion":{"resource.instanceDetails.instanceId":{"Eq":["'$I'"]}}}'

# 7. ERADICATE & RECOVER — terminate the instance ONLY after security sign-off; replacement
#    node comes from the current golden AMI; re-run §7.1 census to confirm no siblings.
# 8. REPORT — timeline, artifacts (S3 forensics bucket is Object-Lock/compliance-mode),
#    root cause, and the prevention PR (usually: image pin, NetworkPolicy, or IAM diet).
```

### 7.6 Worked micro-examples

**(a) Container-escape class (runc/containerd CVE)** — layer: node OS. Census: `aws ssm send-command ... 'commands=["runc --version; containerd --version"]'` against *all* EC2. Response: §7.3 emergency AMI both variants; data nodes don't run containerd → out of scope; interim mitigation: deny new `hostPID`/`privileged` pods via policy engine.

**(b) Critical JDK CVE** — hits three places at once: Strimzi/NiFi *images* (mirror pulls patched tags → Harbor → ECR → `kubectl -n kafka annotate strimzipodset dp-broker strimzi.io/manual-rolling-update=true` and NiFi StatefulSet rolling restart), EC2 *tarball* JVMs (`dnf -y update java-21-amazon-corretto-headless` via the §6.3 serial orchestrator — ISR-gated), and any team fat-jars (census via §7.1 step 2 `java -version` sweep; team action item).

**(c) Poisoned model artifact** (bad checksum or malicious pickle in the model bucket) — freeze: `aws s3api put-object-legal-hold --bucket corp-models --key llama-ft/v12/model.safetensors --legal-hold Status=ON`; verify fleet against the signed manifest: `aws s3api head-object ... --checksum-mode ENABLED` vs the release SHA-256 allowlist; scan with `modelscan` from the mirror; kill serving pods pinned to that version and revoke the agent runtime's pod-identity association until re-attested; trace who fetched it via S3 server-access logs / CloudTail data events.

---
## 8. What-If Scenario Library

Format per scenario: **Symptoms → Triage → Likely causes → Fix → Forensics → Prevention.** Quarterly game-days (P15) execute one of these for real.

### 8.1 What if pods cluster-wide go `ImagePullBackOff`? (mirror outage)

- **Symptoms:** New/restarted pods across namespaces fail pulls; running pods fine. `kubectl get events -A | grep -c ImagePull` climbing.
- **Triage:** `kubectl describe pod` → which registry host is failing? From the node: `kubectl debug node/<n> ... chroot /host crictl pull registry.corp.example.com/library/busybox:1.36`. Test TLS: `openssl s_client -connect registry.corp.example.com:443 -brief`. Check Harbor host: `aws ssm send-command --targets Key=tag:Name,Values=harbor ... 'systemctl status harbor; df -h'`.
- **Likely causes:** Harbor down/cert expired (§6.9 miss), Harbor disk full, corp DNS change, ECR VPC endpoint SG/policy change (then *ECR* pulls fail — different blast radius).
- **Fix:** Runtime pulls ride **ECR replicas**, so a Harbor outage should only block *new* vetting — if runtime broke, someone pointed workloads at Harbor directly (fix the manifests). Harbor cert: renew via cert-manager/ACM PCA, `systemctl restart harbor`. Disk: prune untagged artifacts + GC. Total loss: repoint `registry.corp.example.com` CNAME to the standby (`aws route53 change-resource-record-sets ...`).
- **Forensics:** Harbor nginx logs, VPC endpoint metrics (`aws cloudwatch get-metric-data` on endpoint bytes), config-change trail in CloudTrail (`events?ReadOnly=false` on the SG/endpoint).
- **Prevention:** ECR-for-runtime/Harbor-for-vetting split (already the design), cert expiry alarms 30d out (§6.9), Harbor storage alarm at 75%, monthly pull-path synthetic probe.

### 8.2 What if a Kafka broker's disk hits 90%?

- **Symptoms:** §5.1 PVC WARN → FAIL; producers see `NotEnoughReplicasException` if a broker drops from ISR; Strimzi condition warnings.
- **Triage:** Which volume and what's eating it:
  ```bash
  kubectl -n kafka exec dp-broker-2 -c kafka -- df -h /var/lib/kafka/data-0
  kubectl -n kafka exec dp-broker-2 -c kafka -- \
    bin/kafka-log-dirs.sh --bootstrap-server localhost:9092 --describe --broker-list 2 \
    | tail -1 | jq -r '.brokers[].logDirs[].partitions|sort_by(-.size)[:10][]|"\(.partition) \(.size)"'
  ```
- **Likely causes:** Retention set to "forever" on a fat topic, runaway producer (`rate(kafka_server_brokertopicmetrics_bytesin_total[10m])` by topic), consumer outage causing retention-by-size never to trigger, partition skew after reassignment.
- **Fix (fastest first):**
  ```bash
  # 1. Cut retention on the offender (takes effect within retention.check.interval):
  kubectl -n kafka exec dp-broker-0 -c kafka -- bin/kafka-configs.sh --bootstrap-server localhost:9092 \
    --alter --entity-type topics --entity-name telemetry-raw --add-config retention.ms=21600000
  # 2. Grow the volume — edit the Kafka CR storage size; Strimzi + gp3-data class expand PVCs online:
  kubectl -n kafka patch kafkanodepool broker --type merge \
    -p '{"spec":{"storage":{"volumes":[{"id":0,"type":"persistent-claim","size":"1500Gi","class":"gp3-data","deleteClaim":false}]}}}'
  kubectl -n kafka get pvc -l strimzi.io/pool-name=broker -w   # FileSystemResizePending → Bound
  # EC2 variant: aws ec2 modify-volume --volume-id vol-xxx --size 2500  && (on node) xfs_growfs /data
  ```
- **Forensics:** Producer identity via topic ACLs/quotas + client.id in request logs; when growth started: `increase(kafka_log_size[24h])` per topic.
- **Prevention:** 75/85% PVC alerts (§5.1), topic creation policy requiring explicit retention, client produce quotas (`kafka-configs --alter --entity-type clients --add-config producer_byte_rate=...`), quarterly §6.12 forecast.

### 8.3 What if the OpenSearch domain goes RED?

- **Symptoms:** `describe-domain-health` RED; writes to affected indices rejected; dashboards partial.
- **Triage:**
  ```bash
  curl -sk $AUTH "$DOMAIN/_cluster/allocation/explain?pretty" | jq '{index,shard,explanation:.allocate_explanation}'
  curl -sk $AUTH "$DOMAIN/_cat/shards?h=index,shard,prirep,state,unassigned.reason" | grep -v STARTED | head
  curl -sk $AUTH "$DOMAIN/_cat/allocation?v"      # disk watermark breach?
  ```
- **Likely causes:** Disk flood-stage (95%) marked indices read-only, node loss > replica count, a mapping explosion, snapshot-restore half-state.
- **Fix:**
  ```bash
  # Flood-stage: free space (delete/shrink old indices via ISM or _delete), grow EBS, then clear the block:
  aws opensearch update-domain-config --domain-name data-search \
    --ebs-options EBSEnabled=true,VolumeType=gp3,VolumeSize=768
  curl -sk $AUTH -XPUT "$DOMAIN/_all/_settings" -H 'Content-Type: application/json' \
    -d '{"index.blocks.read_only_allow_delete":null}'
  # Stuck-unassigned after transient failure:
  curl -sk $AUTH -XPOST "$DOMAIN/_cluster/reroute?retry_failed=true"
  # Truly lost primaries: restore those indices from the corp-s3 snapshot repo (§6.8).
  ```
- **Forensics:** `ES_APPLICATION_LOGS` in CloudWatch around the transition; correlate with ingest spikes (NiFi §5.7) and ISM failures (§5.5).
- **Prevention:** ISM rollover+delete on every time-series index, FreeStorageSpace alarm at 25%, shard sizing per §6.12, `auto_software_update_enabled=false` stays false so surprise blue/greens don't collide with ingest peaks.

### 8.4 What if Postgres hits a connection storm? (CNPG)

- **Symptoms:** Apps log `FATAL: sorry, too many clients already`; Keycloak 500s if it's the shared cluster; CNPG pods healthy but saturated.
- **Triage:**
  ```bash
  $PSQL "SELECT usename, state, count(*) FROM pg_stat_activity GROUP BY 1,2 ORDER BY 3 DESC"
  $PSQL "SELECT pid, now()-xact_start age, left(query,60) FROM pg_stat_activity
         WHERE state='idle in transaction' ORDER BY 2 DESC LIMIT 10"
  ```
- **Likely causes:** App deploy without pooling / leaking connections, idle-in-transaction pileup (locks!), batch job fan-out.
- **Fix:**
  ```bash
  $PSQL "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE state='idle in transaction' AND now()-xact_start > interval '10 min'"
  $PSQL "ALTER ROLE agent_app CONNECTION LIMIT 80"          # cap the offender
  # Durable fix: CNPG's built-in PgBouncer front-end:
  cat <<'EOF' | kubectl apply -f -
  apiVersion: postgresql.cnpg.io/v1
  kind: Pooler
  metadata: { name: keycloak-db-pooler, namespace: keycloak }
  spec:
    cluster: { name: keycloak-db }
    instances: 2
    type: rw
    pgbouncer: { poolMode: transaction, parameters: { max_client_conn: "1000", default_pool_size: "40" } }
  EOF
  # → repoint the app at keycloak-db-pooler-rw:5432
  ```
- **Forensics:** `pg_stat_statements` top offenders (§5.6), app deploy timeline vs connection count metric.
- **Prevention:** `idle_in_transaction_session_timeout` already set in §4.9.3; Pooler by default for chatty apps; per-role connection limits; alert at 80% of `max_connections`.

### 8.5 What if NiFi backpressure stalls a whole flow?

- **Symptoms:** §5.7 shows connections at 100%, `flowFilesQueued` flat-lining upward, downstream topics/indices go quiet.
- **Triage:** Find the *first* full connection in flow order (everything upstream backs up behind it); check the destination processor's bulletins and thread starvation (`activeThreadCount` pegged at max timer threads); repos disk (§5.7).
- **Likely causes:** Downstream sink slow/broken (OpenSearch RED → see 8.3, Kafka ISR issues → 8.2), under-provisioned processor concurrency, content repo disk full.
- **Fix:** Fix the sink first (it's usually a cascade from 8.2/8.3). Then relieve pressure: raise the connection's thresholds via API (`PUT /connections/{id}` with bumped `backPressureObjectThreshold`), add processor concurrent tasks, expand the content-repo PVC (gp3-data class → `kubectl patch pvc`), and only as a last resort empty a queue you can afford to lose: `POST /flowfile-queues/{id}/drop-requests` (**data loss — team sign-off required**). Node overloaded: offload it (`PUT /controller/cluster/nodes/{id}` state `OFFLOADING`).
- **Forensics:** Provenance query around the stall start; bulletin history; correlate with sink-side incident timeline.
- **Prevention:** Backpressure alerts at 80% (daily check already), sink SLOs surfaced on the same dashboard as flow health, quarterly load test of the top three flows.

### 8.6 What if GPU pods all go `Pending` after an AMI roll?

- **Symptoms:** Karpenter launches nodes, but `nvidia.com/gpu` allocatable is 0; device-plugin pods CrashLoop; inference queue (§5.8) climbing.
- **Triage:** `kubectl logs -n kube-system ds/nvidia-device-plugin` → NVML "driver/library version mismatch"; on-node `nvidia-smi` via SSM fails the same way. Compare driver label on old vs new nodes.
- **Likely causes:** New AMI's NVIDIA driver vs pinned CUDA/toolkit images mismatch; GPU pipeline validation phase skipped; wrong parent (standard AMI landed in the GPU EC2NodeClass tag family).
- **Fix:** Roll back fast — retag last-good AMI `corp:approved=true` and the bad one `=false` (Karpenter drifts back), or pin `amiSelectorTerms` to the known-good AMI ID; MNG GPU pools: `update-nodegroup-version --launch-template version=N-1`. Then fix the pipeline and re-run §6.2.
- **Forensics:** Image Builder build logs for the driver package version; diff `dnf list installed | grep nvidia` old vs new via SSM.
- **Prevention:** The §5.8 GPU smoke test is a **blocking gate** in the GPU canary (§6.2 step 1) — if this scenario happened, the gate was skipped; make it mechanical (pipeline test phase runs `nvidia-smi`).

### 8.7 What if nodes go `NotReady` after an emergency hotfix?

- **Symptoms:** Minutes after a §7.4 in-place patch, kubelet flaps; pods evicted in waves.
- **Triage:** `aws ssm start-session --target <i>` → `journalctl -u kubelet -u containerd --since -30min`; classic: hand-edited `/etc/containerd/config.toml` written in v2 schema against containerd 2.x (v3), or a conflicting sysctl.
- **Fix:** Restore the AMI-shipped config from the package backup, `systemctl restart containerd kubelet`; if widespread, stop patching and jump straight to §7.3 replacement — that's the lesson.
- **Forensics:** SSM command history (who ran what: `aws ssm list-commands --filter key=DocumentName,value=AWS-RunShellScript`), diff of the config file vs AMI baseline.
- **Prevention:** Policy line in §6.2 exists for this reason: **EKS nodes are replaced, not patched.** Hotfix path requires two-person review and always schedules the AMI chase.

### 8.8 What if Keycloak is down and nobody can log in?

- **Symptoms:** All OIDC logins fail (kubectl, Grafana, NiFi, Dashboards); *running* workloads unaffected (Pod Identity ≠ Keycloak).
- **First move — break-glass:** Platform admins authenticate via **IAM access entries** (deliberately independent of Keycloak): `aws eks update-kubeconfig --name data-platform` → full kubectl. This is why §4.8 keeps both layers.
- **Triage:** `kubectl -n keycloak get pods` — Keycloak pods usually CrashLooping on DB errors; `kubectl cnpg status keycloak-db -n keycloak` → primary unhealthy; logs show `PANIC: could not write to file "pg_wal/..." : No space left on device`.
- **Likely causes:** WAL volume full (archiving broken or retention outgrown), DB failover mid-flight, bad realm import.
- **Fix:**
  ```bash
  kubectl -n keycloak patch cluster keycloak-db --type merge \
    -p '{"spec":{"walStorage":{"size":"40Gi","storageClass":"gp3-data"}}}'   # online PVC expand
  kubectl -n keycloak get pvc -w
  # If archiving was the cause, verify barman is shipping again:
  kubectl cnpg status keycloak-db -n keycloak | grep -A3 'Continuous Backup'
  kubectl -n keycloak rollout restart deploy/keycloak
  ```
- **Forensics:** CNPG events + Postgres logs for when archiving first failed (it's usually days before the outage); S3 `corp-db-backups` last-object timestamp.
- **Prevention:** WAL PVC alert at 70%, §5.1 already checks CNPG archiving daily, quarterly break-glass drill so admins *know* the IAM path works.

### 8.9 What if this month's bill spikes 40%?

- **Symptoms:** §5.12 anomaly or the 80% forecast budget alert (§6.10).
- **Triage:** CUR query #2 (§6.10) → `DataTransfer-Regional-Bytes` doubled. Cross-AZ suspects in this stack, in order: **Kafka consumers fetching cross-AZ**, replication after a topic RF change, chatty pod-to-pod across AZs, OpenSearch client traffic.
- **Fix (Kafka case):** Server side is already set (`RackAwareReplicaSelector` in §4.9.1); the missing half is clients — teams set `client.rack=<az-id>` (derive from `topology.kubernetes.io/zone` downward API) so consumers **fetch from the local replica**. Verify with per-AZ `bytesout` before/after. GPU case: idle instances from §6.10 report → downscale NodePool limits. Logging case: a debug-level flood into CloudWatch → fix log level, add log-group retention.
- **Forensics:** Athena CUR by `resource_tags['corp:team']` day-over-day to name the owner; flow-logs top talkers by AZ pair.
- **Prevention:** `client.rack` in the team golden-config templates, per-team budgets, §5.12 daily cross-check stays boring.

### 8.10 What if GuardDuty flags a crypto-miner in a GPU pod?

Finding: `CryptoCurrency:Runtime/BitcoinTool.B!DNS` on `i-0abc...`, pod `agents/tool-runner-7f9`. This is the live-fire run of §7.5 — execute it verbatim, plus:

- **Immediate scoping:** `kubectl -n agents get pod tool-runner-7f9 -o jsonpath='{.spec.serviceAccountName}{" "}{.spec.nodeName}'`; check what that SA's pod identity can touch before revoking.
- **Typical root cause in an agent platform:** prompt-injected tool execution or a poisoned dependency in a team image that passed as "internal". The air gap blocks the pool connection (GuardDuty saw the *DNS attempt*) — the miner fails outbound, but the compromise is real.
- **Follow-ups beyond §7.5:** Harbor-scan the exact image digest; diff its SBOM against the previous tag; revoke and re-issue the namespace's pod-identity associations; add a NetworkPolicy default-deny egress for `agents` (only Kafka/OpenSearch/model endpoints allowed); feed the IOCs (domains, binary hashes) to corp SOC.
- **Evidence pack:** GuardDuty finding JSON, §7.5 volatile capture + memory image + snapshots, K8s audit slice, the image digest + SBOM diff — all under `s3://corp-forensics/IR-.../` (Object Lock).

### 8.11 What if every pipeline sits `pending`? (runners offline)

- **Symptoms:** Jobs queue for minutes→hours; GitLab runners page shows offline/stale; every team blocked at once.
- **Triage:** `kubectl -n gitlab-runners get pods` + `logs deploy/gitlab-runner | tail -30` — auth errors (token rotated but Secret not updated) vs network errors; reachability over TGW: `kubectl -n gitlab-runners exec deploy/gitlab-runner -- curl -m5 -skI https://gitlab.corp.example.com | head -1`; ASG health (§5.14); the **air-gap classic**: after a chart bump the `helper_image` pin was dropped → job pods stuck `ContainerCreating` trying to pull `registry.gitlab.com` (blocked) — `kubectl -n ci-jobs describe pod <j> | grep -A4 Events` shows it instantly.
- **Likely causes:** token rotation half-done, lost helper-image pin, TGW/SG change between VPC and GitLab, ASG at zero or LT pointing at a deregistered AMI.
- **Fix:** per cause — §6.13 step 2 in full for tokens; restore the pin and rollout; revert the network change; `update-auto-scaling-group --desired-capacity` / fix the LT AMI and instance-refresh.
- **Forensics:** git history of the values repo (who changed what), GitLab audit events for runner pause/delete, CloudTrail on the ASG/SG.
- **Prevention:** the §6.13 canary-pipeline gate; alert when `sum(gitlab_runner_jobs{state="running"}) == 0` in business hours while queue p95 rises; a lint in the values repo that fails if `helper_image` doesn't point at ECR.

### 8.12 What if a CI job leaks its cloud credentials?

- **Symptoms:** GuardDuty credential-exfiltration-class finding or anomalous CloudTrail calls from a `gl-*` role session; or a team reports a malicious MR editing `.gitlab-ci.yml`.
- **Why the blast radius is small by design (§4.10.3):** credentials live 1h, scoped to a single team deploy role, bound to protected refs (Pattern 1 `sub` condition / Pattern 2 protected ExternalId); fork/MR pipelines never see them; `ci-jobs` egress is default-deny except ECR/S3/STS/GitLab, so most exfil paths are dead ends.
- **Contain:**
  ```bash
  # Kill the stolen session NOW — same revocation pattern as §7.5 step 5, on the DEPLOY role:
  aws iam put-role-policy --role-name data-analytics-deploy --policy-name AWSRevokeOlderSessions     --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*",
      "Condition":{"DateLessThan":{"aws:TokenIssueTime":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}}]}'
  # Pattern 2: rotate the ExternalId; Pattern 1: temporarily drop the OIDC trust statement.
  curl -s -X PUT --header "PRIVATE-TOKEN: $GL_ADMIN_TOKEN" "$GL/runners/$RUNNER_ID" --form paused=true
  ```
- **Trace:** CloudTrail where `userIdentity.arn` contains the session name `gl-<project>-<pipeline>` → exact project, pipeline, commit, author; the pipeline job log and MR diff are the other half of the timeline. Cross-check GitLab audit events for who approved the MR.
- **Recover & prevent:** rotate everything the role could read; re-enable trust with tightened conditions; add the offending pattern to the pipeline-template lint (e.g. forbid `echo $AWS_*`, curl to non-allowlisted hosts); require code-owner approval for `.gitlab-ci.yml` changes on protected branches.

---
## 9. Appendices

### Appendix A — VPC endpoint checklist (what breaks without it)

| Endpoint | Purpose | Symptom if missing |
|---|---|---|
| `s3` (Gateway) | ECR layers, AL2023 repos, backups, CUR, forensics bucket | Pulls hang at layer download; dnf fails; barman/velero uploads fail |
| `ecr.api` + `ecr.dkr` | Image auth + registry | `ImagePullBackOff` with auth/DNS errors on every ECR pull |
| `eks` + `eks-auth` | Cluster API mgmt + Pod Identity credential vending | CLI/TF cluster ops fail; pods with pod-identity get no AWS creds |
| `sts` | IAM auth for nodes, Pod Identity, kubelogin | Nodes can't join; `aws sts get-caller-identity` times out |
| `ec2` + `autoscaling` + `elasticloadbalancing` | Node mgmt, MNG scaling, NLB/ALB controllers | Node group updates hang; LB provisioning stuck |
| `ssm` + `ssmmessages` + `ec2messages` | All fleet ops in this doc (sessions, run-command, patching, inventory) | Data nodes unmanageable; §6.3/§7.x dead |
| `logs` + `monitoring` | CloudWatch logs/metrics | Silent observability gap — everything "green" |
| `kms` | EBS/secrets/S3 encryption | Volumes won't attach; secrets undecryptable |
| `secretsmanager` | App/DB credentials | CSI secret mounts and rotation fail |
| `aps-workspaces` (if AMP) | Managed Prometheus remote-write | Metrics gap |
| `guardduty-data` | Runtime Monitoring agent telemetry | Runtime findings (§8.10) never fire |

### Appendix B — Tagging standard (enforced by SCP/IaC lint)

| Tag | Values / example | Drives |
|---|---|---|
| `corp:team` | `data-analytics` | Cost allocation, budgets, ownership paging |
| `corp:environment` | `prod` \| `nonprod` | Patch rings, guardrails |
| `corp:role` | `kafka` \| `postgres` \| `nifi` \| `eks-node` \| `ci-runner` | SSM targeting, prereq association, SGs |
| `corp:patch-group` | `datanode-kafka` … | Patch baselines & windows (§6.3) |
| `corp:backup` | `daily` | AWS Backup selection (§6.8) |
| `corp:approved` | `true` \| `pending-canary` \| `false` | Karpenter AMI drift gate (§6.2) |
| `corp:ami-family` | `eks-1.35-al2023-standard` | Node/AMI lineage |
| `CaseId` | `IR-2026-001` | Forensic artifact chain of custody (§7.5) |

### Appendix C — One-liner cheat sheet

```bash
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'   # anything unhappy
kubectl get pdb -A -o json | jq -r '.items[]|select(.status.disruptionsAllowed==0)|.metadata.name'
kubectl -n kafka exec dp-broker-0 -c kafka -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions
kubectl cnpg status keycloak-db -n keycloak
aws eks describe-cluster --name data-platform --query 'cluster.health.issues'
aws opensearch describe-domain-health --domain-name data-search
aws ssm describe-instance-information --filters Key=tag:corp:role,Values=kafka,postgres,nifi --query 'InstanceInformationList[?PingStatus!=`Online`].[InstanceId]'
aws ssm start-session --target i-0abc123def456          # never SSH
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[?State!=`available`].[ServiceName]'
aws ce get-anomalies --date-interval StartDate=$(date -d '2 days ago' +%F),EndDate=$(date +%F)
velero backup get | tail -3
curl -s --header "PRIVATE-TOKEN: $GL_ADMIN_TOKEN" "https://gitlab.corp.example.com/api/v4/runners/all?status=offline" | jq length
```

### Appendix D — Version pin reference (`platform/versions.yaml`, reviewed monthly)

```yaml
kubernetes: "1.35"            # next: 1.36 via §6.4
eks_addons:
  vpc-cni: v1.20.x-eksbuild.y
  coredns: v1.12.x-eksbuild.y
  kube-proxy: v1.35.x-eksbuild.y
  aws-ebs-csi-driver: v1.4x.x-eksbuild.y
  eks-pod-identity-agent: v1.3.x-eksbuild.y
karpenter: "1.x"
strimzi: "0.4x"
kafka: "4.0.x"                # metadataVersion pinned until §6.5 finalize
cloudnative_pg: "1.2x"
postgresql: "17.5"
nifi: "2.x"
keycloak: "26.x"
opensearch_engine: "OpenSearch_2.19"
java: "corretto-21"
terraform: ">= 1.10"          # S3-native locking (use_lockfile)
aws_provider: "~> 6.0"
gitlab_runner: "tracks corp GitLab minor"   # helper_image pin lives in the runner values (§4.10)
```

---

*End of plan. Sections are numbered for cross-reference from tickets; every runbook assumes air-gap constraints (mirror-only software, VPC-endpoint-only AWS APIs, SSM-only host access). Validate exact upstream versions at execution time — the pin file above is the single place to bump them.*
