# main.tf
# ---------------------------------------------------------------------------
# CIDR PLAN (VPC 10.0.0.0/16 = 65,536 addresses)
# Each subnet loses 5 usable IPs to AWS (.0 network, .1 router, .2 DNS,
# .3 future, and the last broadcast address).
#
# We carve the /16 into named "tiers" by the SECOND octet group so the plan is
# readable at a glance and leaves big gaps for future expansion.
#
#   PUBLIC          10.0.0.0/20   -> /24 per AZ  (256 IPs each, ~251 usable)
#   PRIVATE-SMALL   10.0.16.0/20  -> /26 per AZ  (64 IPs,  ~59 usable)  small svcs
#   PRIVATE-MEDIUM  10.0.32.0/20  -> /24 per AZ  (256 IPs, ~251 usable) general
#   PRIVATE-LARGE   10.0.48.0/20  -> /22 per AZ  (1024 IPs,~1019 usable) big data
#   RESERVED        10.0.64.0/18  -> untouched, room to grow / future tiers
#
# WHY THREE PRIVATE SIZES?
#   small  -> low-IP-count workloads: SNS/SQS access points, small APIs,
#             bastion-free admin endpoints, lightweight microservices.
#   medium -> the default home for most app servers: Java/Node web apps,
#             backend APIs, NiFi nodes.
#   large  -> IP-hungry clustered systems: Kafka (MSK) brokers, RDS/Postgres
#             fleets, OpenSearch data nodes, search clusters that scale out.
# ---------------------------------------------------------------------------

# Look up which AZs actually exist in the chosen region (don't hard-code).
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # cidrsubnet(base, newbits, netnum) splits a block deterministically.
  # Public: 4 newbits on a /20 base -> /24 subnets.
  public_subnets = {
    for i, az in local.azs : az => cidrsubnet("10.0.0.0/20", 4, i)
  }

  # Small: 6 newbits on /20 -> /26 subnets (64 IPs).
  private_small_subnets = {
    for i, az in local.azs : az => cidrsubnet("10.0.16.0/20", 6, i)
  }

  # Medium: 4 newbits on /20 -> /24 subnets (256 IPs).
  private_medium_subnets = {
    for i, az in local.azs : az => cidrsubnet("10.0.32.0/20", 4, i)
  }

  # Large: 2 newbits on /20 -> /22 subnets (1024 IPs).
  private_large_subnets = {
    for i, az in local.azs : az => cidrsubnet("10.0.48.0/20", 2, i)
  }

  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # lets resources resolve names via the .2 resolver
  enable_dns_hostnames = true # gives instances public DNS names when applicable

  tags = { Name = "${local.name_prefix}-vpc" }
}

# ---------------------------------------------------------------------------
# Internet Gateway — the door to the public internet for public subnets.
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

# ---------------------------------------------------------------------------
# PUBLIC SUBNETS (one per AZ) — hold load balancers and NAT Gateways only.
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true # public tier: auto-assign public IPs

  tags = {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

# ---------------------------------------------------------------------------
# PRIVATE SUBNETS — three sized groups, all internet-isolated (no public IP).
# ---------------------------------------------------------------------------
resource "aws_subnet" "private_small" {
  for_each          = local.private_small_subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key
  tags = {
    Name = "${local.name_prefix}-private-small-${each.key}"
    Tier = "private-small"
  }
}

resource "aws_subnet" "private_medium" {
  for_each          = local.private_medium_subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key
  tags = {
    Name = "${local.name_prefix}-private-medium-${each.key}"
    Tier = "private-medium"
  }
}

resource "aws_subnet" "private_large" {
  for_each          = local.private_large_subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key
  tags = {
    Name = "${local.name_prefix}-private-large-${each.key}"
    Tier = "private-large"
  }
}

# ---------------------------------------------------------------------------
# NAT GATEWAYS — let private subnets make OUTBOUND connections (patch
# downloads, calling external APIs) without being reachable from the internet.
# Each NAT needs a public Elastic IP and lives in a PUBLIC subnet.
# ---------------------------------------------------------------------------
locals {
  nat_azs = var.single_nat_gateway ? slice(local.azs, 0, 1) : local.azs
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
  tags     = { Name = "${local.name_prefix}-nat-eip-${each.key}" }
}

resource "aws_nat_gateway" "this" {
  for_each      = toset(local.nat_azs)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "${local.name_prefix}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# ROUTE TABLES
# A subnet is "public" only because its route table sends 0.0.0.0/0 to the IGW.
# Private subnets send 0.0.0.0/0 to a NAT Gateway instead.
# ---------------------------------------------------------------------------

# Public route table (shared by all public subnets).
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private route tables — one per AZ so each AZ uses its own local NAT.
# This is what gives you AZ-level failover: AZ-a traffic never depends on AZ-b.
resource "aws_route_table" "private" {
  for_each = toset(local.azs)
  vpc_id   = aws_vpc.this.id
  tags     = { Name = "${local.name_prefix}-rt-private-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each               = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  # If single_nat_gateway, every AZ points at the one NAT; otherwise its own.
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[local.nat_azs[0]].id : aws_nat_gateway.this[each.key].id
}

# Associate all three private tiers in each AZ with that AZ's private table.
resource "aws_route_table_association" "private_small" {
  for_each       = aws_subnet.private_small
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private_medium" {
  for_each       = aws_subnet.private_medium
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private_large" {
  for_each       = aws_subnet.private_large
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
