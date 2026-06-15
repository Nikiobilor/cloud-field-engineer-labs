variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.0.0.0/16)"
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (e.g. 10.0.1.0/24)"
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (e.g. 10.0.2.0/24)"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone to place both subnets in (e.g. us-east-1a)"
  type        = string
}

variable "environment" {
  description = "Environment label applied to all resource Name tags (e.g. retailedge-lab)"
  type        = string
}

variable "ops_ip_cidr" {
  description = "CIDR for the ops workstation IP used to scope SSH and node_exporter access (e.g. 203.0.113.10/32)"
  type        = string
}

