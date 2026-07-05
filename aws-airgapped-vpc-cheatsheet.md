# AWS Air-Gapped VPC Cheat Sheet
### Access, Networking, Security Groups & IAM for EC2 + EKS

**Apps covered:** Kafka, NiFi, S3, OpenSearch, Databricks, Web Frontends
**Written in plain language with real examples.**

---

## Table of Contents
1. [Big Picture: What & Why](#1-big-picture-what--why)
2. [The 3 Layers of Access Control](#2-the-3-layers-of-access-control)
3. [Networking Basics (The Roads)](#3-networking-basics-the-roads)
4. [Security Groups (The Door Guards)](#4-security-groups-the-door-guards)
5. [IAM Roles (The ID Badges)](#5-iam-roles-the-id-badges)
6. [VPC Endpoints (The Secret Tunnels)](#6-vpc-endpoints-the-secret-tunnels)
7. [Per-App Setup & Scenarios](#7-per-app-setup--scenarios)
8. [EKS Node Access Deep Dive](#8-eks-node-access-deep-dive)
9. [Troubleshooting Playbook](#9-troubleshooting-playbook)
10. [Best Practices Checklist](#10-best-practices-checklist)

---

## 1. Big Picture: What & Why

### What is an "air-gapped" VPC?

Imagine a school building with **no doors to the outside world**. Students inside can walk between classrooms, but nobody can walk in from the street, and nobody inside can walk out to the street.

An **air-gapped VPC** is like that building. It's a private network in AWS that has **no direct path to the public internet**. No internet gateway. Traffic stays inside.

```
┌─────────────────────────────────────────┐
│   AIR-GAPPED VPC (no internet door)      │
│                                          │
│  [Kafka]  [NiFi]  [OpenSearch]           │
│     │        │         │                 │
│  [Web Frontend]   [Databricks]           │
│     │                                    │
│  [S3 via tunnel] ──► S3 (private tunnel) │
│                                          │
│   NO INTERNET GATEWAY                     │
└─────────────────────────────────────────┘
```

### Why do people build these?

| Reason | Simple Explanation |
|--------|-------------------|
| **Security** | If hackers can't reach it from the internet, they can't attack it from the internet. |
| **Compliance** | Rules for banks, hospitals, and government (HIPAA, PCI, FedRAMP) often require it. |
| **Data protection** | Your sensitive data can't accidentally "leak out" to the internet. |
| **Control** | You decide exactly what talks to what. Nothing happens by accident. |

### The tricky part

AWS services like S3 and OpenSearch normally live "on the internet." So how does your air-gapped app reach S3 if there's no internet? 

**Answer: VPC Endpoints** — private tunnels that connect your VPC directly to AWS services *without* going through the internet. (More in Section 6.)

---

## 2. The 3 Layers of Access Control

Think of getting a user into an app like getting a person into a locked room. There are **3 checkpoints**:

```
USER wants to reach an APP
        │
        ▼
┌───────────────────┐
│ 1. NETWORKING     │  "Is there even a road to get there?"
│    (Routes/Subnet)│   → Route tables, subnets
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ 2. SECURITY GROUP │  "Are you allowed through this door?"
│    (Firewall)     │   → Allow port 9092 from this IP
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ 3. IAM / AUTH     │  "Do you have the right ID badge?"
│    (Permissions)  │   → IAM role says you can read this S3 bucket
└───────────────────┘
        │
        ▼
   ACCESS GRANTED ✅
```

**Golden rule:** All 3 must pass. If a user can't reach an app, the problem is *always* in one of these 3 layers. Check them in order.

---

## 3. Networking Basics (The Roads)

### Key building blocks

| Term | Plain Meaning | School Analogy |
|------|--------------|----------------|
| **VPC** | Your private network in AWS | The whole school campus |
| **Subnet** | A smaller section of the VPC | One building on campus |
| **Route Table** | The map of which roads go where | Hallway signs pointing to rooms |
| **Private Subnet** | A subnet with no internet path | A building with no exit to the street |
| **CIDR block** | The range of IP addresses (like `10.0.0.0/16`) | The range of room numbers |

### Simple subnet plan for an air-gapped VPC

```
VPC: 10.0.0.0/16  (65,536 addresses total)
│
├── Subnet A (App tier):    10.0.1.0/24   → Kafka, NiFi
├── Subnet B (Data tier):   10.0.2.0/24   → OpenSearch, Databricks
├── Subnet C (Web tier):    10.0.3.0/24   → Web frontends
└── Subnet D (EKS nodes):   10.0.4.0/24   → Kubernetes worker nodes
```

**Why split into tiers?** So you can put different door guards (security groups) on each tier. The web tier can talk to the app tier, but random things can't reach your sensitive data tier.

### CLI: See your VPC and subnets

```bash
# List all your VPCs
aws ec2 describe-vpcs \
  --query "Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table

# List subnets in a specific VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-0abc123" \
  --query "Subnets[*].{Subnet:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}" \
  --output table

# Check a route table (make sure there's NO route to 0.0.0.0/0 via internet gateway)
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=vpc-0abc123" \
  --query "RouteTables[*].Routes" \
  --output table
```

**Air-gap check:** In your route tables, you should **NOT** see a line like `0.0.0.0/0 → igw-xxxx`. That would mean there's a door to the internet. If you see it, you're not air-gapped.

### Console: Check the same thing

1. Go to **VPC Console** → **Route Tables**
2. Pick your route table → **Routes** tab
3. Look for `0.0.0.0/0`. If the target is an **Internet Gateway (igw-)**, that's an open door. For air-gapped, you only want local routes and VPC endpoint routes.

---

## 4. Security Groups (The Door Guards)

### What is a Security Group (SG)?

A security group is a **firewall that wraps around a resource** (like an EC2 instance). It's a list of "who is allowed in and out."

**Key facts about SGs:**
- They are **stateful** — if you allow traffic IN, the reply is automatically allowed OUT. You don't need a matching rule for replies.
- They only have **ALLOW** rules. There are no "deny" rules. Anything not explicitly allowed is blocked.
- You can reference **another security group** as the source. This is the pro move (explained below).

### The single most useful trick: SG-to-SG references

Instead of allowing IP addresses (which change), allow **other security groups**. This is like saying "anyone wearing the *NiFi badge* can enter" instead of "the person in room 204 can enter."

```
┌──────────────────┐         allow port 9092         ┌──────────────────┐
│  NiFi instances  │ ──────── from sg-nifi ────────► │  Kafka instances │
│  (sg-nifi)       │                                 │  (sg-kafka)      │
└──────────────────┘                                 └──────────────────┘

Kafka's SG rule reads: "Allow TCP 9092 from source = sg-nifi"
```

Now you can add/remove NiFi machines all day. As long as they wear the `sg-nifi` badge, they're allowed. No IP updates ever needed.

### Common ports for your apps

| App | Port(s) | What it's for |
|-----|---------|--------------|
| **Kafka** | 9092 (plaintext), 9093 (TLS) | Sending/receiving messages |
| **Kafka (control)** | 9094 (controller), 2181 (Zookeeper, older setups) | Cluster coordination |
| **NiFi** | 8443 (HTTPS UI), 8080 (HTTP UI, older) | Web UI + data flow |
| **NiFi (cluster)** | 11443, 6342 | Node-to-node clustering |
| **OpenSearch** | 443 or 9200 (REST API), 9300 (node-to-node) | Search queries + cluster |
| **Databricks** | 443 (HTTPS), plus internal ports | Notebooks, cluster comms |
| **Web Frontend** | 443 (HTTPS), 80 (HTTP) | Users viewing the website |
| **SSH (admin)** | 22 | Logging into EC2 to manage it |
| **HTTPS (to AWS APIs)** | 443 | Talking to S3, etc. via endpoints |

### CLI: Create and manage security groups

```bash
# 1. Create a security group for Kafka
aws ec2 create-security-group \
  --group-name sg-kafka \
  --description "Kafka brokers - air-gapped" \
  --vpc-id vpc-0abc123
# Returns: "GroupId": "sg-kafka111"

# 2. Allow NiFi's SG to reach Kafka on port 9092 (SG-to-SG reference!)
aws ec2 authorize-security-group-ingress \
  --group-id sg-kafka111 \
  --protocol tcp \
  --port 9092 \
  --source-group sg-nifi222

# 3. Allow the web tier SG to reach OpenSearch on 9200
aws ec2 authorize-security-group-ingress \
  --group-id sg-opensearch333 \
  --protocol tcp \
  --port 9200 \
  --source-group sg-web444

# 4. See all rules on a security group
aws ec2 describe-security-groups \
  --group-ids sg-kafka111 \
  --query "SecurityGroups[0].IpPermissions" \
  --output json

# 5. Remove a rule (if you made a mistake)
aws ec2 revoke-security-group-ingress \
  --group-id sg-kafka111 \
  --protocol tcp \
  --port 9092 \
  --source-group sg-nifi222
```

### Console: Create a security group rule

1. **EC2 Console** → **Security Groups** → select your SG
2. **Inbound rules** tab → **Edit inbound rules**
3. **Add rule** → choose **Type** (e.g., Custom TCP), enter **Port** (e.g., 9092)
4. Under **Source**, choose **Custom** and start typing `sg-` to pick another security group
5. **Save rules**

### Example scenario: "A NiFi flow needs to push data into Kafka"

**Goal:** NiFi machines send data to Kafka on port 9092.

```bash
# Kafka's SG must allow NiFi's SG on 9092
aws ec2 authorize-security-group-ingress \
  --group-id sg-kafka111 \
  --protocol tcp --port 9092 \
  --source-group sg-nifi222
```

That's it for the firewall. (You'll still need auth — see IAM/Kafka ACLs in Section 7.)

---

## 5. IAM Roles (The ID Badges)

### What is IAM?

**IAM = Identity and Access Management.** It answers: *"Who are you, and what are you allowed to do in AWS?"*

Even if a machine can reach S3 through the network, it still needs **permission** to actually read or write files. That permission comes from IAM.

### Users vs. Roles — the key difference

| Thing | What it is | When to use |
|-------|-----------|-------------|
| **IAM User** | A permanent identity with a password/keys for a *person* | Rarely for apps. Avoid long-lived keys. |
| **IAM Role** | A temporary "hat" that a machine or service *wears* | **Almost always use this for EC2/EKS.** |

**Why roles are better than users for machines:**
- Roles give **temporary** credentials that auto-rotate. No passwords sitting on disk to be stolen.
- You attach a role to an EC2 instance, and any app on that machine automatically gets those permissions.

### How an EC2 instance "wears" a role

```
┌─────────────────────────────────────┐
│  EC2 Instance                        │
│  ┌────────────────────────────────┐  │
│  │ Instance Profile               │  │  ← the "hat rack"
│  │   holds → IAM Role             │  │  ← the "hat"
│  │            → IAM Policy         │  │  ← what the hat lets you do
│  └────────────────────────────────┘  │
│                                      │
│  App runs → automatically gets       │
│  temporary AWS credentials           │
└─────────────────────────────────────┘
```

### The 3 parts of an IAM permission

1. **Policy** — a JSON document listing what's allowed (e.g., "read bucket `my-data`").
2. **Role** — a container that policies attach to.
3. **Trust policy** — says *who* is allowed to wear this role (e.g., "EC2 instances can wear this").

### Example: An IAM policy to read one S3 bucket

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadMyDataBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::my-data-bucket",
        "arn:aws:s3:::my-data-bucket/*"
      ]
    }
  ]
}
```

**Reading this like a sentence:** "Allow the actions *GetObject* and *ListBucket* on the bucket *my-data-bucket* and everything inside it."

### Example: Trust policy (who can wear this role?)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Reading this:** "EC2 instances are allowed to assume (wear) this role."

### CLI: Create a role and attach it to EC2

```bash
# 1. Create the role with the trust policy (from a file trust.json)
aws iam create-role \
  --role-name ec2-s3-reader \
  --assume-role-policy-document file://trust.json

# 2. Create the permission policy (from a file s3policy.json)
aws iam create-policy \
  --policy-name read-my-data \
  --policy-document file://s3policy.json
# Returns an ARN like: arn:aws:iam::123456789012:policy/read-my-data

# 3. Attach the policy to the role
aws iam attach-role-policy \
  --role-name ec2-s3-reader \
  --policy-arn arn:aws:iam::123456789012:policy/read-my-data

# 4. Create an instance profile (the "hat rack") and add the role
aws iam create-instance-profile --instance-profile-name ec2-s3-reader-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name ec2-s3-reader-profile \
  --role-name ec2-s3-reader

# 5. Attach the instance profile to a running EC2 instance
aws ec2 associate-iam-instance-profile \
  --instance-id i-0abc123 \
  --iam-instance-profile Name=ec2-s3-reader-profile
```

### Console: Attach a role to EC2

1. **EC2 Console** → select instance → **Actions** → **Security** → **Modify IAM role**
2. Pick the role from the dropdown → **Update IAM role**

### CLI: Verify what role an instance is using

```bash
# From your laptop:
aws ec2 describe-instances \
  --instance-ids i-0abc123 \
  --query "Reservations[0].Instances[0].IamInstanceProfile" \
  --output json

# From INSIDE the EC2 instance (uses the metadata service):
# IMDSv2 (the secure way) — get a token first, then ask
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

**Least privilege = the #1 IAM best practice.** Only grant exactly what's needed. Start with nothing, add permissions until the app works. Never use `"Action": "*"` on `"Resource": "*"` in production.

---

## 6. VPC Endpoints (The Secret Tunnels)

### The problem they solve

Your air-gapped VPC has no internet. But S3, OpenSearch, and other AWS services live outside your VPC. **VPC Endpoints** are private tunnels that let you reach these services without ever touching the internet.

```
WITHOUT endpoint (normal internet - NOT allowed in air-gap):
[EC2] ──► Internet Gateway ──► Internet ──► S3   ❌

WITH VPC endpoint (private tunnel - air-gap friendly):
[EC2] ──► VPC Endpoint ──► (AWS private network) ──► S3   ✅
```

### Two types of endpoints

| Type | Used for | How it works | Cost |
|------|----------|--------------|------|
| **Gateway Endpoint** | **S3** and **DynamoDB** only | Adds a route in your route table | **Free** |
| **Interface Endpoint** | Almost everything else (OpenSearch, STS, ECR, EC2 API, etc.) | Puts a private network card (ENI) in your subnet with a private IP | Hourly + data cost |

### Why you NEED these for air-gapped setups

Without endpoints, your air-gapped machines literally cannot:
- Read/write S3 (need **S3 gateway endpoint**)
- Wear IAM roles that call other services (need **STS interface endpoint**)
- Pull container images for EKS (need **ECR + ECR-DKR interface endpoints**)
- Send logs to CloudWatch (need **logs interface endpoint**)

### Essential endpoints checklist for your stack

```
□ com.amazonaws.<region>.s3           (Gateway)   → S3 access
□ com.amazonaws.<region>.sts          (Interface) → IAM role assumption
□ com.amazonaws.<region>.ec2          (Interface) → EC2 API calls
□ com.amazonaws.<region>.ecr.api      (Interface) → EKS pull images (auth)
□ com.amazonaws.<region>.ecr.dkr      (Interface) → EKS pull images (data)
□ com.amazonaws.<region>.logs         (Interface) → CloudWatch Logs
□ com.amazonaws.<region>.monitoring   (Interface) → CloudWatch Metrics
□ com.amazonaws.<region>.elasticloadbalancing (Interface) → EKS load balancers
□ com.amazonaws.<region>.es           (Interface) → OpenSearch (managed)
□ com.amazonaws.<region>.eks          (Interface) → EKS control plane API
□ com.amazonaws.<region>.autoscaling  (Interface) → EKS node scaling
```

### CLI: Create the S3 gateway endpoint (free, do this first)

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0abc123 \
  --service-name com.amazonaws.us-east-1.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids rtb-0def456
```

### CLI: Create an interface endpoint (e.g., for STS)

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0abc123 \
  --service-name com.amazonaws.us-east-1.sts \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-0aaa subnet-0bbb \
  --security-group-ids sg-endpoints555 \
  --private-dns-enabled
```

**Important:** Interface endpoints need their own security group that **allows port 443 inbound** from your app subnets. Otherwise the tunnel exists but the door is locked.

```bash
# Let all your VPC's resources reach the endpoint on 443
aws ec2 authorize-security-group-ingress \
  --group-id sg-endpoints555 \
  --protocol tcp --port 443 \
  --cidr 10.0.0.0/16
```

### The `--private-dns-enabled` magic

When you enable private DNS, the normal AWS hostname (like `s3.us-east-1.amazonaws.com`) **automatically points to your private tunnel** instead of the internet. Your apps don't need any code changes — they use the normal address and traffic silently goes through the tunnel.

### Console: Create a VPC endpoint

1. **VPC Console** → **Endpoints** → **Create endpoint**
2. Choose the **Service** (search "s3", "sts", etc.)
3. Pick your **VPC** and **subnets**
4. Pick a **security group** (must allow 443 for interface endpoints)
5. Check **Enable DNS name** (private DNS)
6. **Create endpoint**

---

## 7. Per-App Setup & Scenarios

### 🟦 S3 (Object Storage)

**What it is:** A giant filing cabinet in the cloud for storing files (data, backups, logs).

**Access layers:**
1. **Network:** S3 Gateway Endpoint (free)
2. **Firewall:** No SG on S3 itself, but the endpoint's route must exist
3. **IAM:** Role with `s3:GetObject`, `s3:PutObject`, etc.
4. **Bucket policy:** An extra lock on the bucket itself

**Scenario: "Only my air-gapped VPC can access this bucket"**

Add a bucket policy that only allows requests coming through your VPC endpoint:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OnlyFromMyVPCEndpoint",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::my-data-bucket",
        "arn:aws:s3:::my-data-bucket/*"
      ],
      "Condition": {
        "StringNotEquals": {
          "aws:sourceVpce": "vpce-0abc123endpoint"
        }
      }
    }
  ]
}
```

**Reading this:** "Deny ALL S3 actions on this bucket UNLESS the request comes through my VPC endpoint `vpce-0abc123`." This is a powerful lock — even someone with correct IAM keys can't reach the bucket from the internet.

```bash
# Test S3 access from inside an EC2 instance
aws s3 ls s3://my-data-bucket/
aws s3 cp test.txt s3://my-data-bucket/test.txt
```

---

### 🟧 Kafka (Message Streaming)

**What it is:** A super-fast mail system. Apps drop messages into "topics"; other apps pick them up. Great for moving lots of data between systems.

**Access layers:**
1. **Network:** All in-VPC, so just subnets/routes
2. **Firewall:** SG allowing 9092 (or 9093 for TLS) from producer/consumer SGs
3. **Auth:** Kafka's own security (see below) + optionally IAM for MSK

**Two flavors of Kafka:**

| Flavor | Auth method |
|--------|-------------|
| **Self-managed on EC2** | Kafka ACLs, SASL/SCRAM, mTLS certificates |
| **Amazon MSK (managed)** | **IAM auth** (easiest!), or SASL/SCRAM, or mTLS |

**Scenario (MSK with IAM): "Let NiFi produce to a Kafka topic"**

MSK IAM policy for the NiFi role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kafka-cluster:Connect",
        "kafka-cluster:WriteData",
        "kafka-cluster:DescribeTopic"
      ],
      "Resource": [
        "arn:aws:kafka:us-east-1:123456789012:cluster/my-cluster/*",
        "arn:aws:kafka:us-east-1:123456789012:topic/my-cluster/*/orders-topic"
      ]
    }
  ]
}
```

Plus the SG rule:
```bash
# MSK IAM auth uses port 9098
aws ec2 authorize-security-group-ingress \
  --group-id sg-msk111 \
  --protocol tcp --port 9098 \
  --source-group sg-nifi222
```

**Scenario (self-managed): Kafka ACL to let a user write**
```bash
# Run on a Kafka broker
kafka-acls.sh --bootstrap-server localhost:9092 \
  --add --allow-principal User:nifi-app \
  --operation Write --topic orders-topic
```

---

### 🟩 NiFi (Data Flow Tool)

**What it is:** A visual drag-and-drop tool for moving and transforming data. You build "flows" like connecting pipes: pull from here → clean it → push to there.

**Access layers:**
1. **Network:** In-VPC subnets
2. **Firewall:** SG allowing 8443 (HTTPS UI) from admin users; cluster ports between NiFi nodes
3. **Auth:** NiFi user login (LDAP, certificates, OIDC) + NiFi's internal policies

**Scenario: "Let a data engineer log into the NiFi UI"**

```bash
# Allow the engineer's workstation SG (or a bastion) to reach NiFi UI on 8443
aws ec2 authorize-security-group-ingress \
  --group-id sg-nifi222 \
  --protocol tcp --port 8443 \
  --source-group sg-bastion999
```

Since you're air-gapped, users typically reach the NiFi UI through:
- A **bastion host** / **jump box** inside the VPC, or
- **AWS Systems Manager Session Manager** (no open ports needed — see troubleshooting), or
- A **VPN** or **Direct Connect** into the VPC

**Inside NiFi**, you still assign user policies (view flow, modify flow, etc.) in the NiFi UI under **Access Policies**. Network access ≠ app permission.

---

### 🟪 OpenSearch (Search & Analytics)

**What it is:** A search engine for your data. Store logs/documents, then search and make dashboards (like a private Google for your data).

**Access layers:**
1. **Network:** For managed OpenSearch in "VPC mode," it lives in your subnets. Use the `es` interface endpoint if needed.
2. **Firewall:** SG allowing 443/9200 from your app + dashboard users
3. **Auth:** **Two locking systems** — IAM (domain access policy) AND Fine-Grained Access Control (internal users/roles)

**Scenario: "Let the web frontend query OpenSearch, but only read"**

Domain access policy (IAM-based):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:role/web-frontend-role"
      },
      "Action": [
        "es:ESHttpGet",
        "es:ESHttpPost"
      ],
      "Resource": "arn:aws:es:us-east-1:123456789012:domain/my-search/*"
    }
  ]
}
```

SG rule:
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-opensearch333 \
  --protocol tcp --port 443 \
  --source-group sg-web444
```

**Fine-Grained Access Control (FGAC)** lets you go deeper — control access down to specific indexes or even fields, and map users to roles like `readall` or `all_access`. Configure it in the **OpenSearch Dashboards → Security** panel.

```bash
# Test OpenSearch from an EC2 (using SigV4 auth via awscurl, or IAM)
curl -s https://my-search.us-east-1.es.amazonaws.com/_cluster/health?pretty
```

---

### 🟨 Databricks (Data Analytics Platform)

**What it is:** A workspace for data scientists to run big data jobs and notebooks (using Spark). Think "Google Docs for crunching huge datasets."

**Air-gap note:** Databricks on AWS usually runs in a **customer-managed VPC**. For a private/locked-down setup, you use:
- **Secure Cluster Connectivity (SCC / No Public IP)** — cluster nodes have no public IPs
- **PrivateLink** — private tunnels between your VPC, the Databricks control plane, and the workspace
- **VPC endpoints** for the Databricks REST APIs and the secure cluster relay

**Access layers:**
1. **Network:** Databricks clusters run in *your* subnets; PrivateLink connects to Databricks' control plane privately
2. **Firewall:** Databricks requires specific SG rules — nodes must talk to each other on **all ports** within the cluster SG, plus 443 outbound to the control plane (via PrivateLink)
3. **IAM:** An **instance profile** (role) that Databricks clusters wear to reach S3 and other AWS services
4. **Auth:** Databricks' own user login (SSO/SCIM) + workspace access controls

**Scenario: "Let a Databricks cluster read data from S3"**

Create an instance profile role (same steps as Section 5), then register it in Databricks:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::databricks-data",
        "arn:aws:s3:::databricks-data/*"
      ]
    }
  ]
}
```

**Databricks-required SG self-reference** (nodes must talk to each other):
```bash
# Allow all traffic between nodes in the same Databricks SG
aws ec2 authorize-security-group-ingress \
  --group-id sg-databricks777 \
  --protocol -1 \
  --source-group sg-databricks777
```

In the Databricks Admin Console, go to **Settings → Instance Profiles** and add the role's ARN. Then clusters can be launched with that instance profile to access S3.

---

### 🟥 Web Frontends

**What it is:** The websites/dashboards users actually look at in their browser.

**Access layers:**
1. **Network:** Sits in a web-tier subnet; reachable by users via internal ALB, VPN, or PrivateLink
2. **Firewall:** SG allowing 443 from the load balancer; the load balancer's SG allows users
3. **Auth:** App-level login (Cognito, OIDC, SAML)

**Scenario: "Users on the corporate network reach the internal web app"**

For air-gapped, users usually connect through:
- **Internal Application Load Balancer (ALB)** — `internal` scheme, no public IP
- Reached via **VPN**, **Direct Connect**, or **Transit Gateway** from the corporate network

```
Corporate User ──VPN──► Transit Gateway ──► Internal ALB ──► Web Frontend EC2
```

SG layering:
```bash
# 1. ALB allows users from corporate CIDR on 443
aws ec2 authorize-security-group-ingress \
  --group-id sg-alb888 \
  --protocol tcp --port 443 \
  --cidr 172.16.0.0/12   # corporate network range

# 2. Web frontend only allows the ALB (not users directly!)
aws ec2 authorize-security-group-ingress \
  --group-id sg-web444 \
  --protocol tcp --port 443 \
  --source-group sg-alb888
```

**Best practice:** Users should *never* hit the web servers directly. They hit the load balancer, which forwards to the servers. This lets you scale, patch, and secure the servers behind the scenes.

---

## 8. EKS Node Access Deep Dive

### What is EKS?

**EKS = Elastic Kubernetes Service.** Kubernetes is a system that runs your apps in "containers" (lightweight packages) and manages them automatically. EKS is AWS's managed version. Your apps run on **worker nodes** (EC2 instances).

### The special access challenge with EKS

EKS has **TWO permission systems** that must work together:

```
┌─────────────────────────────────────────┐
│  1. AWS IAM  (who can touch AWS stuff)   │
│     → e.g., nodes pull images from ECR   │
└─────────────────────────────────────────┘
              +
┌─────────────────────────────────────────┐
│  2. Kubernetes RBAC (who can do what     │
│     INSIDE the cluster)                   │
│     → e.g., who can create pods           │
└─────────────────────────────────────────┘
```

The bridge between them is called **IAM Roles for Service Accounts (IRSA)** or the newer **EKS Pod Identity**.

### Node IAM role — the minimum badges every node needs

Worker nodes need a role with these AWS-managed policies:

```
□ AmazonEKSWorkerNodePolicy       → basic node operation
□ AmazonEC2ContainerRegistryReadOnly → pull container images from ECR
□ AmazonEKS_CNI_Policy            → networking for pods
```

```bash
# Create the node role
aws iam create-role \
  --role-name eks-node-role \
  --assume-role-policy-document file://ec2-trust.json

# Attach the three required policies
aws iam attach-role-policy --role-name eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
```

### Air-gap requirement: nodes can't pull images without endpoints!

This is the **#1 gotcha** for air-gapped EKS. Nodes try to pull container images from ECR, but there's no internet. You **MUST** have these endpoints:

```
□ com.amazonaws.<region>.ecr.api    (Interface)
□ com.amazonaws.<region>.ecr.dkr    (Interface)
□ com.amazonaws.<region>.s3         (Gateway - ECR stores image layers in S3!)
□ com.amazonaws.<region>.sts        (Interface - for IRSA)
□ com.amazonaws.<region>.eks        (Interface)
□ com.amazonaws.<region>.logs       (Interface - for logging)
```

**Surprise fact:** ECR stores the actual image data in S3 behind the scenes. So even for pulling images, you need the **S3 gateway endpoint** too. Miss this and images fail to pull with confusing errors.

### IRSA: giving a specific pod (not the whole node) AWS permissions

**Why:** Instead of giving *every* pod on a node the same broad permissions, IRSA lets *one specific app* get *exactly* the permissions it needs. This is least-privilege for Kubernetes.

```
┌────────────────────────────────────────────────┐
│  Pod (your app)                                 │
│    uses → Kubernetes Service Account            │
│              linked to → IAM Role               │
│                            → IAM Policy         │
│                                                 │
│  Result: ONLY this pod can read that S3 bucket  │
└────────────────────────────────────────────────┘
```

**Setup steps (using eksctl, the easy way):**

```bash
# 1. Enable the OIDC provider for your cluster (one-time)
eksctl utils associate-iam-oidc-provider \
  --cluster my-cluster --approve

# 2. Create a service account tied to an IAM policy
eksctl create iamserviceaccount \
  --cluster my-cluster \
  --namespace default \
  --name s3-reader-sa \
  --attach-policy-arn arn:aws:iam::123456789012:policy/read-my-data \
  --approve
```

Then in your pod spec, use that service account:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  serviceAccountName: s3-reader-sa   # ← this pod now has S3 read access
  containers:
  - name: app
    image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest
```

### aws-auth: letting humans and node roles into the cluster

The `aws-auth` ConfigMap maps AWS IAM identities to Kubernetes users/groups. **If a node's role isn't in here, nodes can't join the cluster.**

```bash
# View the current mapping
kubectl get configmap aws-auth -n kube-system -o yaml

# Easy way to add a user's access with eksctl
eksctl create iamidentitymapping \
  --cluster my-cluster \
  --arn arn:aws:iam::123456789012:role/DataEngineerRole \
  --group system:masters \
  --username data-engineer
```

> **Note:** Newer EKS supports **Access Entries** (an API-based replacement for editing `aws-auth` by hand). Check with:
> ```bash
> aws eks list-access-entries --cluster-name my-cluster
> ```

### Security groups for EKS

```
□ Cluster SG:  control plane ↔ nodes (usually auto-created)
□ Node SG:     node ↔ node (pods talking to each other)
□ Pod SG:      (optional) "Security Groups for Pods" for fine control
```

```bash
# Nodes must talk to each other on all ports (pod networking)
aws ec2 authorize-security-group-ingress \
  --group-id sg-eksnodes444 \
  --protocol -1 \
  --source-group sg-eksnodes444

# Control plane to nodes on 443 and 10250 (kubelet)
aws ec2 authorize-security-group-ingress \
  --group-id sg-eksnodes444 \
  --protocol tcp --port 10250 \
  --source-group sg-ekscontrol555
```

---

## 9. Troubleshooting Playbook

### The universal debugging order

When something can't connect, **always check in this order** — it saves hours:

```
1. NETWORK  → Is there a route? Right subnet? Endpoint exists?
2. SECURITY GROUP → Is the port open from the right source?
3. NACL → (rarely) Is the subnet-level firewall blocking?
4. DNS → Is the name resolving to the right (private) address?
5. IAM → Does the role/policy allow the action?
6. APP AUTH → Does the app's own login/ACL allow the user?
```

### Symptom → Likely Cause table

| Symptom | Most Likely Cause | Where to Look |
|---------|------------------|---------------|
| **Connection times out** | Security group or route missing | SG inbound rules; route table |
| **Connection refused** | App not running / wrong port | SSH in, check the service |
| **"Access Denied" from AWS** | IAM permission missing | Role policy; bucket policy |
| **S3 works from internet but not VPC** | Missing S3 gateway endpoint | VPC Endpoints |
| **EKS pods stuck "ImagePullBackOff"** | Missing ECR/S3 endpoints | VPC Endpoints; node role |
| **Name resolves to public IP** | Private DNS not enabled on endpoint | Endpoint settings |
| **IAM role "works" but calls fail in air-gap** | Missing STS endpoint | VPC Endpoints |
| **Node won't join EKS cluster** | Node role not in aws-auth | aws-auth ConfigMap |
| **Can reach app but "forbidden"** | App-level auth (NiFi/OpenSearch policy) | App's own security panel |

### Handy diagnostic commands

**Test raw network connectivity (is the door even reachable?):**
```bash
# nc = netcat. Tests if a port is open. Install with: yum install nc
nc -zv 10.0.2.50 9092
# "succeeded" = port open. "timed out" = SG/route problem.

# Trace the route (where does traffic die?)
traceroute 10.0.2.50
```

**Check DNS resolution (is the name pointing to a private IP?):**
```bash
nslookup my-search.us-east-1.es.amazonaws.com
# Should return a 10.x.x.x address (private), NOT a public one.
# If public, your private DNS on the endpoint isn't working.
```

**AWS Reachability Analyzer (the magic troubleshooter):**
```bash
# AWS will tell you EXACTLY where traffic is blocked between two points
aws ec2 create-network-insights-path \
  --source i-0source123 \
  --destination i-0dest456 \
  --protocol tcp \
  --destination-port 9092

# Then analyze it
aws ec2 start-network-insights-analysis \
  --network-insights-path-id nip-0abc123
```
This tool traces the entire path and points to the exact SG, route, or NACL that's blocking. **Use it first — it saves the most time.**

**Simulate IAM permissions (without breaking anything):**
```bash
# Ask "would this role be allowed to do this action?"
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/ec2-s3-reader \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::my-data-bucket/file.txt
```

**Check endpoints exist and are healthy:**
```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=vpc-0abc123" \
  --query "VpcEndpoints[*].{Service:ServiceName,State:State,Type:VpcEndpointType}" \
  --output table
```

**No SSH? Use Session Manager (great for air-gapped admin):**
```bash
# Connect to an instance with NO open ports and NO SSH key
# (requires the SSM agent + ssmmessages/ec2messages/ssm endpoints)
aws ssm start-session --target i-0abc123
```
This is the **preferred way** to reach machines in an air-gapped VPC for admin — no bastion, no open port 22 needed. You just need these three interface endpoints:
```
□ com.amazonaws.<region>.ssm
□ com.amazonaws.<region>.ssmmessages
□ com.amazonaws.<region>.ec2messages
```

### EKS-specific troubleshooting

```bash
# Why is a pod stuck? (shows events at the bottom)
kubectl describe pod my-app

# Are nodes healthy and joined?
kubectl get nodes -o wide

# Check what a service account maps to
kubectl describe sa s3-reader-sa

# See node logs on the actual EC2
journalctl -u kubelet -f
```

**"ImagePullBackOff" in air-gap** → 99% of the time it's a missing ECR/S3 endpoint or the node role is missing `AmazonEC2ContainerRegistryReadOnly`.

---

## 10. Best Practices Checklist

### 🔒 Security
```
□ Use IAM ROLES, never long-lived access keys, for EC2/EKS
□ Follow LEAST PRIVILEGE — grant only what's needed, nothing more
□ Reference SECURITY GROUPS, not IP addresses, in SG rules
□ Enforce IMDSv2 on all instances (blocks credential theft)
□ Put a VPC-endpoint condition on sensitive S3 buckets
□ Never allow 0.0.0.0/0 inbound on app ports
□ Encrypt data at rest (S3, OpenSearch, EBS) and in transit (TLS)
□ Use separate roles per app — don't share one big role
```

### 🌐 Networking
```
□ Confirm NO internet gateway route (0.0.0.0/0 → igw) exists
□ Split resources into tiers (web / app / data) with separate subnets
□ Create the S3 GATEWAY endpoint (free) first
□ Create INTERFACE endpoints for STS, ECR, logs, and each service used
□ Enable PRIVATE DNS on interface endpoints
□ Add 443 inbound rules on the endpoint security group
□ Use internal load balancers (never internet-facing) for web apps
□ Reach the VPC via VPN / Direct Connect / Transit Gateway, not internet
```

### ⚙️ EKS Specific
```
□ Node role has the 3 required policies (Worker, ECR-ReadOnly, CNI)
□ ECR-api, ECR-dkr, AND S3 endpoints exist (all needed for image pulls)
□ STS endpoint exists (required for IRSA)
□ Node role is mapped in aws-auth (or via Access Entries)
□ Use IRSA / Pod Identity for per-pod permissions (not node-wide)
□ Node SG allows node-to-node on all ports
```

### 🛠️ Operations
```
□ Use Session Manager for admin (no open SSH ports)
□ Turn on VPC Flow Logs to see what's being blocked
□ Turn on CloudTrail to audit who did what
□ Learn Reachability Analyzer — it finds blocks fast
□ Tag everything (Name, Environment, Owner) for sanity
□ Test IAM changes with simulate-principal-policy before deploying
□ Document your endpoint list — air-gap breaks silently without them
```

### The mental model to remember

```
Every access problem = ONE of these 3 layers:

  🛣️  NETWORK    → "Is there a road?"     (routes, subnets, endpoints)
  🚪  FIREWALL   → "Is the door open?"    (security groups, NACLs)
  🪪  PERMISSION → "Do you have a badge?" (IAM, app auth)

Check them IN ORDER. The answer is always in one of them.
```

---

*End of cheat sheet. Replace all example IDs (vpc-, sg-, subnet-, i-, arn:) with your real values.*
