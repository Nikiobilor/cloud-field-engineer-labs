# Private hosted zone for retailedge.internal
# Route53 will only answer queries for this zone from VPCs associated with it.
# Queries from outside the associated VPCs return NXDOMAIN.
resource "aws_route53_zone" "private" {
  name = var.zone_name

  vpc {
    vpc_id = var.vpc_id
  }

  # prevent Terraform from destroying the zone if records were added
  # manually during testing — change to false before production teardowns
  lifecycle {
    prevent_destroy = false
  }

  tags = {
    Name        = "retailedge-internal-zone"
    Environment = "lab"
    ManagedBy   = "terraform"
    Session     = "09"
  }
}

# A record for the web tier
# Points to the private IP of the EC2 instance running nginx
resource "aws_route53_record" "web" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "web.${var.zone_name}"
  type    = "A"
  ttl     = var.dns_ttl

  records = [var.web_private_ip]
}

# A record for the API/app tier
# Placeholder IP — replace when the app tier EC2 instance is provisioned
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "api.${var.zone_name}"
  type    = "A"
  ttl     = var.dns_ttl

  records = [var.api_private_ip]
}

# CNAME record pointing internal.retailedge.internal to web.retailedge.internal
# Used to provide a stable alias name that can be redirected without changing
# all downstream consumers
resource "aws_route53_record" "internal_cname" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "internal.${var.zone_name}"
  type    = "CNAME"
  ttl     = var.dns_ttl

  records = ["web.${var.zone_name}"]
}
