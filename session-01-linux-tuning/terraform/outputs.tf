# outputs.tf
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
