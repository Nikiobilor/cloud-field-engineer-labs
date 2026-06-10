# All configurable inputs for our Terraform module

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t2.micro is free tier eligible"
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key file"
  type        = string
  default     = "~/.ssh/canonical_lab_key.pub"
}
