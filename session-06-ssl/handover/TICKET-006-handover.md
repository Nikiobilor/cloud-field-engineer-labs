# Handover Document — TICKET-006
**Prepared by:** Cloud Field Engineer  
**Date:** $(date +%Y-%m-%d)  
**Client:** RetailEdge Ltd  
**Environment:** Ubuntu 22.04 LTS, AWS EC2, eu-west-1  

---

## Summary

TLS termination has been implemented at the nginx reverse proxy layer. The RetailEdge application endpoint is now accessible exclusively via HTTPS on port 443. All plaintext HTTP traffic on port 80 is permanently redirected (HTTP 301) to the HTTPS equivalent. Certificate renewal is automated via a systemd timer.

---

## Root Cause

The nginx reverse proxy was configured to serve content over plaintext HTTP only. No TLS certificate was present on the server. This configuration exposed all application traffic (including any future session tokens or form submissions) to interception and violated PCI-DSS v4.0 Requirement 4.2.1, which mandates strong cryptography for data in transit.

---

## Changes Made

### Files Created
| File | Purpose |
|---|---|
| `/etc/letsencrypt/live/retailedge-lab/fullchain.pem` | TLS certificate (self-signed for lab; replace with Let's Encrypt in production) |
| `/etc/letsencrypt/live/retailedge-lab/privkey.pem` | TLS private key (permissions: 600, root only) |
| `/etc/ssl/certs/dhparam.pem` | 2048-bit Diffie-Hellman parameters for forward secrecy |
| `/etc/nginx/snippets/tls-hardening.conf` | Reusable TLS hardening directives (protocols, ciphers, OCSP, HSTS) |

### Files Modified
| File | Change |
|---|---|
| `/etc/nginx/sites-available/retailedge` | Added HTTPS server block on port 443; converted port 80 block to redirect |
| `/usr/local/bin/configure-firewall.sh` | Added `ufw allow 443/tcp` rule |
| `/etc/cron.d/certbot` | Disabled (renamed `.disabled`) — renewal handled by systemd timer |

### Services Verified
| Service | Port | Status |
|---|---|---|
| nginx | 80 (redirect), 443 (HTTPS) | Active, reloaded |
| certbot.timer | N/A | Active (waiting), next renewal in ~12h |
| myapp | 127.0.0.1:8080 (loopback) | Active, unmodified |
| node_exporter | 9100 (ops IP only) | Active, unmodified |

---

## TLS Configuration Summary

| Parameter | Value |
|---|---|
| Protocols | TLS 1.2, TLS 1.3 |
| Cipher order | Server-preferred, ECDHE/DHE cipher suites only |
| Forward secrecy | Yes (ECDHE + DHE) |
| HSTS | max-age=31536000; includeSubDomains; preload |
| OCSP Stapling | Enabled |
| HTTP/2 | Enabled |

---

## Rollback Instructions

If the HTTPS configuration causes issues and HTTP service must be restored immediately:

```bash
# Step 1: Restore the HTTP-only nginx configuration (from git or bootstrap script)
sudo cp /etc/nginx/sites-available/retailedge.bak /etc/nginx/sites-available/retailedge
sudo nginx -t && sudo systemctl reload nginx

# Step 2: Remove the HTTPS UFW rule
sudo ufw delete allow 443/tcp
```

**Warning:** Rolling back to HTTP-only will immediately re-expose the PCI-DSS finding. This rollback is for emergency use only and should be communicated to the client's compliance team.

---

## Next Steps for Operations Team

1. **Replace the self-signed certificate with a real Let's Encrypt certificate** once a DNS-resolvable domain name is pointed at this server's IP:
   ```bash
   sudo certbot --nginx -d yourdomain.com --non-interactive --agree-tos -m admin@yourdomain.com
   ```

2. **Monitor certificate expiry** — Certbot's systemd timer handles renewal automatically, but add an external monitoring check (e.g. Prometheus `ssl_expiry` blackbox exporter probe) to alert if renewal fails.

3. **Allocate an AWS Elastic IP** to this instance to prevent the public IP from changing on next stop/start cycle, which would invalidate the certificate's SAN field.

4. **Submit the domain to the HSTS preload list** (`https://hstspreload.org`) after confirming the configuration is stable — this provides an additional layer of protection for first-time visitors.

5. **Run a full SSL Labs audit** (`https://www.ssllabs.com/ssltest/`) once a real domain is configured to obtain an A or A+ grade for the compliance record.
