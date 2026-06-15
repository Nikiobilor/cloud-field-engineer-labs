variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for both subnets"
  type        = string
}

variable "environment" {
  description = "Environment label applied to all resource Name tags"
  type        = string
}

variable "ops_ip_cidr" {
  description = "CIDR for the ops workstation IP (e.g. 203.0.113.10/32)"
  type        = string
}
