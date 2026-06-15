variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment label applied to all resource Name tags"
  type        = string
  default     = "retailedge-lab"
}

variable "ops_ip" {
  description = "Ops workstation public IP without the /32 suffix"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for subnets and EC2 instance"
  type        = string
  default     = "us-east-1a"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID for us-east-1"
  type        = string
  default     = "ami-0d7405d05f836d0d4"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Name of the AWS key pair to use for SSH access"
  type        = string
  default     = "cfe"
}

variable "public_key_path" {
  description = "Local path to the public key file for the session key pair"
  type        = string
  default     = "~/.ssh/cfe.pub"
}

