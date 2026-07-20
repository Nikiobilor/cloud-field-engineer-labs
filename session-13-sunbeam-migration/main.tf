# main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "allowed_ssh_cidr" {
  description = "Your current IP, /32 only — never 0.0.0.0 slash 0"
  type        = string
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair in this region — must already exist in AWS, Terraform doesn't create it"
  type        = string
}

resource "aws_security_group" "sunbeam_lab" {
  name        = "session13-sunbeam-lab"
  description = "Session 13 - Sunbeam private cloud lab"

  ingress {
    description = "SSH from operator IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Juju controller <-> unit communication (loopback-scoped, but declared
  # explicitly so the intent is documented, not implicit)
  ingress {
    description = "Juju controller API"
    from_port   = 17070
    to_port     = 17070
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Session = "13"
    Purpose = "sunbeam-migration-lab"
  }
}

resource "aws_instance" "sunbeam_host" {
  ami           = data.aws_ami.ubuntu_2404.id
  instance_type = "m5.xlarge" # 4 vCPU / 16GB — matches Sunbeam's documented minimum; step up to m5.2xlarge only if bootstrap struggles for resources
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.sunbeam_lab.id]

  root_block_device {
    volume_size = 100 # Juju controller + Sunbeam + MicroCeph OSD all share this disk in the lab
    volume_type = "gp3"
  }

  tags = {
    Name    = "session13-sunbeam-host"
    Session = "13"
  }
}

data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

output "instance_public_ip" {
  value = aws_instance.sunbeam_host.public_ip
}