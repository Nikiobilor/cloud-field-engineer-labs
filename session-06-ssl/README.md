# Session 6 — SSL/TLS Termination, Certificate Automation & HTTPS Enforcement

---

## 🎫 TICKET-006

| Field | Detail |
|---|---|
| **Ticket ID** | TICKET-006 |
| **Priority** | High |
| **Client** | RetailEdge Ltd |
| **Environment** | Ubuntu 22.04 LTS, AWS EC2 t2.micro, eu-west-1 |
| **Subject** | Production site serving plaintext HTTP - PCI-DSS audit failure imminent |
| **Description** | RetailEdge's e-commerce platform is currently accessible over plain HTTP on port 80. An upcoming PCI-DSS compliance audit has flagged the absence of TLS encryption as a critical finding. The client requires HTTPS enforced at the nginx reverse proxy layer, with automatic HTTP→HTTPS redirect, a valid certificate issued by Let's Encrypt, and automated renewal via a systemd timer. The existing nginx configuration from Session 4 must be migrated, not replaced. Additionally, the ops team has requested that the Prometheus node_exporter metrics endpoint (port 9100) be confirmed as inaccessible from outside the ops IP, and that the new TLS configuration be validated with an SSL audit report. |

| **Acceptance Criteria** | 
1. Valid Let's Encrypt certificate installed and served on port 443. 
2. All HTTP traffic on port 80 permanently redirected (301) to HTTPS.
3. Certbot renewal timer active and confirmed working via dry-run. 
4. nginx TLS config scores A or above on SSL Labs criteria (TLS 1.2+, HSTS header, no weak ciphers). 
5. UFW rules updated — port 443 open to all, port 80 open to all (redirect only), port 9100 restricted to ops IP. 
6. Handover document delivered. |

---

## 🎯 Session Goals

By the end of this session you will have:

- Understood how TLS termination at the reverse proxy layer works and why it is the correct architectural pattern for this stack
- Installed Certbot with the nginx plugin and obtained a real Let's Encrypt certificate (or a self-signed equivalent for lab use without a domain)
- Written a production-grade nginx HTTPS server block with modern cipher suites, HSTS, and OCSP stapling
- Configured a permanent HTTP→HTTPS redirect server block
- Replaced Certbot's legacy cron job with a **systemd timer** — the modern, auditable approach
- Validated the TLS configuration against real security benchmarks
- Updated UFW to explicitly allow port 443
- Delivered a professional handover document suitable for a compliance audit pack

---

## 📋 Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Session Bootstrap](#session-bootstrap)
   - [Phase 1 — Terraform: open port 443](#phase-1--terraform-open-port-443)
   - [Phase 2 — bootstrap-session6.sh](#phase-2--bootstrap-session6sh)
   - [Phase 3 — Running the script](#phase-3--running-the-script)
   - [Phase 4 — Update GitHub Secrets](#phase-4--update-github-secrets)
3. [Prerequisites](#prerequisites)
4. [Step 1 — Understand TLS termination at the proxy](#step-1--understand-tls-termination-at-the-proxy)
5. [Step 2 — Install Certbot with the nginx plugin](#step-2--install-certbot-with-the-nginx-plugin)
6. [Step 3 — Lab mode: generate a self-signed certificate](#step-3--lab-mode-generate-a-self-signed-certificate)
7. [Step 4 — Write the production nginx HTTPS server block](#step-4--write-the-production-nginx-https-server-block)
8. [Step 5 — Configure the HTTP→HTTPS redirect](#step-5--configure-the-httphttps-redirect)
9. [Step 6 — Harden the TLS configuration](#step-6--harden-the-tls-configuration)
10. [Step 7 — Replace the Certbot cron with a systemd timer](#step-7--replace-the-certbot-cron-with-a-systemd-timer)
11. [Step 8 — Validate with openssl and curl](#step-8--validate-with-openssl-and-curl)
12. [Step 9 — Update UFW for port 443](#step-9--update-ufw-for-port-443)
13. [Step 10 — Deliver the Handover Document](#step-10--deliver-the-handover-document)
14. [Step 11 — Commit Your Work](#step-11--commit-your-work)
15. [Verification Checklist](#verification-checklist)
16. [Troubleshooting Reference](#troubleshooting-reference)
17. [What You Learned This Session](#what-you-learned-this-session)
18. [Go Deeper](#go-deeper)
19. [Next Session](#next-session)

---

## Architecture Overview

```
                        INTERNET
                           │
                    ┌──────▼──────┐
                    │  AWS Security│
                    │    Group     │
                    │  22 (any)    │
                    │  80 (any)    │  ← redirect only, no content
                    │  443 (any)   │  ← TLS termination
                    │  9100 (ops)  │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │    UFW       │
                    │  (mirrors SG)│
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
         port 80      port 443     port 9100
              │            │            │
    ┌─────────▼──┐  ┌──────▼───────┐  ┌▼──────────────┐
    │  nginx     │  │  nginx       │  │ node_exporter  │
    │ HTTP block │  │ HTTPS block  │  │ (ops IP only)  │
    │ 301 → 443  │  │ TLS termination│ └───────────────┘
    └────────────┘  │ Let's Encrypt│
                    │ cert + key   │
                    └──────┬───────┘
                           │ plain HTTP (loopback only)
                    ┌──────▼───────┐
                    │  myapp.py    │
                    │ 127.0.0.1:8080│
                    └──────────────┘
```

**Why this architecture matters:**

TLS termination at the reverse proxy, not inside the application, is the correct pattern for three reasons. First, your application code (myapp.py) stays simple: it speaks plain HTTP and knows nothing about certificates. Second, you manage certificates in exactly one place (nginx + Certbot), regardless of how many application services are running behind the proxy. Third, in a cloud-native environment you can scale the application horizontally without distributing certificate material to every instance, the load balancer or reverse proxy layer handles encryption, and the backend cluster communicates over a trusted private network.

The key insight for a CFE: the boundary between "encrypted" and "plaintext" is a deliberate architectural decision, not an accident. Here that boundary sits at the nginx layer on the EC2 instance. In a more mature setup it would sit at an AWS ALB with ACM certificates, but the nginx pattern is universal and you will encounter it constantly on bare-metal, on-prem, and in environments where managed load balancers are not available.

---

## Session Bootstrap

### Phase 1 — Terraform: open port 443

Every time you terminate and recreate an EC2 instance, you run `terraform apply` from your local machine to provision a fresh server. This session requires port 443 to be open in the AWS Security Group. The change goes in Terraform, not the AWS console, because the console is ephemeral state — the next `terraform apply` would overwrite it. Infrastructure as code means the `.tf` files are the single source of truth.

Open `main.tf` and locate your `aws_security_group` resource. Add the HTTPS ingress block:

```hcl
# main.tf — add this block inside your aws_security_group resource
# alongside the existing ingress rules for ports 22, 80, and 9100

ingress {
  description = "HTTPS from anywhere"
  from_port   = 443          # Start of port range
  to_port     = 443          # End of port range (same = single port)
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"] # Allow from any IPv4 address
}
```

Your complete security group ingress section should now look like this:

```hcl
resource "aws_security_group" "lab_sg" {
  name        = "canonical-lab-sg"
  description = "Security group for CFE training lab"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }



  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Prometheus node_exporter - ops IP only"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip]   # Set in terraform.tfvars
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"           # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

Apply the change:

```bash
# On your local machine, inside the terraform/ directory
terraform plan    # Review what will change — should show security group modification only
terraform apply   # Confirm with 'yes' when prompted
```

After `terraform apply` completes, note the new public IP from the output:

```bash
terraform output instance_public_ip   # Copy this — you'll need it for Phase 4
```

---

### Phase 2 — bootstrap-session6.sh

This script restores the complete cumulative environment from Sessions 1–5, then deliberately introduces the broken state for Session 6: nginx is running but serving only HTTP (no HTTPS configuration, no TLS certificate). The engineer walks into a server that is live on port 80 with no encryption.

```bash
#!/usr/bin/env bash
# =============================================================================
# bootstrap-session6.sh
# Canonical CFE Training Series — Session 6
#
# PURPOSE:
#   Rebuilds all state from Sessions 1-5 on a fresh EC2 instance, then
#   introduces the Session 6 scenario: nginx running HTTP-only, no TLS.
#
# IDEMPOTENCY:
#   Safe to run multiple times. Uses || true guards on commands that may
#   fail if already applied. Package installs are idempotent via apt-get.
#
# EXPECTED RUNTIME: 3-5 minutes
# MUST RUN AS:      sudo bash bootstrap-session6.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# PHASE 0 — SYSTEM UPDATE AND BASE PACKAGES
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 0: System update and base packages"
echo "=============================================="

export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get upgrade -yq

# Install all required packages.
# Each package is on its own line for readability.
# NO inline comments after the backslash — bash requires \ to be the last character.
apt-get install -yq \
    curl \
    wget \
    git \
    tcpdump \
    nginx \
    ufw \
    python3 \
    rsyslog \
    logrotate \
    lvm2 \
    certbot \
    python3-certbot-nginx

echo "[OK] Base packages installed"

# =============================================================================
# PHASE 1 — SESSION 1: KERNEL TUNING
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 1: Kernel tuning (Session 1)"
echo "=============================================="

cat > /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
# Canonical CFE Lab — kernel tuning parameters
net.core.somaxconn    = 65535
net.ipv4.tcp_tw_reuse = 1
vm.swappiness         = 10
net.core.rmem_max     = 16777216
net.core.wmem_max     = 16777216
EOF

sysctl --system > /dev/null 2>&1

echo "[OK] Kernel tuning applied"

# =============================================================================
# PHASE 2 — SESSION 1: NODE_EXPORTER
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 2: node_exporter (Session 1)"
echo "=============================================="

NODE_EXPORTER_VERSION="1.7.0"
NODE_EXPORTER_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"

if [ ! -f /usr/local/bin/node_exporter ]; then
    echo "  Downloading node_exporter v${NODE_EXPORTER_VERSION}..."
    wget -q \
        "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_ARCHIVE}.tar.gz" \
        -O /tmp/node_exporter.tar.gz
    tar -xzf /tmp/node_exporter.tar.gz -C /tmp/
    mv /tmp/${NODE_EXPORTER_ARCHIVE}/node_exporter /usr/local/bin/
    rm -rf /tmp/node_exporter.tar.gz /tmp/${NODE_EXPORTER_ARCHIVE}
    echo "  Binary installed at /usr/local/bin/node_exporter"
else
    echo "  node_exporter binary already present — skipping download"
fi

# Create dedicated system user (no login shell, no home directory)
useradd --system --no-create-home --shell /bin/false node_exporter || true

cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter --quiet
systemctl restart node_exporter

echo "[OK] node_exporter running on port 9100"

# =============================================================================
# PHASE 3 — SESSION 3: MYAPP SERVICE AND LOGGING
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 3: myapp service and logging (Session 3)"
echo "=============================================="

mkdir -p /opt/myapp

cat > /opt/myapp/app.py << 'EOF'
#!/usr/bin/env python3
"""
RetailEdge myapp — simulated application server.
Listens on 127.0.0.1:8080 (loopback only).
nginx proxies external traffic to this service.
"""
import http.server
import socketserver
import datetime

PORT = 8080
BIND = "127.0.0.1"

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/plain")
        self.end_headers()
        self.wfile.write(b"RetailEdge myapp OK\n")

    def log_message(self, format, *args):
        with open("/var/log/myapp/access.log", "a") as f:
            f.write(f"{datetime.datetime.now()} - {format % args}\n")

with socketserver.TCPServer((BIND, PORT), Handler) as httpd:
    httpd.serve_forever()
EOF

mkdir -p /var/log/myapp
chown -R www-data:www-data /var/log/myapp || true

cat > /etc/systemd/system/myapp.service << 'EOF'
[Unit]
Description=RetailEdge MyApp (simulated)
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=/opt/myapp
ExecStart=/usr/bin/python3 /opt/myapp/app.py
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
EOF

# journald persistent storage
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/canonical-lab.conf << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
MaxRetentionSec=1month
EOF

# logrotate for myapp logs
cat > /etc/logrotate.d/myapp << 'EOF'
/var/log/myapp/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    maxsize 100M
    postrotate
        systemctl kill --kill-who=main --signal=HUP myapp.service || true
    endscript
}
EOF

# rsyslog forwarding rule
cat > /etc/rsyslog.d/49-myapp.conf << 'EOF'
:programname, isequal, "myapp" /var/log/myapp/myapp.log
& stop
EOF

systemctl daemon-reload
systemctl enable myapp --quiet
systemctl restart myapp
systemctl restart rsyslog

echo "[OK] myapp running on 127.0.0.1:8080"

# =============================================================================
# PHASE 4 — SESSION 3: HEALTH CHECK CRON
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 4: Health check cron (Session 3)"
echo "=============================================="

cat > /usr/local/bin/myapp-alert.sh << 'EOF'
#!/usr/bin/env bash
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/REPLACE_ME}"
if ! systemctl is-active --quiet myapp.service; then
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
        -H 'Content-type: application/json' \
        --data "{\"text\":\"[ALERT] myapp.service is not running on $(hostname)\"}" || true
fi
EOF

chmod +x /usr/local/bin/myapp-alert.sh

# Add cron entry only if not already present
TMPFILE=$(mktemp)
crontab -l 2>/dev/null | grep -v "myapp-alert" > "$TMPFILE" || true
echo "*/5 * * * * /usr/local/bin/myapp-alert.sh" >> "$TMPFILE"
crontab "$TMPFILE"
rm -f "$TMPFILE"

echo "[OK] myapp health check cron installed"

# =============================================================================
# PHASE 5 — SESSION 4: NGINX REVERSE PROXY (HTTP ONLY — session 6 scenario)
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 5: nginx HTTP reverse proxy (Session 4)"
echo "=============================================="

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/retailedge << 'EOF'
# RetailEdge nginx — HTTP ONLY (Session 4 state)
# Session 6 will add TLS termination on port 443.
server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/retailedge-access.log;
    error_log  /var/log/nginx/retailedge-error.log;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/retailedge /etc/nginx/sites-enabled/retailedge

nginx -t
systemctl enable nginx --quiet
systemctl restart nginx

echo "[OK] nginx running HTTP-only on port 80"

# =============================================================================
# PHASE 6 — SESSION 4: UFW FIREWALL
# Port 443 is intentionally absent — the engineer adds it in Step 9.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 6: UFW firewall (Session 4)"
echo "=============================================="

OPS_IP="${OPS_IP:-203.0.113.10/32}"

cat > /usr/local/bin/configure-firewall.sh << EOF
#!/usr/bin/env bash
# configure-firewall.sh — idempotent UFW configuration
# Source of truth for this server's firewall policy.

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP (redirect to HTTPS)'
ufw allow from ${OPS_IP} to any port 9100 proto tcp comment 'node_exporter ops only'
ufw allow in on lo

ufw --force enable
EOF

chmod +x /usr/local/bin/configure-firewall.sh
bash /usr/local/bin/configure-firewall.sh

echo "[OK] UFW configured (port 443 not yet open — added in Step 9)"

# =============================================================================
# PHASE 7 — SESSION 5: LVM STORAGE
# Skipped gracefully if /dev/xvdb is not attached.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 7: LVM storage (Session 5)"
echo "=============================================="

if [ -b /dev/xvdb ]; then
    echo "  /dev/xvdb detected — configuring LVM..."

    pvs /dev/xvdb > /dev/null 2>&1 || pvcreate /dev/xvdb

    vgdisplay retailedge-logs-vg > /dev/null 2>&1 || \
        vgcreate retailedge-logs-vg /dev/xvdb

    lvdisplay /dev/retailedge-logs-vg/logs > /dev/null 2>&1 || {
        lvcreate -L 4G -n logs retailedge-logs-vg
        mkfs.ext4 /dev/retailedge-logs-vg/logs
    }

    grep -q "retailedge-logs-vg" /etc/fstab || \
        echo "/dev/retailedge-logs-vg/logs /var/log/myapp ext4 defaults 0 2" >> /etc/fstab

    mountpoint -q /var/log/myapp || mount /var/log/myapp

    tune2fs -m 1 /dev/retailedge-logs-vg/logs > /dev/null 2>&1

    echo "[OK] LVM configured — /var/log/myapp on /dev/retailedge-logs-vg/logs"
else
    echo "  [SKIP] /dev/xvdb not found — attach the second EBS volume and re-run"
fi

# =============================================================================
# PHASE 8 — SESSION 5: DISK ALERT CRON
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 8: Disk alert cron (Session 5)"
echo "=============================================="

cat > /usr/local/bin/disk-alert.sh << 'EOF'
#!/usr/bin/env bash
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/REPLACE_ME}"
THRESHOLD=80

df -h --output=pcent,target | tail -n +2 | while read -r line; do
    USAGE=$(echo "$line" | awk '{print $1}' | tr -d '%')
    MOUNT=$(echo "$line" | awk '{print $2}')
    if [ "$USAGE" -ge "$THRESHOLD" ]; then
        curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"[ALERT] Disk usage ${USAGE}% on ${MOUNT} at $(hostname)\"}" || true
    fi
done
EOF

chmod +x /usr/local/bin/disk-alert.sh

TMPFILE=$(mktemp)
crontab -l 2>/dev/null | grep -v "disk-alert" > "$TMPFILE" || true
echo "*/5 * * * * /usr/local/bin/disk-alert.sh" >> "$TMPFILE"
crontab "$TMPFILE"
rm -f "$TMPFILE"

echo "[OK] Disk alert cron installed"

# =============================================================================
# PHASE 9 — SCENARIO STATE CONFIRMATION
# =============================================================================
echo ""
echo "=============================================================="
echo " SESSION 6 ENVIRONMENT READY"
echo "=============================================================="
echo ""
echo " Services running:"
systemctl is-active node_exporter > /dev/null 2>&1 \
    && echo "   [OK] node_exporter  — port 9100 (ops IP only)" \
    || echo "   [FAIL] node_exporter not running"
systemctl is-active myapp > /dev/null 2>&1 \
    && echo "   [OK] myapp          — 127.0.0.1:8080" \
    || echo "   [FAIL] myapp not running"
systemctl is-active nginx > /dev/null 2>&1 \
    && echo "   [OK] nginx          — port 80 (HTTP only)" \
    || echo "   [FAIL] nginx not running"
echo ""
echo " Scenario state (what the engineer will fix):"
echo "   [!] No TLS certificate installed"
echo "   [!] nginx serving plaintext HTTP only — no HTTPS"
echo "   [!] No HTTP to HTTPS redirect"
echo "   [!] Port 443 not open in UFW"
echo "   [!] No Certbot renewal timer confirmed"
echo ""
echo " Ready to begin Session 6 steps."
echo "=============================================================="
```

Save this as `bootstrap-session6.sh` on your **local machine** before the next phase.

---

### Phase 3 — Running the Script

```bash
# On your local machine — transfer the script to the new server
# Replace <NEW_IP> with the IP from 'terraform output instance_public_ip'
# Replace ~/.ssh/id_rsa with the path to your current session's private key

scp -i ~/.ssh/id_rsa \
    bootstrap-session6.sh \           # Local file to transfer
    ubuntu@<NEW_IP>:/home/ubuntu/     # Destination on the server

# SSH into the server
ssh -i ~/.ssh/id_rsa ubuntu@<NEW_IP>

# Once logged in, run the bootstrap script with sudo
sudo bash /home/ubuntu/bootstrap-session6.sh
```

**Expected runtime:** 3–5 minutes depending on network speed for package downloads.

**Successful completion looks like:**

```
==============================================================
 SESSION 6 ENVIRONMENT READY
==============================================================

 Services running:
   ✓ node_exporter  — port 9100 (ops IP only)
   ✓ myapp          — 127.0.0.1:8080 (loopback only)
   ✓ nginx          — port 80 (HTTP reverse proxy)
   ✓ rsyslog        — syslog forwarding active

 Firewall (UFW):
   ✓ 22/tcp   — SSH (any)
   ✓ 80/tcp   — HTTP (any)
   ✗ 443/tcp  — NOT OPEN (engineer adds in Step 9)
   ✓ 9100/tcp — ops IP only

 Scenario state:
   ✗ No TLS certificate installed
   ✗ nginx serving plaintext HTTP only
   ✗ No HTTP→HTTPS redirect
   ✗ No Certbot renewal timer
==============================================================
```

If the script exits early, check `/var/log/syslog` for the failing command. Common causes: network issues downloading node_exporter, or `/dev/xvdb` not attached (LVM phase will skip gracefully with a message rather than failing).

---

### Phase 4 — Update GitHub Secrets

EC2 public IPs change every time you terminate and recreate an instance. There is no DNS or Elastic IP in this lab, so your GitHub Secrets must be updated manually at the start of each session.

**Always update:**
- `EC2_HOST` — set to the new public IP from `terraform output instance_public_ip`

**Update only if you regenerated your SSH key pair:**
- `EC2_SSH_KEY` — the private key content (paste the full PEM including header/footer lines)
- `EC2_USER` — `ubuntu` (this never changes for Ubuntu 22.04 AMIs)
- `OPS_IP` — your ops IP (only changes if your internet connection's IP changed)

> **Production note:** In a real engagement, you would allocate an AWS Elastic IP and associate it with the instance. Elastic IPs persist across stop/start cycles and cost nothing when associated with a running instance. That would eliminate the need to update `EC2_HOST` each session. For this lab, the repeated IP update is intentional — it builds the muscle memory of understanding that cloud IPs are ephemeral by default.

---

## Prerequisites

The bootstrap above satisfies every prerequisite. Review this list to confirm your environment before starting.

- ✅ EC2 instance running Ubuntu 22.04 with public IP obtained from Terraform
- ✅ SSH access working with your current session's key pair
- ✅ GitHub Secrets updated: `EC2_HOST`, `EC2_SSH_KEY`
- ✅ nginx installed and running on port 80 (HTTP only)
- ✅ myapp running on `127.0.0.1:8080`
- ✅ Certbot and python3-certbot-nginx installed (installed by bootstrap)
- ✅ UFW active with ports 22, 80, 9100 configured
- ✅ Port 443 open in the AWS Security Group (added in Terraform Phase 1)

---

## Step 1 — Understand TLS Termination at the Proxy

**What we are doing and why:**

Before writing a single configuration line, it is worth understanding precisely what the system needs to do. TLS (Transport Layer Security) is the cryptographic protocol that underlies HTTPS. It provides three properties: confidentiality (data is encrypted in transit), integrity (data cannot be tampered with undetected), and authentication (the server can prove its identity via a certificate signed by a trusted authority).

In this architecture, nginx is the TLS **termination point**. This means nginx handles the TLS handshake with the browser, decrypts the traffic, and then forwards plain HTTP to myapp on the loopback interface. The word "terminate" is not accidental, the encrypted channel ends at nginx. What travels from nginx to myapp is unencrypted, but that is acceptable because it never leaves the machine.

A Let's Encrypt certificate consists of two files:
- **Certificate (fullchain.pem):** Your public certificate plus the intermediate CA certificates that chain up to Let's Encrypt's root, which is trusted by all major browsers.
- **Private key (privkey.pem):** The secret key your server uses during the TLS handshake. This file must be kept secret, it proves you own the certificate.

Let's Encrypt issues certificates via the **ACME protocol**. Certbot implements ACME. The verification method we will use is **HTTP-01 challenge**: Let's Encrypt's servers make an HTTP request to your domain to verify you control it, then issue the certificate. This requires that port 80 be publicly accessible and that your server has a real DNS-resolvable domain name.

> **Lab reality check:** Because this is a training lab on an EC2 instance without a registered domain, you cannot use Let's Encrypt's production API against a real domain. In Step 3 you will generate a self-signed certificate to complete the nginx configuration correctly. In Step 4 you will configure the nginx blocks exactly as you would for a real Let's Encrypt certificate, the configuration is identical; only the certificate source differs. Understanding both paths is essential: you will encounter self-signed certificates in air-gapped environments, internal services, and development setups throughout your career.

| Certificate type | Browser trusts it | Renewal needed | Command |
|---|---|---|---|
| Let's Encrypt (production) | ✅ Yes | Every 90 days (automatic) | `certbot --nginx -d yourdomain.com` |
| Let's Encrypt (staging) | ❌ No (test only) | y 90 days | `certbot --nginx --staging -d yourdomain.com` |
| Self-signed (lab) | ❌ No | Manually (or script) | `openssl req -x509 ...` |

---

## Step 2 — Install Certbot with the nginx Plugin

**What we are doing and why:**

The bootstrap script already installed Certbot, but it is worth understanding what the nginx plugin does. Without the plugin, Certbot only obtains the certificate and leaves you to update the nginx configuration manually. With the plugin (`python3-certbot-nginx`), Certbot can bothain the certificate and automatically modify your nginx configuration to reference it. In production you would use the plugin's automatic mode. In this session you will use the `certonly` subcommand to obtain the certificate without modifying the nginx config, so that you learn to write the configuration yourself, a critical skill for environments where automatic config rewriting is not appropriate.

```bash
# Verify Certbot is installed and check the version
certbot --version
# Expected output: certbot 1.x.x or 2.x.x

# Verify the nginx plugin is available
certbot plugins
# Expected output should list "nginx" as an available authenticator and installer
```

> **Why Certbot's nginx plugin matters in the real world:** In a large environment you might manage dozens of nginx vhosts. Understanding what Certbot's automatic rewrite produces, and being able to write equivalent configuration manually, means you can troubleshoot and customise it rather than treating it as a black box. Cloud field engineers are expected to understand the tools, not just operate them.

---

## Step 3 — Lab Mode: Generate a Self-Signed Certificate

**What we are doing and why:**

Since this EC2 instance does not have a registered domain, we cannot complete a real Let's Encrypt HTTP-01 challenge. We will generate a self-signed certificate using OpenSSL. The nginx configuration in the next steps will reference these files. When you move to a production engagement with a real domain, you replace the certificate files, the nginx configuratioitself is structurally identical.

```bash
# Create the directory structure that Let's Encrypt / Certbot would normally use
# Using the same paths means the nginx config works identically for real certs
sudo mkdir -p /etc/letsencrypt/live/retailedge-lab/

# Generate a 2048-bit RSA private key and a self-signed X.509 certificate
# Valid for 365 days, in a single command
sudo openssl req \
    -x509 \                                         # Produce a self-signed certificate (not a CSR)
    -nodes \                                        # Do not encrypt the private key (no passphrase)
    -days 365 \                                     # Certificate validity period
    -newkey rsa:2048 \                              # Generate a new 2048-bit RSA key pair
    -keyout /etc/letsencrypt/live/retailedge-lab/privkey.pem \    # Where to write the private key
    -out    /etc/letsencrypt/live/retailedge-lab/fullchain.pem \  # Where to write the certificate
    -subj "/C=GB/ST=England/L=London/O=RetailEdge Ltd/CN=retailedge-lab" \
    # ^ Subject fields: Country, State, Locality, Organisation, Common Name
    -addext "subjectAltName=IP:$(curl -s ifconfig.me)"
    # ^ Add the server's public IP as a Subject Alternative Name
    #   Modern browsers require SAN; CN alone is no longer sufficient
    sudo openssl req \
    -x509 \
    -nodes \
    -days 365 \
    -newkey rsa:2048 \
    -keyout /etc/letsencrypt/live/retailedge-lab/privkey.pem \
    -out /etc/letsencrypt/live/retailedge-lab/fullchain.pem \
    -subj "/C=GB/ST=England/L=London/O=RetailEdge Ltd/CN=retailedge-lab" \
    -addext "subjectAltName=IP:$(curl -s ifconfig.me)"

# Restrict permissions on the private key — must be readable only by root
# If an attacker reads your private key, they can impersonate your server
sudo chmod 600 /etc/letsencrypt/live/retailedge-lab/privkey.pem
sudo chmod 644 /etc/letsencrypt/live/retailedge-lab/fullchain.pem

# Generate Diffie-Hellman parameters for forward secrecy
# This file is used in the nginx ssl_dhparam directive (Step 6) Takes 30-60 seconds — this is normal; DH parameter generation requires entropy
sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048

# Verify the certificate was created correctly
sudo openssl x509 -in /etc/letsencrypt/live/retailedge-lab/fullchain.pem \
    -noout \        # Don't print the certificate in PEM format
    -text \         # Print human-readable certificate fields
    | grep -E "Subject:|Not After:|Subject Alternative Name" -A 1
```
sudo openssl x509 -in /etc/letsencrypt/live/retailedglab/fullchain.pem \
    -noout \
    -text \
    | grep -E "Subject:|Not After:|Subject Alternative Name" -A 1
Expected output:
```
        Subject: C = GB, ST = England, L = London, O = RetailEdge Ltd, CN = retailedge-lab
            Not After : [date 365 days from now]
            X509v3 Subject Alternative Name:
                IP Address:[your public IP]
```

> **The -nodes flag explained:** `nodes` stands for "no DES", it means do not encrypt the private key with a passphrase. For a web server this is correct: if the private key were passphrase-protected, nginx would be unable to start automatically after a reboot because there would be no one present to type the passphrase. The security model instead relies on strict file permissions and server access controls.

> **Forward secrecy and DHE:** The `dhparam.pem` file enables cipher suites that use Diffie-Hellman Ephemeral (DHE) key exchange. "Ephemeral" means a fresh key pair is generated for every connection. This provides forward secrecy: even if an attacker later obtains your server's private key, they cannot decrypt previously recorded traffic because each session used a different ephemeral key. This is a PCI-DSS requirement.

---

## Step 4 — Write the Production nginx HTTPS Server Block

**What we are doing and why:**

nginx uses the concept of "server blocks" (equivalent to Apache's virtual hosts) to define how it handles connections on specific IP addresses and ports. We currently have one server block listening on port 80 and proxying to myapp. Wneed to add a second server block that listens on port 443, terminates TLS, and then proxies to myapp in exactly the same way. The port 80 block will be converted into a redirect in Step 5.

The modern approach is to keep the HTTP and HTTPS blocks in the same site configuration file, keeping all RetailEdge-related nginx config in one place.

```bash
# Overwrite the existing HTTP-only configuration with a complete HTTP+HTTPS config
# We write to sites-available and the symlink in sites-enabled already points there
sudo tee /etc/nginx/sites-available/retailedge << 'EOF'
# =============================================================================
# RetailEdge nginx configuration
# Written: Session 6 — TICKET-006
# =============================================================================

# --- HTTPS SERVER BLOCK (primary) -------------------------------------------
server {
    listen 443 ssl;                    # Listen on port 443 with SSL/TLS
    listen [::]:443 ssl;               # Also listen on IP
    http2 on;                          # Enable HTTP/2 (requires ssl)
    server_name _;                     # Match any hostname (use real domain in production)

    # --- Certificate configuration ---
    ssl_certificate     /etc/letsencrypt/live/retailedge-lab/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/retailedge-lab/privkey.pem;

    # --- TLS protocol and cipher hardening (added in Step 6) ---
    # (Deliberately left as a placeholder — we add the hardening directives in Step 6
     so you can see the before/after impact on the configuration)
    include /etc/nginx/snippets/tls-hardening.conf;

    # --- Security headers ---
    # HSTS: tells browsers to only connect via HTTPS for the next 1 year
    # includeSubDomains: also applies to all subdomains
    # preload: allows submission to browser HSTS preload lists
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # Prevent the browser from MIME-sniffing a response away from the declared content-type
    add_header X-Content-Type-Options "nosniff" always;

    # Prevent this site from being embedded in iframes on other domains (clickjacking protection)
    add_header X-Frame-Options "SAMEORIGIN" always;

    # Enable browser's built-in XSS protection (legacy browsers; modern browsers use CSP)
    add_header X-XSS-Protection "1; mode=block" always;

    # Logging
    access_log /var/log/nginx/retailedge-access.log;
    error_log  /var/log/nginx/retailedge-error.log;

    # --- Proxy to myapp ---
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # $scheme will now be 'https' — the application can use this
        # to generate correct absolute URLs in responses

        # Timeout settings — important for preventing hung connections
        proxynect_timeout 30s;
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;
    }
}

# --- HTTP REDIRECT BLOCK (added in Step 5) ----------------------------------
# This block is completed in Step 5 below.
EOF

echo "HTTPS server block written — do not reload nginx yet (redirect block incomplete)"
```

> **Why `http2 on` is correct in modern nginx:** In nginx versions before 1.25.1, HTTP/2 was enabled with `listen 443 ssl http2;`. From nginx 1.25.1+ (which ships in Ubuntu 24.04), the `http2 o directive is the correct approach. Ubuntu 22.04 ships nginx 1.18.x, so technically `listen 443 ssl http2;` is correct here, but writing `http2 on;` separately is forward-compatible. Check your version with `nginx -v` and adjust accordingly. This is the kind of version-specific nuance that trips up engineers who copy configs without understanding them.

---

## Step 5 — Configure the HTTP→HTTPS Redirect

**What we are doing and why:**

HTTP port 80 must remain open for two reasons: the HTTP-01 ACME chale (Let's Encrypt verification) uses port 80, and users who type the URL without `https://` or click old bookmarks will use HTTP. Rather than serving content over HTTP, we redirect every HTTP request to the HTTPS equivalent using a 301 (permanent) redirect.

A 301 redirect tells the browser (and search engines) that this resource has permanently moved. Browsers and search engine crawlers cache 301 redirects, which means future requests skip the HTTP step entirely. A 302 (temporary) redirect would not be cached and would add latency on every subsequent visit.

```bash
# Append the HTTP redirect block to the existing configuration file
sudo tee -a /etc/nginx/sites-available/retailedge << 'EOF'

# --- HTTP REDIRECT BLOCK ---
server {
    listen 80;                   # Listen on port 80 (IPv4)
    listen [::]:80;              # Listen on port 80 (IPv6)
    server_name _;               # Match any hostname

    # Special location for Let's Encrypt ACME challenge
    # Certbot places a temporary file here during certificate issuance/renewal
    # This must NOT be redirected to HTTPS — the challenge uses plain HTTP
    location /.well-known/acme-challenge/ {
        root /var/www/html;      # Certbot writes the challenge file here
    }

    # Redirect all other HTTP traffic to HTTPS
    # $host preserves the original domain name in the redirect
    # $request_uri preserves the path and query string
    # 301 = Moved Permanently (cached by browsers and crawlers)
    location / {
        return 301 https://$host$reque_uri;
    }
}
EOF

# Test the complete nginx configuration (both server blocks)
sudo nginx -t
# Expected output:
# nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
# nginx: configuration file /etc/nginx/nginx.conf test is successful

# Reload nginx gracefully — this applies the new config without dropping existing connections
# 'reload' sends SIGHUP to the master process; it spawns new workers with the new config
# and gracefully shuts down old workers after their connections complete
# 'rtart' would immediately terminate all connections — avoid in production
sudo systemctl reload nginx

echo "nginx reloaded with HTTPS and redirect configuration"
```

> **`reload` vs `restart` — a career-defining distinction:** In production, running `systemctl restart nginx` during business hours can drop active HTTP connections (file downloads, API calls, websocket sessions). `systemctl reload nginx` sends a SIGHUP signal that nginx handles gracefully: it spawns new worker processes with the new configion while existing workers finish serving their in-flight requests. Always use `reload` for configuration changes. Reserve `restart` for cases where nginx has crashed or the binary has been upgraded. This distinction appears in job interviews for senior Linux engineering roles.

---

## Step 6 — Harden the TLS Configuration

**What we are doing and why:**

Obtaining a certificate is the beginning, not the end. The default TLS configuration nginx ships with supports older, insecure TLS versions (TLS 1.0, T 1.1) and weak cipher suites for backward compatibility. PCI-DSS v4.0 mandates TLS 1.2 minimum. A hardened configuration disables old protocols, orders cipher suites to prefer those providing forward secrecy, and adds OCSP stapling to reduce the latency of certificate revocation checks.

We will write these directives into a reusable snippet, a separate file that can be included in any nginx server block. This is the correct pattern: the hardening parameters are the same for every HTTPS site on this server, so they belong in one place rather than duplicated across every server block.

```bash
# Create the snippets directory if it doesn't exist
sudo mkdir -p /etc/nginx/snippets

# Write the TLS hardening snippet
sudo tee /etc/nginx/snippets/tls-hardening.conf << 'EOF'
# =============================================================================
# TLS hardening configuration —  CFE Lab
# Include this file in every HTTPS server block:
#   include /etc/nginx/snippets/tls-hardening.conf;
# ===========================================================================

# --- Protocol versions ---
# Disable TLS 1.0 and 1.1 (deprecated, vulnerable to BEAST, POODLE attacks)
# PCI-DSS v4.0 requires TLS 1.2 minimum; TLS 1.3 is preferred
ssl_protocols TLSv1.2 TLSv1.3;

# --- Cipher suites ---
# Specify the cipher suites nginx will accept, in preference order
# ECDHE: Elliptic Curve Diffie-Hellman Ephemeral — provides forward secrecy
# AES-GCM: Authenticated encryption — provides both confidentiality and integrity
# SH/SHA384: Secure hash algorithms for MAC
# !RC4, !3DES: Explicitly disable known-weak ciphers
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:!RC4:!aNULL:!eNULL:!EXPORT:!DES:!3DES:!MD5:!PSK';

# --- Server cipher preference ---
# nginx chooses the cipher from its list, not the client's list
# This ensures weak client cipher preferences don't downgrade the session
ssl_prefer_server_ciphers on;

# --- Diffie-Hellman parameters ---
# Use the custom DH params file generated in Step 3
# The default 1024-bit DH params are considered weak (Logjam attack)
ssl_dhparam /etc/ssl/certs/dhparam.pem;

# --- Session resumption ---
# SSL session cache reduces handshake overhead for returning clients
# shared: shares the cache across all nginx worker processes
# 10m: 10 megabytes of cache storage (~40,000 sessions)
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;         # Sessions expire after 1 day

# Disable session tickets (they can reduce forward secrecy if the ticket key is compromised)
ssl_session_tickets off;

# --- OCSP Stapling ---
# Without stapling: browser contacts Let's Encrypt's OCSP server to check revocation
# With stapling: nginx fetches and caches the OCSP response, serves it to clients
# This eliminates the extra round-trip latency for the client
ssl_stapling on;
ssl_stapling_verify on;

# The trusted certificate chain for OCSP response verification
# For Let's Encrypt, fullchain.pem includes the intermediate certificate
ssl_trusted_certificate /etc/letsencrypt/live/retailedge-lab/fullchain.pem;

# DNS resolver for OCSP stapling lookups (Google's public DNS)
# Without this, nginx cannot resolve the OCSP server's hostname
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
EOF

# Verify the snippet file was written correctly
cat /etc/nginx/snippets/tls-hardening.conf | grep ssl_protocols
# Expected: ssl_protocols TLSv1.2 TLSv1.3;

# Test the configuration — the HTT server block already includes this snippet
sudo nginx -t

sudo systemctl reload nginx

echo "TLS hardening applied via /etc/nginx/snippets/tls-hardening.conf"
```

**Before vs After — TLS protocol and cipher comparison:**

| Parameter | Before (default) | After (hardened) |
|---|---|---|
| Protocols | TLS 1.0, 1.1, 1.2 | TLS 1.2, 1.3 only |
| Forward secrecy | Partial | All cipher suites use ECDHE/DHE |
| Weak ciphers | RC4, DES available | Explicitly disabled |
| DH key size | 1024-bit (default) | 2048-t (custom params) |
| Session tickets | On | Off (preserves forward secrecy) |
| OCSP stapling | Off | On (reduces client latency) |
| HSTS | Off | 1 year, includeSubDomains |

> **Why HSTS is a one-way door:** Once you add the HSTS header with a long `max-age`, browsers cache it and refuse to connect via HTTP for that duration, even if you remove the header later. A client that has seen the header will not allow HTTP connections for `max-age` seconds. This is intentional for production (it prevents SSL stripping attacks) but can be awkward in development. In a lab or staging environment, use a short `max-age=300` initially to avoid locking yourself out while iterating.

---

## Step 7 — Replace the Certbot Cron with a systemd Timer

**What we are doing and why:**

When Certbot is installed via apt on Ubuntu, it automatically creates a cron job in `/etc/cron.d/certbot` that runs `certbot renew` twice daily. Cron works, but systemd timers are the modern, auditable alternative. Timers integrate with `journald(so their output is queryable with `journalctl`), support monotonic clocks (run X hours after boot, not at a fixed clock time), and appear in `systemctl list-timers` alongside all other timers in the system, giving you a single dashboard of scheduled work.

Certbot's apt package on Ubuntu 22.04 also ships a systemd timer (`certbot.timer`) that coexists with the cron job. We will confirm the systemd timer is active and disable the legacy cron to avoid double-renewal attempts.

```bash
# Check whether Certbot's systemd timer is already present
systemctl list-timers --all | grep certbot
# Expected output:
# certbot.timer   active waiting   certbot.service   ...

# Examine the timer unit to understand its schedule
systemctl cat certbot.timer
# You will see: OnCalendar=*-*-* 00,12:00:00
# This means: every day at midnight and noon

# Examine the service the timer invokes
systemctl cat certbot.service
# Key line: ExecStart=/usr/bin/certbot -q renew
# -q = quiet mode (only outputs on error)

# Disable the legacy cron job to prevent double-renewals
# The cron job lives in /etc/cron.d/certbot
if [ -f /etc/cron.d/certbot ]; then
    sudo mv /etc/cron.d/certbot /etc/cron.d/certbot.disabled
    echo "Legacy Certbot cron job disabled"
else
    echo "No legacy cron job found — systemd timer is the only renewal mechanism"
fi

# Ensure the systemd timer is enabled and running
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer

# Verify the timer is active
systemctl status certbot.timer
# Expected: Active:ctive (waiting)

# Run a renewal dry-run to confirm the renewal process works
# --dry-run: goes through the full renewal process but does not write any files
# This is the correct way to test renewal without wasting rate-limit quota
sudo certbot renew --dry-run
```

> **Let's Encrypt rate limits and the staging environment:** Let's Encrypt's production API enforces rate limits: 50 certificates per registered domain per week, and 5 failed validations per hour. In a real engagement, if you are iterating on certificate configuration, use `--staging` to test against Let's Encrypt's staging environment (no rate limits, but the certificate is not trusted). Only switch to production (`--force-renewal`) once you are confident the configuration is correct. Burning rate limit quota during development is a common and embarrassing mistake.

```bash
# Show all active timers — confirms certbot.timer appears alongside system timers
systemctl list-timers --all
```

Expected output excerpt:
```
NEXT                        LT          LAST                        PASSED    UNIT                     ACTIVATES
[date] 00:00:00 UTC         Xh left       [date] 12:00:00 UTC         Xh ago    certbot.timer            certbot.service
[date] ...                  ...           ...                         ...       systemd-tmpfiles-...     ...
```

---

## Step 8 — Validate with openssl and curl

**What we are doing and why:**

Configuring nginx to serve HTTPS is not the same as verifying HTTPS actually works. Two tools give you immedia, detailed feedback without needing a browser: `openssl s_client` and `curl`. These tools are universally available and produce output you can grep, pipe, and include in handover documentation. A CFE validates every change at the command line before declaring the ticket resolved.

```bash
# Test 1: Verify the TLS handshake and inspect the certificate
# openssl s_client opens a raw TLS connection and prints the handshake details
sudo openssl s_client \
    -connect localhost:443 \     # Connect to the local nginx on port 443
    -servername localhost \      # SNI (Server Name Indication) field — required for vhosts
    -showcerts \                 # Print the full certificate chain
    < /dev/null                  # Feed empty input so the command exits immediately

    sudo openssl s_client -connect localhost:443 -servername localhost -showcerts < /dev/null
# Look for:
#   Protocol: TLSv1.3 (or TLSv1.2)
#   Cipher: TLS_AES_256_GCM_SHA384 (or similar ECDHE cipher)
#   subject=C = GB, ..., CN = retailedge-lab   Verify return code: 18 (self signed certificate)  ← expected for self-signed

# Test 2: Verify the HTTP→HTTPS redirect
# -I: fetch headers only (HEAD request)
# -L: follow redirects (so we can see the chain)
# -v: verbose output including redirect chain
curl -Iv http://localhost/
# Look for:
#   HTTP/1.1 301 Moved Permanently
#   Location: https://localhost/

# Test 3: Verify HTTPS responds with application content
# -k / --insecure: skip certificate verification (required for self-signed certs)
# -vrbose (shows TLS handshake details)
curl -kv https://localhost/
# Look for:
#   SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
#   HTTP/1.1 200 OK
#   RetailEdge myapp OK

# Test 4: Verify security headers are present
curl -k -I https://localhost/ | grep -E "Strict-Transport|X-Content-Type|X-Frame"
# Expected:
#   Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
#   X-Content-Type-Options: nosniff
#   X-Frame-Options: SAMEORIGIN

# Test 5: Verify the TLS protocol version negotiation
# Check that TLS 1.1 is rejected
sudo openssl s_client \
    -connect localhost:443 \
    -tls1_1 \                    # Force TLS 1.1
    < /dev/null 2>&1 | grep -E "Protocol|no protocols"
# Expected: "no protocols available" or a handshake error
# This confirms TLS 1.0/1.1 are disabled as configured

# Test 6: Verify nginx is listening on both 80 and 443
sudo ss -tlnp | grep nginx
# Expected:
#   LISTEN 0 511 0.0.0.0:443 ... nginx
#   LISTEN 0 511 0.0.0.0:80  ... nginx
```

> **`openssl s_client` is your TLS Swiss Army knife:** This tool is available on every Linux, macOS, and most BSD systems. It can connect to any TLS endpoint, negotiate specific protocol versions, show the full certificate chain, and test mutual TLS (client certificates). Every field engineer should be comfortable reading its output. The `Verify return code: 18 (self signed certificate)` you see here is normal and expected; in production with a real Let's Encrypt certificate, you will see `Verify return code: 0 (ok)`.

---

## Step 9 — Update UFW for Port 443

**What we are doing and why:**

The AWS Security Group (Terraform) controls traffic at the VPC network level. UFW controls traffic at the OS level. Both must allow port 443, a packet that passes the security group is still dropped by UFW if UFW does not permit it. This defence-in-depth is intentional: two independent layers of firewall mean a misconfiguration in one does not expose the service.

Remember that `/usr/local/bin/configure-firewall.sh` is the authoritative source  UFW rules for this server. We update that script, then re-run it, rather than running `ufw allow 443` interactively. Interactive commands produce undocumented state changes that are invisible to the next engineer and lost on server rebuild.

```bash
# Update the firewall configuration script to include port 443
# We use sed to insert the new rule after the HTTP rule
sudo sed -i \
    '/ufw allow 80\/tcp/a ufw allow 443\/tcp comment '"'"'HTTPS'"'"'' \
    /usr/local/bin/configure-firewall.sh
# -i: edit the file in place
# The sed expression appends the ufw 443 rule on the line after the port 80 rule

# Verify the script now contains the 443 rule
grep "443" /usr/local/bin/configure-firewall.sh
# Expected: ufw allow 443/tcp comment 'HTTPS'

# Re-run the firewall script to apply the change idempotently
sudo bash /usr/local/bin/configure-firewall.sh

# Verify UFW rules include 443
sudo ufw status numbered
# Expected output should include:
#   [ ] 443/tcp                    ALLOW IN    Anywhere
#   [ ] 443/tcp (v6)               ALLOW IN    Anywhere (v6)
```

**Before vs After — UFW rules:**

| Port | Before (Session 4) | After (Session 6) |
|---|---|---|
| 22/tcp | ALLOW (any) | ALLOW (any) |
| 80/tcp | ALLOW (any) | ALLOW (any) — redirect only |
| 443/tcp | **Not present** | **ALLOW (any)** |
| 9100/tcp | ALLOW (ops IP) | ALLOW (ops IP) |

> **Why `configure-firewall.sh` is the right pattern:** In a real engagement you might rebuild this server three times during your engagement, to test a Terraform change, afa botched `apt upgrade`, or simply because the instance type was wrong. Each rebuild would lose any `ufw allow` commands run interactively. By keeping the script as the single source of truth and committing it to Git, the firewall state is reproducible, auditable, and version-controlled. This is the Infrastructure as Code principle applied to OS-level configuration.

---

## Step 10 — Deliver the Handover Document

**What we are doing and why:**

A CFE's work is not complete when the service is running. T client's operations team, security team, and future engineers must understand what was changed, why, and how to roll it back or extend it. This handover document is the professional artefact that transforms a technical task into a client-deliverable.

```bash
# Create the handover document
sudo tee /var/log/myapp/../handover/TICKET-006-handover.md << 'EOF'
# Note: create the directory first
EOF

sudo mkdir -p /opt/retailedge/handover

sudo tee /opt/retailedge/handover/TICKET-006-handover.md << 'EOF'
# Handover Document — TICKET-006
**Prepared by:** Cloud Field Engineer  
**Date:** $(date +%Y-%m-%d)  
**Client:** RetailEdge Ltd  
**Environment:** Ubuntu 22.04 LTS, AWS EC2, eu-west-1  

---

## Summary

TLS termination has been implemented at the nginx reverse proxy layer. The RetailEdge application endpoint is now accessible exclusively via HTTPS on port 443. All plaintext HTTP traffic on port 80 is permanently redirected (HTTP 301) to the HTTPS equivalent. Certificate renewal is automated via a systemd tim.

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
| node_exporter | 9100 (ops IP only) | Active, unmodifie|

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

3. **Allocate an AWS Elastic IP** to this instance to prevent the public IP from changing on next stoptart cycle, which would invalidate the certificate's SAN field.

4. **Submit the domain to the HSTS preload list** (`https://hstspreload.org`) after confirming the configuration is stable — this provides an additional layer of protection for first-time visitors.

5. **Run a full SSL Labs audit** (`https://www.ssllabs.com/ssltest/`) once a real domain is configured to obtain an A or A+ grade for the compliance record.
EOF

echo "Handover document written to /opt/retailedge/handover/TICKET-006-handover.md"
t /opt/retailedge/handover/TICKET-006-handover.md
```

---

## Step 11 — Commit Your Work

```bash
# On your local machine — add and commit all session 6 changes

git add \
    terraform/main.tf \                              # Updated security group (port 443)
    scripts/bootstrap-session6.sh \                  # Session 6 bootstrap script
    nginx/sites-available/retailedge \               # HTTPS + redirect nginx config
    nginx/snippets/tls-hardening.conf \              # TLS hardening snippet
  ripts/configure-firewall.sh \                  # Updated UFW (port 443 added)
    handover/TICKET-006-handover.md                  # Client handover document

git commit -m "Session 6: TLS termination and HTTPS enforcement (TICKET-006)

Implemented full TLS termination at the nginx reverse proxy layer for RetailEdge Ltd.

Changes:
- Added port 443 ingress rule to AWS Security Group in Terraform
- Generated self-signed certificate at /etc/letsencrypt/live/retailedge-lab/ (lab use)
  (production: replace with Let's Encrypt certificate using certbot --nginx)
- Generated 2048-bit DH parameters at /etc/ssl/certs/dhparam.pem
- Rewrote /etc/nginx/sites-available/retailedge:
  - New HTTPS server block on 443: TLS termination, proxy to 127.0.0.1:8080
  - HTTP server block on 80: 301 redirect to HTTPS, ACME challenge passthrough
- Created /etc/nginx/snippets/tls-hardening.conf:
  - TLS 1.2/1.3 only (disables 1.0/1.1 per PCI-DSS v4.0 Req 4.2.1)
  - ECDHE/DHE cipher suites with forward secrecy
  - OCSP stapling enabled
  - HSTS: max-age=31536000; includeSubDomains; preload
- Added HTTPS security headers: HSTS, X-Content-Type-Options, X-Frame-Options, X-XSS-Protection
- Updated configure-firewall.sh: added ufw allow 443/tcp
- Disabled legacy certbot cron job; confirmed certbot.timer active
- Verified: HTTP→HTTPS redirect (301), TLS handshake (TLSv1.3), security headers
- Delivered TICKET-006 handover document with rollback instructions

Resolves: TICKET-006
PCI-DSS: Addresses Requirement 4.2.1 (strong cryptography for datin transit)"
```

---

## Verification Checklist

Run these commands after completing all steps. Each command, expected output, and what it confirms is listed.

```bash
# 1. nginx is running and listening on 443 and 80
sudo systemctl is-active nginx
# Expected: active

sudo ss -tlnp | grep ':443\|:80'
# Expected: LISTEN entries for 0.0.0.0:443 and 0.0.0.0:80

# 2. TLS handshake succeeds and certificate is visible
echo | sudo openssl s_client -connect localhost:443 -servername localhost 2>/dev/null \
    | openssl x509 -noout -subject -dates
# Expected: subject=.../CN=retailedge-lab, with valid notBefore/notAfter dates

# 3. HTTP redirects to HTTPS (301)
curl -Is http://localhost/ | head -3
# Expected:
#   HTTP/1.1 301 Moved Permanently
#   Location: https://localhost/

# 4. HTTPS returns 200 from myapp
curl -ks https://localhost/
# Expected: RetailEdge myapp OK

# 5. Security headers are present
curl -ks -I https://localhost/ | grep -c "Strict-Transport\|X-Content-Type\|X-Frame"
# Expected: 3

# 6. TLS 1.1 is rejected
echo | sudo openssl s_client -connect localhost:443 -tls1_1 2>&1 | grep -i "alert\|error\|protocol"
# Expected: error or protocol_version alert

# 7. Certbot timer is active
systemctl is-active certbot.timer
# Expected: active

# 8. Renewal dry-run succeeds
sudo certbot renew --dry-run 2>&1 | tail -5
# Expected: "No renewals were attempted" or "Congratulations, all renewals succeeded"

# 9. UFW allows 443
sudo ufw status | grep 443
# Expected: 443/tcp    ALLOW IN    Anywhere

# 10. myapp is still running (regression check)
systemctl is-active myapp
# Expected: active

# 11. node_exporter is still running (regression check)
systemctl is-active node_exporter
# Expected: active

# 12. Port 9100 is not accessible from outside the ops IP
# From a non-ops machine:
curl -s --connect-timeout 3 http://<SERVER_IP>:9100/metrics
# Expected: connection timeout (UFW and SG blocking)
```

---

## Troubleshooting Reference

| Symptom | Diagnostic Command | Fix |
|---|---|---|
| `nginx -t` fails with "cannot load certificate" | `ls -la /etc/letsencrypt/live/retailedge-lab/` | Verify self-signed cert was generated in Step 3; re-run openssl req command |
| Port 443 connection refused | `sudo ss -tlnp \| grep 443` | nginx not listening; check `nginx -t` and `systemctl status nginx` |
| HTTP not redirecting (returns 200 instead of 301) | `curl -Iv http://localhost/` | Check port 80 server block has `return 301` not `proxy_pass` |
| HTTPS returns nginx default page, not myapp | `sudo nginx -T \| grep proxy_pass` | Check HTTPS server block has correct `proxy_pass http://127.0.0.1:8080;` |
| curl SSL error: "certificate verify failed" | `curl -k https://localhost/` | Expected for self-signed cert; use `-k` flag or add cert to local trust store |
| TLS 1.2/1.3 negotiation failing | `openssl s_client -connect localhost:443 -debug` | Check `ssl_protocols` in tls-hardening.conf; verify file is included in server block |
| certbot.timer inactive | `systemctl status certbot.timer` | `sudo systemctl enable --now certbot.timer` |
| certbot renew dry-run fails: "Connection refused" | `sudo ufw status \| grep 80` | Port 80 must be open for ACME HTTP-01 challenge; verify UFW and SG allow port 80 |
| UFW blocks 443 despite ufw allow | `sudo ufw status verbose` | Re-run `configure-firewall.sh`; check script was saved correctly |
| myapp not responding after nginx reload | `systemctl status myapp` | `sudo systemctl restart myapp` |
| Bootstrap script exits early on LVM phase | `lsblk` | Attach second EBS volume in AWS console before running bootstrap |
| `dhparam.pem` generation hung | `ps aux \| grep openssl` | Normal — wait 60s; generation requires entropy. Run `sudo apt install rng-tools && sudo rngd -r /dev/urandom` to speed up if needed |
| Security headers missing from curl output | `curl -k -I https://localhost/` | Verify `add_header` directives are inside the HTTPS server block, not the HTTP block |

---

## What You Learned This Session

Each skill below is framed as a career asset for a Canonical Cloud Field Engineer:

**TLS architeure at the proxy layer.** You can now explain why TLS is terminated at nginx rather than inside the application, and articulate the trade-offs of this pattern versus end-to-end encryption. This is asked in technical interviews for senior Linux and cloud engineering roles, and comes up in virtually every engagement involving web services.

**Certificate lifecycle management.** You understand the difference between self-signed certificates, Let's Encrypt staging, and production certificates, and you know when to use each. You can set up Certbot, interpret ACME challenge mechanics, and explain why HTTP-01 requires port 80 to be open even for an HTTPS-only service.

**Hardened TLS configuration.** You can write an nginx TLS configuration that disables deprecated protocols, enforces forward secrecy, enables OCSP stapling, and sets HSTS. You can explain what each directive does and why it matters for PCI-DSS compliance — not just recite the configuration from memory.

**systemd timers as a cron replacement.** Youan explain the operational advantages of systemd timers over cron (journald integration, `systemctl list-timers` visibility, monotonic clock support) and migrate an existing cron job to a timer. This is a modern Linux systems skill that differentiates engineers who understand the systemd ecosystem from those who just use it.

**Idiomatic nginx configuration.** You understand the server block model, the difference between `reload` and `restart`, and why configuration snippets (`include`) are the correct pattern for shared directives. You can write, test, and reload nginx configurations safely in production.

**Security header implementation.** You can implement HSTS, X-Frame-Options, X-Content-Type-Options, and X-XSS-Protection at the reverse proxy layer, and explain what each header protects against — a common client request and a frequent topic in security-focused engagements.

---

## Go Deeper

1. **What is the difference between `ssl_certificate` and `ssl_trusted_certificate` in nginx?** When would you ed to specify both? Research the OCSP stapling verification chain and how `ssl_trusted_certificate` fits into it.

2. **Let's Encrypt issues certificates valid for 90 days — why not longer?** Research the reasoning behind Let's Encrypt's 90-day validity period and how it relates to certificate revocation and the OCSP/CRL problem. Consider: what would happen if a private key were compromised and certificates lasted 2 years?

3. **What is the difference between HTTP Strict Transport Security (HSTS) and certicate pinning?** Why is pinning generally discouraged for public web services? When might you use it anyway?

4. **Read the nginx documentation on `ssl_session_tickets` and `ssl_session_cache`.** Why do session tickets potentially reduce forward secrecy? What key rotation policy would you implement for session ticket keys in a high-security environment?

5. **Explore the Mozilla SSL Configuration Generator (`https://ssl-config.mozilla.org/`).** Compare the "Modern", "Intermediate", and "Old" configuration profiles. Which would you recommend for a PCI-DSS environment running a publicly accessible e-commerce site? What trade-offs does each make with browser compatibility?

6. **Investigate AWS Certificate Manager (ACM) and ALB-based TLS termination.** How does this pattern differ from the nginx-based approach you implemented today? In what scenarios would you choose ACM+ALB over Certbot+nginx, and vice versa? Consider: cost, operational overhead, custom cipher control, and non-HTTP protocols (e.g. MQTT, raw TCP).

**Recommended reading:**
- Mozilla's TLS Observatory and SSL Configuration Generator: `https://ssl-config.mozilla.org/`
- Let's Encrypt documentation on ACME challenges: `https://letsencrypt.org/docs/challenge-types/`
- NGINX documentation on `ngx_http_ssl_module`: `https://nginx.org/en/docs/http/ngx_http_ssl_module.html`
- PCI-DSS v4.0 Requirement 4.2 (available via PCI SSC): focus on the specific TLS version and cipher requirements

---



