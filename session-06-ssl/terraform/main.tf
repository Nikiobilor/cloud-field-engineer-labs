# Terraform configuration for TICKET-001: Ubuntu server performance lab

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWS Provider configuration
# We read the region from a variable so this is reusable
provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────
# DATA SOURCES
# Data sources let Terraform query AWS for info
# without us hardcoding IDs
# ─────────────────────────────────────────────

# Get the latest Ubuntu 22.04 AMI ID dynamically
# This means our code always uses the latest patched image
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Get our current public IP address
# This is used to restrict SSH access to only our machine
data "http" "my_ip" {
  url = "https://ipv4.icanhazip.com"
}

# ─────────────────────────────────────────────
# VPC AND NETWORKING
# ─────────────────────────────────────────────

# Create a dedicated VPC for this lab
# Think of a VPC as a private data centre network in AWS
resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "canonical-lab-vpc"
    Project = "canonical-cfe-labs"
    Session = "01"
  }
}

# Internet Gateway — allows traffic to flow between the VPC and the internet
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab_vpc.id

  tags = {
    Name = "canonical-lab-igw"
  }
}

# Public subnet — instances here can get public IPs
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true # Automatically assign public IPs

  tags = {
    Name = "canonical-lab-public-subnet"
  }
}

# Route table — defines where traffic goes
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab_vpc.id

  # Default route: send all internet-bound traffic to the IGW
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "canonical-lab-public-rt"
  }
}

# Associate the route table with our public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─────────────────────────────────────────────
# SECURITY GROUP
# Think of this as a firewall for the EC2 instance
# ─────────────────────────────────────────────

resource "aws_security_group" "lab_sg" {
  name        = "canonical-lab-sg"
  description = "Security group for Canonical lab - TICKET-001"
  vpc_id      = aws_vpc.lab_vpc.id

  # Allow SSH only from our IP address
  # trimspace removes the newline from the http data source response
  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${trimspace(data.http.my_ip.response_body)}/32"]
  }
  
   ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

   ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # Allow node_exporter metrics port from our IP
  ingress {
    description = "Prometheus node_exporter metrics"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = ["${trimspace(data.http.my_ip.response_body)}/32"]
  }

  # Allow all outbound traffic (needed to download packages)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "canonical-lab-sg"
  }
}

# ─────────────────────────────────────────────
# SSH KEY PAIR
# Upload our public key to AWS so we can SSH in
# ─────────────────────────────────────────────

resource "aws_key_pair" "lab_key" {
  key_name   = "canonical-lab-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# ─────────────────────────────────────────────
# EC2 INSTANCE
# The actual server we are working on
# ─────────────────────────────────────────────

resource "aws_instance" "lab_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.lab_sg.id]
  key_name               = aws_key_pair.lab_key.key_name

  # Root EBS volume — 8GB is enough for this lab and stays in free tier
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true

    tags = {
      Name = "canonical-lab-root-vol"
    }
  }

  # User data runs when the instance first boots
  # We use it to do initial setup automatically
  user_data = <<-USERDATA
    #!/bin/bash
    set -e

    # Update the system
    apt-get update -y
    apt-get upgrade -y

    # Install useful tools we'll use in the lab
    apt-get install -y \
      htop \
      iotop \
      sysstat \
      net-tools \
      curl \
      wget \
      vim \
      jq \
      tree

    # Create a marker file so we know user_data ran
    echo "user_data completed at $(date)" > /tmp/bootstrap_complete.txt
  USERDATA

  tags = {
    Name    = "canonical-lab-server-ticket-001"
    Project = "canonical-cfe-labs"
    Session = "01"
    Ticket  = "CFE-001"
  }
}
