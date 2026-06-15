# ─── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # required for EC2 instances to resolve AWS service endpoints by hostname
  enable_dns_support = true

  # required for instances to receive a DNS hostname from AWS
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── INTERNET GATEWAY ─────────────────────────────────────────────────────────
# The IGW is the VPC's connection to the internet.
# It performs one-to-one NAT for instances that have a public IP address.
# Without this resource no traffic can leave or enter the VPC from the internet
# even if a route table has a 0.0.0.0/0 entry — the route has nowhere to point.

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-igw"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC SUBNET ────────────────────────────────────────────────────────────
# This subnet is public because we associate it with a route table that has
# a default route pointing to the IGW.
# map_public_ip_on_launch gives instances a public IP automatically — required
# for the web tier to be reachable from the internet.

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-public-subnet"
    Environment = var.environment
    Tier        = "public"
    ManagedBy   = "Terraform"
  }
}

# ─── PRIVATE SUBNET ───────────────────────────────────────────────────────────
# This subnet is private because its route table has no default route.
# map_public_ip_on_launch is false — instances here must never receive a
# public IP. Outbound internet access requires a NAT Gateway (see below).

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.environment}-private-subnet"
    Environment = var.environment
    Tier        = "private"
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC ROUTE TABLE ───────────────────────────────────────────────────────
# A route table is a set of rules that tells the VPC router where to send packets.
# This table has two routes:
#   - 10.0.0.0/16 local  (added automatically by AWS for all VPC-internal traffic)
#   - 0.0.0.0/0 → IGW   (added explicitly below — this is what makes the subnet public)

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    # all traffic not matched by a more specific prefix goes to the internet gateway
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-public-rt"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC ROUTE TABLE ASSOCIATION ───────────────────────────────────────────
# A route table must be explicitly associated with a subnet.
# Without this the subnet uses the VPC default route table which has no
# default route — effectively making it private by accident.
# This was one of the root causes in TICKET-008.

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── PRIVATE ROUTE TABLE ──────────────────────────────────────────────────────
# Intentionally has no default route.
# No packet from the internet can ever be delivered to a private subnet instance
# because the routing infrastructure discards it before any SG evaluation runs.
# This is defence in depth: two independent layers must both be misconfigured
# before the private subnet becomes reachable.
#
# When the NAT Gateway is enabled (see the commented block below), a
# 0.0.0.0/0 → NAT GW route is added to this table.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-private-rt"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PRIVATE ROUTE TABLE ASSOCIATION ──────────────────────────────────────────

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ─── NAT GATEWAY (COST-GATED: uncomment when ~$1/day is acceptable) ───────────
#
# A NAT Gateway must sit in the PUBLIC subnet — it needs the IGW route to
# forward outbound traffic from private instances to the internet.
# It is a managed AWS service: highly available, auto-scaling, no OS to patch.
# A NAT instance (EC2 with IP forwarding + iptables MASQUERADE) is cheaper
# but introduces single-point-of-failure and operational overhead.
#
# Estimated cost in us-east-1: ~$0.048/hr + $0.048/GB processed (~$34/month idle)

# resource "aws_eip" "nat" {
#   domain = "vpc"
#
#   tags = {
#     Name        = "${var.environment}-nat-eip"
#     Environment = var.environment
#     ManagedBy   = "Terraform"
#   }
# }

# resource "aws_nat_gateway" "main" {
#   allocation_id = aws_eip.nat.id
#
#   # must be in the public subnet — requires an IGW route to reach the internet
#   subnet_id = aws_subnet.public.id
#
#   tags = {
#     Name        = "${var.environment}-nat-gw"
#     Environment = var.environment
#     ManagedBy   = "Terraform"
#   }
#
#   # the IGW must exist before the NAT GW can be created
#   depends_on = [aws_internet_gateway.main]
# }

# ─── PRIVATE ROUTE TABLE DEFAULT ROUTE VIA NAT GW ─────────────────────────────
# Uncomment together with the NAT Gateway resources above.
# Adds 0.0.0.0/0 → NAT GW to the private route table.
# Without this the NAT GW exists but private instances have no route to it.

# resource "aws_route" "private_nat" {
#   route_table_id         = aws_route_table.private.id
#   destination_cidr_block = "0.0.0.0/0"
#   nat_gateway_id         = aws_nat_gateway.main.id
# }

# ─── WEB TIER SECURITY GROUP ──────────────────────────────────────────────────
# Allows HTTPS and HTTP from the internet (HTTP is redirected to HTTPS by nginx).
# SSH and node_exporter are scoped to the ops IP only.

resource "aws_security_group" "web" {
  name        = "${var.environment}-web-sg"
  description = "Web tier: HTTPS and HTTP from internet, SSH and node_exporter from ops IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from internet — nginx redirects to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH access scoped to ops workstation IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip_cidr]
  }

  ingress {
    description = "node_exporter metrics scoped to ops workstation IP"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip_cidr]
  }

  egress {
    description = "all outbound traffic allowed"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-web-sg"
    Environment = var.environment
    Tier        = "web"
    ManagedBy   = "Terraform"
  }
}

# ─── APP TIER SECURITY GROUP ──────────────────────────────────────────────────
# Port 8080 source is the web-sg ID — not a CIDR block.
# This means exactly: allow port 8080 from any instance that is a member of
# web-sg regardless of its IP address or subnet.
#
# Using a CIDR source (e.g. 10.0.1.0/24) would allow any host in that subnet
# to reach the backend — including bastion hosts, debug instances, or any
# future resource in that CIDR. A SG ID source is precise and scales with
# the fleet automatically without any rule updates.

resource "aws_security_group" "app" {
  name        = "${var.environment}-app-sg"
  description = "App tier: port 8080 from web-sg members only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "backend service port — web-sg members only, not a CIDR"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    description = "all outbound traffic allowed"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-app-sg"
    Environment = var.environment
    Tier        = "app"
    ManagedBy   = "Terraform"
  }
}

