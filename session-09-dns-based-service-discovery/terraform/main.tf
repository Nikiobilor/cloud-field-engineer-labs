terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "your-terraform-state-bucket-651697298579"
    key    = "session8/terraform.tfstate"
    region = "us-east-1"

    # native Terraform 1.10 state locking — no DynamoDB table required
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "voh-admin"
}

# ─── VPC MODULE ───────────────────────────────────────────────────────────────
# All network resources live inside the module.
# The root configuration passes parameters and references outputs to
# place the EC2 instance in the correct subnet with the correct security group.

module "vpc" {
  source = "./modules/vpc"

  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24"
  private_subnet_cidr = "10.0.2.0/24"
  availability_zone   = var.availability_zone
  environment         = var.environment

  # /32 appended here so the variable stays as a bare IP everywhere else
  ops_ip_cidr = "${var.ops_ip}/32"
}

# ─── KEY PAIR ─────────────────────────────────────────────────────────────────
# Generated fresh each session; public key path is set in variables.tf

resource "aws_key_pair" "session8" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)

  tags = {
    Name        = "${var.environment}-session8-key"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── EC2 INSTANCE — WEB TIER ─────────────────────────────────────────────────
# Placed in the public subnet so nginx is reachable from the internet.
# Security group is web-sg from the module output — not hardcoded.

resource "aws_instance" "web" {
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id              = module.vpc.public_subnet_id
  vpc_security_group_ids = [module.vpc.web_sg_id]

  # public IP required for SSH access and for nginx to serve internet traffic
  associate_public_ip_address = true

  key_name = aws_key_pair.session8.key_name

  root_block_device {
    # 20GB root volume — expanded from 8GB in Session 5
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.environment}-web"
    Environment = var.environment
    Tier        = "web"
    ManagedBy   = "Terraform"
    Session     = "8"
  }
}

# DNS module — Session 9
# Wires the private hosted zone to the Session 8 VPC.
# The vpc_id is read from the vpc module output.
# The web_private_ip is read from the EC2 instance resource.
module "dns" {
  source = "./modules/dns"

  vpc_id         = module.vpc.vpc_id
  web_private_ip = aws_instance.web.private_ip
  dns_ttl        = 60
}
