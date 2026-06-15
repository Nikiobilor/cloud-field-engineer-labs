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

# ─── INTERNET GATEWAY ────────────────────────────────────────────────────────
# The IGW is the VPC's connection to the internet.
# It performs one-to-one NAT for instances that have a public IP address.
# Without this resource, no traffic can leave or enter the VPC from the internet —
# even if you add 0.0.0.0/0 to a route table, the route has nowhere to point.

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-igw"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC SUBNET ───────────────────────────────────────────────────────────
# This subnet is "public" because we will associate it with a route table
# that has a default route pointing to the IGW.
# map_public_ip_on_launch means instances in this subnet automatically receive
# a public IP — required for the web tier to be reachable from the internet.

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

# ─── PRIVATE SUBNET ──────────────────────────────────────────────────────────
# This subnet is "private" because we will associate it with a route table
# that has NO default route to the internet.
# map_public_ip_on_launch is explicitly false — instances here should never
# receive a public IP. Outbound internet access (if needed) must go via NAT GW.

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
# The VPC router always exists — you cannot remove it. You configure it by
# defining route tables and associating them with subnets.
#
# This route table has two routes:
#   - 10.0.0.0/16 local (automatically added by AWS for all VPC-internal traffic)
#   - 0.0.0.0/0 → IGW  (added explicitly below — this is what makes the subnet public)

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    # all traffic not matched by a more specific prefix goes to the IGW
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-public-rt"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC ROUTE TABLE ASSOCIATION ──────────────────────────────────────────
# A route table must be explicitly associated with a subnet.
# Without this association, the subnet uses the VPC's default route table,
# which has no default route — effectively making it private by accident.
# This was one of the root causes of the RetailEdge ticket: the public subnet
# was never explicitly associated with the IGW route table.

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── PRIVATE ROUTE TABLE ─────────────────────────────────────────────────────
# The private route table intentionally has no default route.
# This ensures no traffic from a private subnet instance can reach the internet
# directly. The only route is the implicit local route (VPC CIDR → local),
# which allows intra-VPC traffic between the web tier and the app tier.
#
# When NAT Gateway is enabled (see Step 9), a 0.0.0.0/0 → NAT GW route is added.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-private-rt"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PRIVATE ROUTE TABLE ASSOCIATION ─────────────────────────────────────────

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ─── WEB TIER SECURITY GROUP ─────────────────────────────────────────────────

resource "aws_security_group" "web" {
  name        = "${var.environment}-web-sg"
  description = "Web tier: allows HTTPS from internet, SSH from ops"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from internet — redirected to HTTPS by nginx"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH — scoped to ops IP in calling module"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip_cidr]
  }

  ingress {
    description = "node_exporter — scoped to ops IP"
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
    ManagedBy   = "Terraform"
  }
}

# ─── APP TIER SECURITY GROUP ──────────────────────────────────────────────────
# The source for port 8080 is the web-sg ID — not a CIDR.
# This means exactly: allow port 8080 from any instance that is a member of
# web-sg. No other resource in the VPC can reach this port, regardless of subnet.

resource "aws_security_group" "app" {
  name        = "${var.environment}-app-sg"
  description = "App tier: allows port 8080 from web-sg only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "backend port — web-sg members only"
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
    ManagedBy   = "Terraform"
  }
}
