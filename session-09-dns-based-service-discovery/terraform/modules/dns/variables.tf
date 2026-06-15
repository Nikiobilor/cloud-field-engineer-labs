variable "vpc_id" {
  description = "The ID of the VPC to associate the private hosted zone with"
  type        = string
}

variable "zone_name" {
  description = "The domain name for the private hosted zone"
  type        = string
  default     = "retailedge.internal"
}

variable "web_private_ip" {
  description = "Private IP address of the web EC2 instance"
  type        = string
}

variable "api_private_ip" {
  description = "Private IP address of the app tier instance (placeholder if not yet deployed)"
  type        = string
  default     = "10.0.2.10"
}

variable "dns_ttl" {
  description = "TTL in seconds for all DNS records in this zone"
  type        = number
  default     = 60
}
