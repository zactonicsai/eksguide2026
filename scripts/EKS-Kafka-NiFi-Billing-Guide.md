# The Complete Money Guide: What AWS Charges You for an EKS Cluster Running Kafka (Strimzi) and NiFi

> **Written in plain language.** Every price below is an approximate US East (N. Virginia)
> "on-demand" list price as of mid-2026. Prices change over time and differ by region, so
> always double-check the [AWS Pricing Calculator](https://calculator.aws/).

---

## 1. Meet the Players (Quick Intro)

Before we talk about money, let's meet the characters in this story:

| Player | What it really is | Easy way to picture it |
|---|---|---|
| **Kubernetes** | Software that manages apps running in containers | A robot manager that starts, stops, and heals your apps |
| **Amazon EKS** | AWS runs the Kubernetes "brain" for you | You rent the robot manager instead of building one |
| **Apache Kafka** | A super-fast message system between apps | A giant post office with conveyor belts of messages |
| **Strimzi** | An "operator" that installs and repairs Kafka inside Kubernetes | A helper robot that builds and fixes the post office for you |
| **Apache NiFi** | A tool that moves and transforms data between systems | Smart plumbing: pipes that carry data and can clean it along the way |

**The big picture:** EKS is the mall building. Kafka is the post office inside the mall.
NiFi is the plumbing. AWS charges you rent for the building, the electricity, the water,
the parking lot, the front doors, and even the security cameras. Each of those "utilities"
is a separate AWS service with its own bill.

---

## 2. The Golden Rule of EKS Billing

**EKS itself is only ONE small fee. Most of your money goes to the things EKS *creates for you*.**

When you install Kafka (through Strimzi) or NiFi, they ask Kubernetes for things:
"I need a disk!" "I need a front door for traffic!" Kubernetes turns around and asks AWS.
AWS says "Sure!" — and quietly starts the billing meter for each one. Even after you stop
using the cluster, many of these meters **keep running until you delete the resources**.

---

## 3. The Complete List of Billable Services

### 3.1 Amazon EKS — the cluster "brain" fee

* **What it is:** AWS runs the Kubernetes control plane (the brain that decides where every
  app runs) so you don't have to.
* **How it relates to Kafka & NiFi:** Neither can exist without the brain. Strimzi talks to
  the brain constantly ("make 3 Kafka brokers!"), and NiFi's pods are scheduled by it.
* **What you pay:** **$0.10 per hour ≈ $73 per month per cluster** — even if the cluster is
  sitting idle doing absolutely nothing.
* **Two traps to know:**
  * If your Kubernetes version gets old (past standard support, about 14 months), the fee
    jumps to **$0.60/hour ≈ $438/month** ("extended support"). Keep your cluster upgraded!
  * If you turn on **EKS Auto Mode** (AWS manages nodes for you), you pay a small extra
    management fee on top of each EC2 computer — roughly 10–12% more per node.

### 3.2 Amazon EC2 — the worker computers (usually your BIGGEST bill)

* **What it is:** Real virtual computers ("worker nodes") where your apps actually run.
* **How it relates to Kafka & NiFi:** Every Kafka broker, every Kafka controller
  (ZooKeeper or KRaft), the Strimzi operator itself, every NiFi node, and NiFi's ZooKeeper
  are all just programs running on these EC2 computers. Kafka and NiFi are hungry — they
  like lots of memory and CPU.
* **What you pay:** Per computer, per hour, based on size. Examples:
  * `t3.medium` (small, testing only) ≈ $30/month
  * `m5.large` ≈ $70/month
  * `m5.xlarge` (common for Kafka/NiFi) ≈ **$140/month each**
* **Reality check:** A typical small Kafka + NiFi setup needs at least 3 good-sized nodes,
  so plan on **$400+/month just for compute**.

### 3.3 Amazon EBS — the hard drives (disks)

* **What it is:** Network hard drives that attach to your EC2 computers.
* **How it relates to Kafka:** Every Kafka broker gets its own **PersistentVolume** —
  a real EBS disk — where all your messages are stored. Kafka controllers/ZooKeeper get
  smaller disks too. Strimzi creates these automatically through the EBS CSI driver.
* **How it relates to NiFi:** NiFi keeps **three separate storage areas**, each usually on
  its own EBS disk:
  1. **FlowFile Repository** — NiFi's short-term memory (what data is moving right now)
  2. **Content Repository** — the package room (the actual data being moved)
  3. **Provenance Repository** — NiFi's diary (a record of everything that ever happened
     to every piece of data)
* **What you pay:** gp3 disks ≈ **$0.08 per GB per month** (gp2 ≈ $0.10). A modest setup
  with 1,000–1,500 GB of total disk lands around **$80–$120/month**.
* **BIG TRAP:** Disks bill **even when the pods using them are turned off**, and they can
  survive after you delete the cluster ("orphaned volumes") and bill forever. The delete
  script in this package hunts them down.

### 3.4 EBS Snapshots — photos of your disks

* **What it is:** Backup copies of EBS disks, stored safely.
* **How it relates to Kafka & NiFi:** If you back up broker volumes or NiFi repositories
  (a smart idea before upgrades), each backup is a snapshot.
* **What you pay:** ≈ **$0.05 per GB per month**, forever, until you delete the snapshots.

### 3.5 Elastic Load Balancing (ELB / ALB / NLB) — the front doors

* **What it is:** A managed "front door" that spreads incoming traffic across your pods.
* **How it relates to Kafka (this one surprises everyone):** If Strimzi's external
  listener is set to `type: loadbalancer`, Strimzi creates **one load balancer PER BROKER,
  plus one extra "bootstrap" load balancer**. A 3-broker Kafka cluster = **4 load
  balancers**. A 9-broker cluster = 10!
* **How it relates to NiFi:** The NiFi web page (its UI) needs a front door too — usually
  one Application Load Balancer (through an Ingress) or one LoadBalancer service.
* **What you pay:** Each NLB or ALB ≈ **$16–$25/month base**, PLUS usage charges (LCUs)
  based on traffic. Four Kafka doors + one NiFi door ≈ **$85–$130/month**.

### 3.6 Data Transfer — the moving fee (the sneakiest cost of all)

* **What it is:** AWS charges money when data *moves* between certain places.
* **How it relates to Kafka:** For safety, Kafka **copies every message** to brokers in
  other Availability Zones (different buildings). Crossing between zones costs
  **$0.01 per GB in each direction** ($0.02 round trip). If your apps push 1 TB/day
  through Kafka with 3x replication, this alone can be **hundreds of dollars a month**
  and it never shows up as a "Kafka" line item on the bill!
* **How it relates to NiFi:** NiFi nodes shuffle data between each other (load balancing
  connections), pull data from outside sources, and push data to destinations. Data going
  **out to the internet costs ≈ $0.09 per GB**.
* **Money tip:** Keep producers, brokers, and consumers "zone-aware" (Kafka's
  fetch-from-closest-replica feature) to cut this cost.

### 3.7 NAT Gateway — the one-way door to the internet

* **What it is:** Lets computers in *private* subnets reach the internet (but the internet
  can't reach them).
* **How it relates to Kafka & NiFi:** Your nodes use it to download container images
  (Strimzi images, NiFi images from Docker Hub), and NiFi processors use it to call
  outside APIs and websites.
* **What you pay:** ≈ **$0.045/hour ≈ $33/month per NAT gateway**, PLUS **$0.045 per GB**
  of data that flows through it. Pulling big images repeatedly gets pricey.
* **Money tip:** Add VPC endpoints for ECR and S3 so image pulls skip the NAT gateway.

### 3.8 Public IPv4 Addresses — street addresses cost money now

* **What it is:** Since 2024, AWS charges for every public IPv4 address you use.
* **How it relates to Kafka & NiFi:** Public worker nodes, the NAT gateway's address, and
  every internet-facing load balancer (remember, Kafka may have 4+!) each hold addresses.
* **What you pay:** **$0.005/hour ≈ $3.65/month per address.** Ten addresses = $36/month.

### 3.9 Amazon ECR — the garage for container images

* **What it is:** A private storage place for your container images.
* **How it relates to Kafka & NiFi:** Custom images live here — for example, a NiFi image
  with your extra processors baked in, or a Kafka Connect image with connector plugins.
* **What you pay:** **$0.10 per GB per month** of stored images, plus data transfer.
  Usually small ($1–$10/month), but old unused images pile up.

### 3.10 Amazon CloudWatch — the security cameras and notebooks

* **What it is:** AWS's logging and monitoring service.
* **How it relates to EKS:** The control plane can send its logs here (the "audit" log is
  especially chatty). Container Insights collects metrics about your pods.
* **How it relates to Kafka & NiFi:** Both are **very talkative loggers**. Kafka brokers
  log constantly; NiFi's app logs and bulletin messages add up fast when shipped to
  CloudWatch by Fluent Bit.
* **What you pay:** ≈ **$0.50 per GB ingested**, ≈ $0.03/GB/month stored, and $0.30 per
  custom metric. A chatty cluster easily spends **$20–$100/month** here.
* **Money tip:** Set log retention (7–30 days) — the default is "keep forever."

### 3.11 Amazon S3 — the giant storage locker

* **What it is:** Cheap, unlimited object storage.
* **How it relates to NiFi:** NiFi flows very often read from and write to S3
  (`PutS3Object`, `FetchS3Object` processors) — that's frequently NiFi's whole job!
* **How it relates to Kafka:** Kafka Connect S3 sink connectors archive topics to S3;
  backups and exported data land here too.
* **What you pay:** ≈ **$0.023 per GB per month** plus tiny per-request fees. Cheap per
  GB, but terabytes of NiFi output add up.

### 3.12 Amazon Route 53 — the phone book (DNS)

* **What it is:** Turns friendly names into IP addresses.
* **How it relates to Kafka & NiFi:** If you use `external-dns`, it creates names like
  `kafka.mycompany.com` and `nifi.mycompany.com` pointing at your load balancers.
* **What you pay:** **$0.50/month per hosted zone** plus about $0.40 per million lookups.
  Small, but real.

### 3.13 AWS KMS — the lockbox for secret keys

* **What it is:** Manages encryption keys.
* **How it relates to Kafka & NiFi:** Kubernetes Secrets (Kafka user passwords, TLS
  certificates Strimzi generates, NiFi keystore passwords) can be envelope-encrypted with
  a KMS key. Encrypted EBS disks also use KMS.
* **What you pay:** **$1/month per key** plus $0.03 per 10,000 uses. Tiny, but on the bill.

### 3.14 AWS Secrets Manager — the fancy safe (optional)

* **What it is:** A managed safe for passwords with rotation features.
* **How it relates to Kafka & NiFi:** Teams often sync Kafka credentials or NiFi
  sensitive properties from Secrets Manager into the cluster (External Secrets Operator
  or the Secrets Store CSI driver).
* **What you pay:** **$0.40 per secret per month** plus $0.05 per 10,000 API calls.

### 3.15 AWS Fargate — rent-a-pod without owning computers (optional)

* **What it is:** Serverless compute: you pay per pod (per vCPU-hour and GB-hour) instead
  of renting whole EC2 computers.
* **How it relates to Kafka & NiFi:** **Usually a bad fit for Kafka brokers and NiFi
  nodes** because Fargate pods can't use EBS persistent disks (only EFS). It can be fine
  for small helper pods.
* **What you pay:** ≈ $0.04048 per vCPU-hour + $0.004445 per GB-hour.

### 3.16 Amazon EFS — the shared network folder (optional)

* **What it is:** A file system many pods can share at once.
* **How it relates to NiFi:** Sometimes used for shared NiFi configuration or when
  someone tries to run stateful pods on Fargate.
* **What you pay:** ≈ **$0.30 per GB per month** — almost 4x the price of gp3 EBS, so use
  it only when you truly need shared access.

### 3.17 Optional Extras That Sneak Onto Bills

* **GuardDuty EKS Protection** — a security guard that reads your cluster's audit logs;
  billed by audit-log volume.
* **AWS Backup** — scheduled EBS backups; you pay snapshot storage rates.
* **VPC Interface Endpoints (PrivateLink)** — ≈ $0.01/hour each per AZ plus per-GB; they
  cost a little but often *save* more by avoiding NAT charges.
* **EKS add-ons and Provisioned Control Plane tiers** — the basic add-ons are free
  (their compute isn't), but optional paid tiers/capabilities exist for heavy users.

---

## 4. A Sample Monthly Bill (Small Production-ish Setup)

Three `m5.xlarge` nodes, a 3-broker Kafka with external listeners, a 3-node NiFi:

| # | Service | What's running | Est. monthly cost |
|---|---|---|---|
| 1 | EKS control plane | 1 cluster (standard support) | $73 |
| 2 | EC2 worker nodes | 3 × m5.xlarge | $421 |
| 3 | EBS disks (gp3) | ~1,200 GB (Kafka + NiFi repos + roots) | $96 |
| 4 | Load balancers | 4 NLB (Kafka) + 1 ALB (NiFi UI) | $85+ |
| 5 | NAT gateway | 1 gateway + image pulls | $35+ |
| 6 | Cross-AZ data transfer | ~1 TB of Kafka replication | $20+ |
| 7 | CloudWatch | control plane + app logs, metrics | $30 |
| 8 | Public IPv4 addresses | ~6 addresses | $22 |
| 9 | ECR + S3 + Route 53 + KMS | images, backups, DNS, keys | $15 |
|   | **TOTAL (rough)** | | **≈ $800/month** |

Notice: the "EKS" line is only **9%** of the bill. The other 91% is everything EKS
created for Kafka and NiFi.

---

## 5. The Three Biggest "Surprise" Costs with Kafka + NiFi

1. **Cross-AZ replication traffic.** Kafka's safety copies between zones cost $0.02/GB
   round trip and never say "Kafka" on the bill — they hide under "EC2 Data Transfer."
2. **One load balancer per Kafka broker.** External `loadbalancer` listeners multiply
   your front doors. Consider internal listeners, NodePort, or a single ingress-based
   route when possible.
3. **Zombies that outlive the cluster.** Orphaned EBS volumes, forgotten snapshots,
   leftover load balancers, idle Elastic IPs, and CloudWatch log groups all keep billing
   after the cluster is gone — which is exactly why the delete scripts in this package
   sweep for them.

---

## 6. Ten Ways to Lower the Bill

1. **Delete dev/test clusters when not in use** — the $73/month brain fee bills 24/7.
2. **Keep Kubernetes upgraded** — avoid the 6x extended-support fee ($438/month).
3. **Use gp3 instead of gp2 disks** — 20% cheaper and faster.
4. **Use Spot instances** for non-critical nodes — 60–90% cheaper compute.
5. **Buy Savings Plans / Reserved Instances** for steady Kafka/NiFi nodes — up to 72% off.
6. **Avoid one-LB-per-broker** external listeners unless you truly need them.
7. **Enable Kafka's closest-replica fetching** and keep clients zone-aware.
8. **Add VPC endpoints for ECR/S3** to shrink NAT gateway data fees.
9. **Set CloudWatch log retention** and drop debug-level logging in production.
10. **Run the cost report script regularly** and delete orphaned disks, snapshots, LBs,
    and Elastic IPs.

---

## 7. Disclaimer & References

Prices above are approximate on-demand list prices for US East (N. Virginia) and **will
differ** in your region and over time. Data transfer, load-balancer usage units (LCUs),
requests, and support plans are extra. For real numbers, use:

* AWS EKS pricing — <https://aws.amazon.com/eks/pricing/>
* EC2 pricing — <https://aws.amazon.com/ec2/pricing/on-demand/>
* EBS pricing — <https://aws.amazon.com/ebs/pricing/>
* ELB pricing — <https://aws.amazon.com/elasticloadbalancing/pricing/>
* VPC (NAT, IPv4) pricing — <https://aws.amazon.com/vpc/pricing/>
* CloudWatch pricing — <https://aws.amazon.com/cloudwatch/pricing/>
* AWS Pricing Calculator — <https://calculator.aws/>
* Your real bill — AWS **Cost Explorer** (the included report script can query it).
