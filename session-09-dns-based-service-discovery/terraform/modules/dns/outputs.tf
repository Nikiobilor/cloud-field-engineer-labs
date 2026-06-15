output "zone_id" {
  description = "The Route53 hosted zone ID"
  value       = aws_route53_zone.private.zone_id
}

output "zone_name" {
  description = "The domain name of the private hosted zone"
  value       = aws_route53_zone.private.name
}

output "web_record_fqdn" {
  description = "Fully qualified domain name of the web A record"
  value       = aws_route53_record.web.fqdn
}

output "api_record_fqdn" {
  description = "Fully qualified domain name of the API A record"
  value       = aws_route53_record.api.fqdn
}

output "cname_record_fqdn" {
  description = "Fully qualified domain name of the internal CNAME record"
  value       = aws_route53_record.internal_cname.fqdn
}
