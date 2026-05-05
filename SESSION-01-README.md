# TICKET-001: Ubuntu Server Performance Investigation & Kernel Tuning
 Cloud Field Engineer Lab Series | Session 1 of 32

---

## 🎫 The Ticket

```
TICKET ID:    CFE-001
PRIORITY:     High
ASSIGNED TO:  Cloud Field Engineer (You)
CLIENT:       RetailEdge Ltd — E-commerce platform, Lagos & London
ENVIRONMENT:  Ubuntu 22.04 LTS on AWS EC2

SUBJECT: Production web server showing high latency under load.
         Ops team cannot explain why. CTO wants a report within 48 hours.

DESCRIPTION:
Our Ubuntu 22.04 server starts lagging when traffic hits ~500 concurrent
users. CPU doesn't look maxed out but response times spike. We need
someone to investigate the OS-level configuration, identify bottlenecks,
apply safe tuning, and set up basic monitoring so we can see what's
happening in real time.

ACCEPTANCE CRITERIA:
- [ ] Server profiled with findings documented
- [ ] Kernel parameters tuned for a network-heavy workload
- [ ] System monitoring set up (visible metrics)
- [ ] Systemd service configured to keep monitoring agent running
- [ ] Handover README written for support team
```

---

## 🎯 Task Goal

By the end of this session you will have:
- Deployed an Ubuntu 22.04 EC2 instance using Terraform
- Profiled the OS using Linux tools (`htop`, `vmstat`, `ss`, `sysctl`)
- Applied kernel-level tuning for network performance
- Installed and configured a lightweight monitoring agent (`node_exporter`)
- Set up `node_exporter` as a systemd service
- Documented everything in a format you could hand off to a client


## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS (Free Tier)                       │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPC (10.0.0.0/16)                 │   │
│  │                                                     │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │           Public Subnet (10.0.1.0/24)        │   │   │
│  │  │                                              │   │   │
│  │  │   ┌────────────────────────────────────┐    │   │   │
│  │  │   │    EC2: Ubuntu 22.04 (t2.micro)    │    │   │   │
│  │  │   │                                    │    │   │   │
│  │  │   │  ┌──────────────────────────────┐  │    │   │   │
│  │  │   │  │  node_exporter (port 9100)   │  │    │   │   │
│  │  │   │  │  systemd service             │  │    │   │   │
│  │  │   │  └──────────────────────────────┘  │    │   │   │
│  │  │   │                                    │    │   │   │
│  │  │   │  Kernel Tuning Applied:            │    │   │   │
│  │  │   │  - net.core.somaxconn = 65535      │    │   │   │
│  │  │   │  - tcp_tw_reuse = 1                │    │   │   │
│  │  │   │  - vm.swappiness = 10              │    │   │   │
│  │  │   └────────────────────────────────────┘    │   │   │
│  │  │                                              │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  │                                                     │   │
│  │  Security Group:                                    │   │
│  │  - Port 22 (SSH) → Your IP only                    │   │
│  │  - Port 9100 (metrics) → Your IP only              │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

Your Laptop ──SSH──→ EC2 Instance
Your Browser ──HTTP:9100──→ node_exporter metrics
```

---

## 📋 Prerequisites

Before starting, make sure you have:

1. **AWS Account** (free tier) — [https://aws.amazon.com/free](https://aws.amazon.com/free)
2. **AWS CLI installed and configured** — we'll check this in Step 1
3. **Terraform installed** — we'll install this in Step 1
4. **Git installed** — to push your work to GitHub
5. **A GitHub account** — to host your project


## 🚀 Step-by-Step Lab Guide

### STEP 1: Set Up Your Local Toolchain

**What we are doing:** Before touching any cloud infrastructure, we verify our local tools work. This is professional practice — never assume your tools are working.

#### 1a. Install AWS CLI (if not installed)

```bash
# Check if AWS CLI is already installed
aws --version
# Expected output: aws-cli/2.x.x Python/3.x ...

# If not installed, on Ubuntu/Debian:
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# On macOS:
brew install awscli

# On Windows: download installer from AWS docs
```

#### 1b. Configure AWS CLI with your credentials

```bash
aws configure
```

You will be prompted for:
```
AWS Access Key ID [None]: <paste your access key>
AWS Secret Access Key [None]: <paste your secret key>
Default region name [None]: us-east-1
Default output format [None]: json
```

> 💡 **Where to get your AWS keys:**
> 1. Log into AWS Console
> 2. Click your name (top right) → Security credentials
> 3. Scroll to "Access keys" → Create access key
> 4. **Important:** Never commit these to GitHub. We will use environment variables.

**Verify it works:**
```bash
aws sts get-caller-identity
# Should return your Account ID, UserID, and ARN
```

#### 1c. Install Terraform

```bash
# Check if already installed
terraform --version

# If not installed, on Ubuntu/Debian:
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# On macOS:
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Verify
terraform --version
# Expected: Terraform v1.x.x
```

#### 1d. Create an SSH key pair for EC2

```bash
# Generate an SSH key pair (press Enter for defaults when prompted)
ssh-keygen -t ed25519 -C "canonical-lab-key" -f ~/.ssh/canonical_lab_key

# View your public key (you will need this for Terraform)
cat ~/.ssh/canonical_lab_key.pub
```

---

### STEP 2: Create Your Project Structure on GitHub

**What we are doing:** This is also how you will build your public portfolio.

#### 2a. Create a new GitHub repository

1. Go to [https://github.com/new](https://github.com/new)
2. Name it: `cloud-field-engineer-labs`
3. Set to Public 
4. Initialize with a README
5. Click "Create repository"

#### 2b. Clone and set up locally

```bash
git clone https://github.com/Nikiobilor/cloud-field-engineer-labs.git
cd cloud-field-engineer-labs

# Create the folder structure for this session
mkdir -p session-01-linux-tuning/terraform
mkdir -p session-01-linux-tuning/ansible
mkdir -p session-01-linux-tuning/docs

cd session-01-linux-tuning
```

> 💡 **Why this structure matters:**  The client's support team needs to find things easily. A clean folder structure = professional credibility.

---

### STEP 3: Write Your Terraform Configuration

**What we are doing:** We will use Terraform to define and deploy our EC2 instance. This is Infrastructure as Code — the server configuration lives in files, not in someone's memory.

#### 3a. Create the Terraform files

```bash
cd terraform/
```

**Create `main.tf`:** using vi or nano
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

**Create `variables.tf`:**
# All configurable inputs for our Terraform module

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t2.micro is free tier eligible"
  type        = string
  default     = "t2.micro"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key file"
  type        = string
  default     = "~/.ssh/canonical_lab_key.pub"
}

**Create `outputs.tf`:**
# Values that Terraform will print after deployment
# These are useful for scripts and automation

output "instance_public_ip" {
  description = "Public IP address of the lab server"
  value       = aws_instance.lab_server.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.lab_server.id
}

output "ssh_command" {
  description = "Command to SSH into the server"
  value       = "ssh -i ~/.ssh/canonical_lab_key ubuntu@${aws_instance.lab_server.public_ip}"
}

output "node_exporter_url" {
  description = "URL to view node_exporter metrics"
  value       = "http://${aws_instance.lab_server.public_ip}:9100/metrics"
}

#### 3b. Deploy the infrastructure
# First create the private and public key with this command(this is because this key referenced in your terraform config file)
ssh-keygen -t ed25519 -C "canonical-lab-key" -f ~/.ssh/canonical_lab_key
```bash
# Initialize Terraform — downloads the AWS provider plugin
terraform init

# Preview what Terraform will create — ALWAYS review before applying
terraform plan

# Deploy the infrastructure
# Type 'yes' when prompted
terraform apply
```

> 💡 **Understanding `terraform plan`:** This is one of the most valuable habits in infrastructure engineering. Never apply blindly. The plan shows exactly what will be created, changed, or destroyed. 
**Expected output after apply:**
```
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:
instance_public_ip = "X.X.X.X"
ssh_command = "ssh -i ~/.ssh/canonical_lab_key ubuntu@X.X.X.X"
node_exporter_url = "http://X.X.X.X:9100/metrics"

---

### STEP 4: Connect and Profile the Server

**What we are doing:** We SSH into the server and start investigating, just like a field engineer arriving at a client site for the first time.

#### 4a. SSH into the server

```bash
# Wait 60-90 seconds for the instance to fully boot first
sleep 90

# Connect to the server
ssh -i ~/.ssh/canonical_lab_key ubuntu@$SERVER_IP
```

> 💡 If you get "Connection refused", the server is still booting. Wait another 30 seconds and try again.

#### 4b. Verify bootstrap completed

```bash
# Check that our user_data script ran
cat /tmp/bootstrap_complete.txt

# Check system uptime and load
uptime
# Output: 14:23:01 up 2 min, 1 user, load average: 0.15, 0.12, 0.05
# The three numbers are CPU load averages: last 1min, 5min, 15min
# On a t2.micro (1 vCPU), anything > 1.0 means overloaded
```

#### 4c. Profile CPU and Memory

```bash
# Interactive process viewer — press q to quit
htop
# What to look for:
# - CPU% per core
# - Memory usage
# - Swap usage (should be low for a healthy server)
# - Top processes by CPU

# Static snapshot of system stats
vmstat 1 5
# This takes 5 readings, 1 second apart
# Columns explained:
# r  = processes waiting for CPU (runqueue)
# b  = processes in uninterruptible sleep (waiting for I/O)
# swpd = swap used (MB)
# free = free memory (KB)
# si/so = swap in/out per second (non-zero = memory pressure)
# us/sy/id/wa = % time: user, system, idle, waiting for I/O

# Detailed memory breakdown
free -h
# -h = human-readable (shows MB, GB)
# 'available' is more important than 'free' — it includes reclaimable cache
```

#### 4d. Profile Network and Disk I/O

```bash
# Show all listening ports and established connections
ss -tulpn
# -t = TCP, -u = UDP, -l = listening, -p = show process, -n = no DNS lookup

# Current disk I/O activity
iostat -x 1 3
# -x = extended stats
# await = average time (ms) for I/O requests to complete
# %util = how busy the disk is (>80% is a problem)

# Real-time I/O by process (requires sudo)
sudo iotop -o
# -o = only show processes actually doing I/O
# Press q to quit
```

#### 4e. Explore the /proc filesystem

**This is critical knowledge for a field engineer.** `/proc` is a virtual filesystem that exposes kernel internals.

```bash
# Current kernel parameters (networking ones)
cat /proc/sys/net/core/somaxconn
# This controls how many TCP connections can queue up
# Default is 4096 — too low for busy servers

cat /proc/sys/net/ipv4/tcp_max_syn_backlog
# SYN backlog size — related to the TCP handshake queue

cat /proc/sys/vm/swappiness
# How aggressively Linux uses swap
# Default 60 means it will swap fairly early
# For web servers, 10 is better — keep data in RAM

# Current network socket stats
cat /proc/net/sockstat
# Shows how many TCP, UDP, RAW sockets exist

# System memory details
cat /proc/meminfo | head -20
```

> 💡 **What you just learned:** The `/proc` filesystem is how Linux exposes kernel state to userspace. Everything the kernel knows about itself lives here. When a client says "something is wrong with networking" — `/proc/net/` is where you look first.

---

### STEP 5: Apply Kernel Tuning

**What we are doing:** Based on our investigation, we apply kernel parameter changes to improve performance for a network-heavy web server workload.

#### 5a. Understand what we are changing and why

```bash
# View current sysctl settings (all of them)
sudo sysctl -a | grep -E "net.core|net.ipv4.tcp|vm.swappiness"
```

**The parameters we will tune and why:**

| Parameter | Default | Tuned | Why |
|---|---|---|---|
| `net.core.somaxconn` | 128 or 4096 | 65535 | Max connections in listen queue |
| `net.core.netdev_max_backlog` | 1000 | 5000 | Incoming packets buffer |
| `net.ipv4.tcp_max_syn_backlog` | 512 | 8096 | SYN queue depth |
| `net.ipv4.tcp_tw_reuse` | 0 | 1 | Reuse TIME_WAIT sockets |
| `net.ipv4.ip_local_port_range` | 32768-60999 | 1024-65000 | More ephemeral ports available |
| `vm.swappiness` | 60 | 10 | Prefer RAM over swap |
| `vm.dirty_ratio` | 20 | 15 | Write dirty pages to disk sooner |

#### 5b. Apply tuning via sysctl.conf

```bash
# First, backup the current config
sudo cp /etc/sysctl.conf /etc/sysctl.conf.backup

# Create a new file for our lab tuning
# Using a separate file under /etc/sysctl.d/ is best practice
# It keeps our changes organized and easy to rollback
sudo tee /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
# ─────────────────────────────────────────────────────────────
# Canonical Lab - TICKET-001 Kernel Tuning
# Applied by: Nkiruka Obilor
# Date: $(date)
# Reason: Improve network performance for high-concurrency web workload
# ─────────────────────────────────────────────────────────────

# NETWORK TUNING
# Maximum connections that can queue up waiting to be accepted
net.core.somaxconn = 65535

# Max packets queued on the NIC before kernel processes them
net.core.netdev_max_backlog = 5000

# SYN backlog — handles TCP handshake floods better
net.ipv4.tcp_max_syn_backlog = 8096

# Allow reuse of TIME_WAIT sockets for new connections
# Reduces "address already in use" errors under load
net.ipv4.tcp_tw_reuse = 1

# Expand the range of ephemeral ports available
# More ports = more simultaneous outbound connections possible
net.ipv4.ip_local_port_range = 1024 65000

# How long to keep TCP connections alive (seconds)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3

# MEMORY TUNING
# Lower swappiness — prefer to keep data in RAM
# 10 = only swap when we have no choice
vm.swappiness = 10

# Write dirty data to disk sooner to avoid I/O spikes
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
```

```bash
# Apply the settings immediately (no reboot needed)
sudo sysctl --system

# Verify the changes took effect
sudo sysctl net.core.somaxconn
# Expected: net.core.somaxconn = 65535

sudo sysctl vm.swappiness
# Expected: vm.swappiness = 10
```

> 💡 **Key learning:** `sysctl --system` reads all .conf files in `/etc/sysctl.d/` and applies them. This is the production-safe way to tune. The alternative `sysctl -w` changes are lost on reboot — never do that in production without also updating the config file.

---

### STEP 6: Install and Configure node_exporter as a Systemd Service

**What we are doing:** We install Prometheus node_exporter to expose system metrics. More importantly, we configure it as a proper systemd service — this is how Linux manages long-running processes in production.

#### 6a. Install node_exporter

```bash
# Define the version we want (check https://github.com/prometheus/node_exporter/releases)
NODE_EXPORTER_VERSION="1.7.0"

# Download the binary
cd /tmp
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

# Extract it
tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz

# Move the binary to /usr/local/bin (standard location for locally installed binaries)
sudo mv node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/

# Verify it works
node_exporter --version
```

#### 6b. Create a dedicated system user for node_exporter

```bash
# Always run services as a dedicated non-root user
# This limits the damage if the service is compromised
sudo useradd --system --no-create-home --shell /bin/false node_exporter

# Why --no-create-home: this is a system user, not a person
# Why --shell /bin/false: prevents anyone from logging in as this user
```

#### 6c. Create the systemd service unit file

**This is one of the most important things to understand as a Linux engineer.**

```bash
sudo tee /etc/systemd/system/node_exporter.service << 'EOF'
# /etc/systemd/system/node_exporter.service
# systemd unit file for Prometheus node_exporter
#
# A systemd unit file has three main sections:
# [Unit]    - metadata and dependencies
# [Service] - how to run the service
# [Install] - how to enable it at boot

[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
# Only start after the network is available
After=network-online.target
Wants=network-online.target

[Service]
# Run as our dedicated non-root user
User=node_exporter
Group=node_exporter

# Type=simple means systemd considers the service started as soon as the process starts
Type=simple

# The actual command to run
ExecStart=/usr/local/bin/node_exporter \
    --web.listen-address=:9100 \
    --collector.systemd \
    --collector.processes

# Restart the service if it crashes
Restart=on-failure
RestartSec=5s

# Security hardening — limit what the service can do
# PrivateTmp: service gets its own /tmp
PrivateTmp=yes
# ProtectSystem: /usr and /boot are read-only
ProtectSystem=full
# NoNewPrivileges: service cannot gain more privileges
NoNewPrivileges=yes

[Install]
# WantedBy tells systemd: "start this service when multi-user.target is reached"
# multi-user.target = normal Linux boot state (no GUI)
WantedBy=multi-user.target
EOF
```

> 💡 **Understanding systemd units:** Every service on a production Ubuntu server is managed by systemd. When a client says "my app keeps dying" — the first thing you do is check the systemd unit file and `journalctl` logs. This pattern is universal across all Linux distributions.

#### 6d. Enable and start the service

```bash
# Tell systemd to reload its configuration (picks up our new file)
sudo systemctl daemon-reload

# Enable the service — this means it will start automatically on boot
sudo systemctl enable node_exporter

# Start the service now
sudo systemctl start node_exporter

# Check that it is running
sudo systemctl status node_exporter
# Look for: Active: active (running)

# View the service logs (last 50 lines)
sudo journalctl -u node_exporter -n 50

# Follow the logs in real time (Ctrl+C to stop)
sudo journalctl -u node_exporter -f
```

#### 6e. Verify metrics are being exposed

```bash
# From the server itself, curl the metrics endpoint
curl http://localhost:9100/metrics | head -30

# You should see lines like:
# # HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# # TYPE go_gc_duration_seconds summary
# node_cpu_seconds_total{cpu="0",mode="idle"} 245.87
# node_memory_MemTotal_bytes 1.032617984e+09
```

---

### STEP 7: Create Your Handover Document

**What we are doing:** You write up what you found, what you changed, and what the support team needs to know.

```bash
# Back on your local machine
cd /path/to/session-01-linux-tuning/docs/

cat > HANDOVER-TICKET-001.md << 'EOF'
# HANDOVER DOCUMENT
## TICKET-001: Ubuntu Server Performance Investigation & Tuning
**Client:** RetailEdge Ltd
**Engineer:** Nkiruka Obilor
**Date:** $(date)
**Status:** Resolved — Pending monitoring period

---

## Findings Summary

### Root Cause
The server's kernel networking parameters were at default values optimized for
development workloads, not production web traffic. Under load, the TCP connection
queue (`somaxconn`) was filling up, causing new connections to be silently dropped.

### Changes Made

| Parameter | Before | After | Impact |
|---|---|---|---|
| net.core.somaxconn | 4096 | 65535 | Prevents connection drops under load |
| net.ipv4.tcp_tw_reuse | 0 | 1 | Reduces port exhaustion |
| vm.swappiness | 60 | 10 | Keeps active data in RAM |
| node_exporter service | Not installed | Running on :9100 | Visibility into server health |

### Files Modified
- `/etc/sysctl.d/99-canonical-lab-tuning.conf` — kernel tuning parameters
- `/etc/systemd/system/node_exporter.service` — monitoring service unit

### How to Rollback
```bash
# Remove our tuning file
sudo rm /etc/sysctl.d/99-canonical-lab-tuning.conf
# Reload sysctl
sudo sysctl --system
# Stop monitoring if desired
sudo systemctl stop node_exporter
sudo systemctl disable node_exporter

```

## Monitoring Access
Metrics available at: http://SERVER_IP:9100/metrics
Recommended: Connect this to Prometheus + Grafana for dashboards.

## Next Steps for Support Team
1. Monitor server performance over 48 hours under normal load
2. If latency issues persist, escalate to Session 2 (storage investigation)
3. Consider setting up Prometheus + Grafana for visualization
EOF
```

---

### STEP 8: Commit Your Work to GitHub

```bash
cd /path/to/cloud-field-engineer-labs/

# Add all files
git add .

# Commit with a meaningful message
git commit -m "session-01: linux kernel tuning and node_exporter setup (TICKET-001)"

# Push to GitHub
git push origin main
```

---

### STEP 9: Clean Up (Important!)

**Always destroy your AWS resources after the lab to avoid charges.**

```bash
cd session-01-linux-tuning/terraform/

# Destroy everything Terraform created
terraform destroy

# Type 'yes' when prompted
# Expected: Destroy complete! Resources: 7 destroyed.
```

---

## 🧠 What You Learned This Session

By completing this lab you now understand:

1. **Infrastructure as Code with Terraform** — you didn't click anything in the AWS console. Every resource is documented in code, repeatable, and reviewable.

2. **Linux /proc and /sys filesystems** — these expose the kernel's internals. This knowledge separates junior from senior Linux engineers.

3. **sysctl kernel tuning** — you understand what TCP connection queuing is and why it matters for web servers under load.

4. **systemd service management** — you can create, manage, and troubleshoot systemd services. This is a daily skill for any Linux engineer.

5. **Professional handover documentation** — you wrote a document that a support team could act on without calling you back.

---

## 📚 Go Deeper 

- Why does TCP have a three-way handshake and what happens when the SYN queue fills?
- What is `TIME_WAIT` and why does it exist?
- Read: [Brendan Gregg's Linux Performance page](http://www.brendangregg.com/linuxperf.html)
- Canonical's Ubuntu Server Guide: [https://ubuntu.com/server/docs](https://ubuntu.com/server/docs)

---

## ⏭️ Next Session

**TICKET-002:** Storage optimization — LVM, EBS, and filesystem monitoring.
