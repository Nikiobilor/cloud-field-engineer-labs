output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.main.id
}

output "internet_gateway_id" {
  description = "ID of the internet gateway attached to the VPC"
  value       = aws_internet_gateway.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet"
  value       = aws_subnet.private.id
}

output "public_route_table_id" {
  description = "ID of the public route table — contains 0.0.0.0/0 via IGW"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID of the private route table — local route only, no default"
  value       = aws_route_table.private.id
}

output "web_sg_id" {
  description = "ID of the web-tier security group"
  value       = aws_security_group.web.id
}

output "app_sg_id" {
  description = "ID of the app-tier security group — port 8080 sourced from web-sg ID"
  value       = aws_security_group.app.id
}

