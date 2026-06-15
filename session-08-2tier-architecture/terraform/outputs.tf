output "web_instance_public_ip" {
  description = "Public IP of the web tier EC2 instance — use this to update GitHub Secrets EC2_HOST"
  value       = aws_instance.web.public_ip
}

output "web_instance_private_ip" {
  description = "Private IP of the web tier EC2 instance"
  value       = aws_instance.web.private_ip
}

output "web_instance_id" {
  description = "Instance ID of the web tier EC2 instance"
  value       = aws_instance.web.id
}

output "vpc_id" {
  description = "ID of the VPC created by the vpc module"
  value       = module.vpc.vpc_id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = module.vpc.public_subnet_id
}

output "private_subnet_id" {
  description = "ID of the private subnet"
  value       = module.vpc.private_subnet_id
}

output "public_route_table_id" {
  description = "ID of the public route table — should have 0.0.0.0/0 via IGW"
  value       = module.vpc.public_route_table_id
}

output "private_route_table_id" {
  description = "ID of the private route table — should have local route only"
  value       = module.vpc.private_route_table_id
}

output "web_sg_id" {
  description = "ID of the web-tier security group"
  value       = module.vpc.web_sg_id
}

output "app_sg_id" {
  description = "ID of the app-tier security group — port 8080 source is web-sg ID"
  value       = module.vpc.app_sg_id
}

output "internet_gateway_id" {
  description = "ID of the internet gateway"
  value       = module.vpc.internet_gateway_id
}

