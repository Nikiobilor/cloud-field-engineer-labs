# Session 9 — DNS-Based Service Discovery with Route53 Private Hosted Zones

---

## 🎫 Ticket

```
TICKET ID:    TICKET-009
Priority:     High
Client:       RetailEdge Ltd
Environment:  AWS EC2 — Ubuntu 22.04 LTS, eu-west-2 (or your configured region)
Subject:      Services hardcoded to IP addresses break on every instance replacement
              — implement DNS-based service discovery via Route53 private hosted zone

Description:
  RetailEdge's internal services (nginx reverse proxy, myapp API, node_exporter)
  currently reference each other using hardcoded IP addresses stored in config
  files and /etc/hosts. Each time an EC2 instance is replaced (which occurs every
  session in this lab, and will occur in production during blue/green deployments,
  Auto Scaling events, and failure recovery), every IP reference must be manually
  updated across all configs. This is operationally fragile and does not scale.

  The platform team wants services to reference each other by DNS name
  (e.g. api.retailedge.internal, web.retailedge.internal) so that DNS resolves
  automatically to the correct IP regardless of which instance is running.

  Root cause: the VPC has no private hosted zone configured. Engineers do not
  understand how /etc/resolv.conf, the VPC resolver, and Route53 private hosted
  zones interact. A second gap is conceptual: the team conflates public DNS,
  private DNS, and split-horizon DNS.

Acceptance Criteria:
  ✅ Terraform module at terraform/modules/dns/ with variables.tf and outputs.tf
  ✅ Route53 private hosted zone retailedge.internal associated with the Session 8 VPC
  ✅ A record: web.retailedge.internal → web EC2 private IP
  ✅ A record: api.retailedge.internal → app tier private IP (placeholder)
  ✅ CNAME record: internal.retailedge.internal → web.retailedge.internal
  ✅ dig and nslookup resolve all three records from inside the EC2 instance
  ✅ Engineer can explain why the same names do not resolve from outside the VPC
  ✅ /etc/hosts hardcoded IP entries removed; resolution is DNS-driven
  ✅ AWS Console verification of hosted zone and records documented
  ✅ Handover document delivered to RetailEdge platform team
```

---

## 🎯 Session Goals

By the end of this session you will be able to:

1. Explain how DNS resolution works on an AWS VPC instance — from `/etc/resolv.conf` through `systemd-resolved` to the VPC resolver at the base-plus-two address.
2. Create a Route53 private hosted zone using Terraform and associate it with a VPC.
3. Write A records and CNAME records in Terraform using the `aws_route53_record` resource.
4. Resolve internal DNS names using `dig` and `nslookup` from inside an EC2 instance.
5. Explain split-horizon DNS and articulate why it matters for internal service architectures.
6. Explain TTL trade-offs in a cloud environment where instance IPs change frequently.
7. Describe the difference between DNS-based service discovery and a full service mesh, and when you would recommend each to a client.

---

## 📋 Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Session Bootstrap](#session-bootstrap)
   - [Phase 1 — Terraform: Add the DNS Module](#phase-1--terraform-add-the-dns-module)
   - [Phase 2 — bootstrap-session9.sh](#phase-2--bootstrap-session9sh)
   - [Phase 3 — Running the Script](#phase-3--running-the-script)
   - [Phase 4 — Update GitHub Secrets](#phase-4--update-github-secrets)
3. [Prerequisites](#prerequisites)
4. [Step 1 — Understand the Problem: Why Hardcoded IPs Break](#step-1--understand-the-problem-why-hardcoded-ips-break)
5. [Step 2 — How DNS Resolution Works on an AWS VPC Instance](#step-2--how-dns-resolution-works-on-an-aws-vpc-instance)
6. [Step 3 — What Is a Route53 Private Hosted Zone?](#step-3--what-is-a-route53-private-hosted-zone)
7. [Step 4 — Split-Horizon DNS Explained](#step-4--split-horizon-dns-explained)
8. [Step 5 — TTL Values: Trade-offs in a Cloud Environment](#step-5--ttl-values-trade-offs-in-a-cloud-environment)
9. [Step 6 — Write the Terraform DNS Module](#step-6--write-the-terraform-dns-module)
10. [Step 7 — Integrate the DNS Module into Root Configuration](#step-7--integrate-the-dns-module-into-root-configuration)
11. [Step 8 — Apply the Terraform Changes](#step-8--apply-the-terraform-changes)
12. [Step 9 — Verify DNS Resolution from Inside the Instance](#step-9--verify-dns-resolution-from-inside-the-instance)
13. [Step 10 — Verify from the AWS Console](#step-10--verify-from-the-aws-console)
14. [Step 11 — Remove the /etc/hosts Hardcoded Entries](#step-11--remove-the-etchosts-hardcoded-entries)
15. [Step 12 — Confirm End-to-End Service Connectivity by Name](#step-12--confirm-end-to-end-service-connectivity-by-name)
16. [Step 13 — Handover Document](#step-13--handover-document)
17. [Step 14 — Commit Your Work](#step-14--commit-your-work)
18. [Verification Checklist](#verification-checklist)
19. [Troubleshooting Reference](#troubleshooting-reference)
20. [What You Learned This Session](#what-you-learned-this-session)
21. [Go Deeper](#go-deeper)
22. [Next Session](#next-session)

---

## Architecture Overview

```
                          ┌─────────────────────────────────────────────────┐
                          │                  AWS Account                     │
                          │                                                  │
                          │   ┌─────────────────────────────────────────┐   │
                          │   │         Route53 Private Hosted Zone      │   │
                          │   │           retailedge.internal            │   │
                          │   │                                          │   │
                          │   │  web.retailedge.internal   A → 10.0.1.x │   │
                          │   │  api.retailedge.internal   A → 10.0.2.x │   │
                          │   │  internal.retailedge.internal            │   │
                          │   │              CNAME → web.retailedge...   │   │
                          │   └──────────────────┬──────────────────────┘   │
                          │                      │ associated with           │
                          │   ┌──────────────────▼──────────────────────┐   │
                          │   │             VPC 10.0.0.0/16              │   │
                          │   │                                          │   │
                          │   │  VPC Resolver: 10.0.0.2 (base+2)        │   │
                          │   │  (also reachable at 169.254.169.253)     │   │
                          │   │                                          │   │
                          │   │  ┌────────────────────────────────────┐ │   │
                          │   │  │     Public Subnet 10.0.1.0/24      │ │   │
                          │   │  │                                    │ │   │
                          │   │  │  ┌──────────────────────────────┐ │ │   │
                          │   │  │  │     EC2 (Ubuntu 22.04)       │ │ │   │
                          │   │  │  │  eth0: 10.0.1.x              │ │ │   │
                          │   │  │  │                              │ │ │   │
                          │   │  │  │  systemd-resolved            │ │ │   │
                          │   │  │  │    ↓ queries                 │ │ │   │
                          │   │  │  │  /etc/resolv.conf            │ │ │   │
                          │   │  │  │  nameserver 127.0.0.53       │ │ │   │
                          │   │  │  │    ↓ forwarded to            │ │ │   │
                          │   │  │  │  VPC Resolver 10.0.0.2       │ │ │   │
                          │   │  │  │    ↓ answered from           │ │ │   │
                          │   │  │  │  Route53 private zone        │ │ │   │
                          │   │  │  │                              │ │ │   │
                          │   │  │  │  nginx :443 → :8080          │ │ │   │
                          │   │  │  │  myapp :8080                 │ │ │   │
                          │   │  │  │  node_exporter :9100         │ │ │   │
                          │   │  │  └──────────────────────────────┘ │ │   │
                          │   │  └────────────────────────────────────┘ │   │
                          │   │                                          │   │
                          │   │  ┌────────────────────────────────────┐ │   │
                          │   │  │    Private Subnet 10.0.2.0/24      │ │   │
                          │   │  │    (no IGW route — isolated)       │ │   │
                          │   │  └────────────────────────────────────┘ │   │
                          │   └──────────────────────────────────────────┘   │
                          │                                                  │
                          │   ┌──────────────────────────────────────────┐   │
                          │   │        S3 Backend + Lock File             │   │
                          │   │  (Terraform 1.10 native locking)         │   │
                          │   └──────────────────────────────────────────┘   │
                          └─────────────────────────────────────────────────┘

  Internet (external resolver)
  ─── dig web.retailedge.internal ──→  NXDOMAIN (zone is private; not visible)

  EC2 inside VPC
  ─── dig web.retailedge.internal ──→  10.0.1.x (answered from Route53 private zone)
```

**Why this architecture matters for a CFE:**
Route53 private hosted zones are the AWS-native answer to internal service discovery. They are free when associated with a VPC in the same account, require no additional infrastructure, and integrate directly into the VPC resolver every EC2 instance already uses. Understanding the full resolution chain, from the application's DNS query through `systemd-resolved` to the VPC resolver to Route53, is essential for diagnosing DNS failures in production, and is the knowledge that separates engineers who can configure DNS from those who can explain it to a client.

---

## Session Bootstrap

### Phase 1 — Terraform: Add the DNS Module

The DNS module will be wired into the root `main.tf` after you write it in Step 6 and Step 7. Before running the bootstrap, make sure your Terraform root configuration includes the changes from Sessions 1–8. The DNS module changes are applied in Step 8 after the bootstrap has run.

The only Terraform change needed **before** the bootstrap is confirming the Session 8 VPC module is intact. The bootstrap reads the Terraform state to install the right packages, it does not apply DNS changes itself.

No new Terraform blocks are needed in Phase 1. DNS module blocks are introduced in Step 6.

---

### Phase 2 — bootstrap-session9.sh

Save this file as `bootstrap-session9.sh` on your local machine. It will be SCP'd to the instance in Phase 3.

```bash
#!/usr/bin/env bash
# =============================================================================
# bootstrap-session9.sh
# Canonical CFE Training Series — Session 9
# Cumulative bootstrap: rebuilds Sessions 1-8 state then introduces the
# broken state for Session 9 (hardcoded IP entries in /etc/hosts).
#
# Run as: sudo bash bootstrap-session9.sh
# Expected runtime: 4-7 minutes on a t2.micro with a cold apt cache
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIABLES
# Replace OPS_IP with your actual ops IP before running, or export it
# as an environment variable before calling this script.
# -----------------------------------------------------------------------------
OPS_IP="${OPS_IP:-0.0.0.0/0}"
INSTANCE_PRIVATE_IP=$(hostname -I | awk '{print $1}')
LAB_USER="ubuntu"
LAB_HOME="/home/${LAB_USER}"

echo "============================================================"
echo " CFE Session 9 Bootstrap"
echo " Instance private IP: ${INSTANCE_PRIVATE_IP}"
echo " OPS_IP: ${OPS_IP}"
echo "============================================================"

# =============================================================================
# SESSION 1 — Kernel tuning, node_exporter
# =============================================================================

echo "[Session 1] Applying kernel tuning parameters..."

cat > /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
# Canonical CFE Lab — kernel tuning
# Increase the maximum number of open file descriptors
fs.file-max = 100000
# Reduce swappiness to prefer RAM over swap
vm.swappiness = 10
# Enable TCP SYN cookies to defend against SYN flood attacks
net.ipv4.tcp_syncookies = 1
# Increase TCP receive and send buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

sysctl --system > /dev/null 2>&1

echo "[Session 1] Installing node_exporter..."

NODE_EXPORTER_VERSION="1.7.0"
NODE_EXPORTER_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

if ! id -u node_exporter > /dev/null 2>&1; then
  useradd --system --no-create-home --shell /bin/false node_exporter
fi

if [ ! -f /usr/local/bin/node_exporter ]; then
  cd /tmp
  wget -q \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_ARCHIVE}"
  tar xzf "${NODE_EXPORTER_ARCHIVE}"
  cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" \
    /usr/local/bin/node_exporter
  chown node_exporter:node_exporter /usr/local/bin/node_exporter
  rm -rf \
    "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" \
    "/tmp/${NODE_EXPORTER_ARCHIVE}"
fi

cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter > /dev/null 2>&1 || true

echo "[Session 1] node_exporter running."

# =============================================================================
# SESSION 3 — myapp.service, journald, logrotate, rsyslog, cron alert
# =============================================================================

echo "[Session 3] Installing myapp..."

apt-get update -qq
apt-get install -yq python3 rsyslog logrotate > /dev/null 2>&1

mkdir -p /opt/myapp /var/log/myapp

cat > /opt/myapp/app.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"RetailEdge myapp OK\n")
    def log_message(self, fmt, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 8080), Handler) as httpd:
    httpd.serve_forever()
EOF

cat > /etc/systemd/system/myapp.service << 'EOF'
[Unit]
Description=RetailEdge myapp service
After=network.target

[Service]
User=ubuntu
ExecStart=/usr/bin/python3 /opt/myapp/app.py
Restart=on-failure
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/log/journal
sed -i 's/^#Storage=.*/Storage=persistent/' /etc/systemd/journald.conf || \
  echo "Storage=persistent" >> /etc/systemd/journald.conf
sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf || \
  echo "SystemMaxUse=500M" >> /etc/systemd/journald.conf
sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=1month/' /etc/systemd/journald.conf || \
  echo "MaxRetentionSec=1month" >> /etc/systemd/journald.conf

cat > /etc/logrotate.d/myapp << 'EOF'
/var/log/myapp/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    postrotate
        systemctl kill --kill-who=main --signal=HUP myapp.service 2>/dev/null || true
    endscript
}
EOF

cat > /etc/rsyslog.d/49-myapp.conf << 'EOF'
if $programname == 'myapp' then /var/log/myapp/myapp.log
& stop
EOF

cat > /usr/local/bin/myapp-alert.sh << 'EOF'
#!/usr/bin/env bash
if ! systemctl is-active --quiet myapp.service; then
  echo "[ALERT] myapp.service is not running on $(hostname)" \
    >> /var/log/myapp/alerts.log
fi
EOF

chmod +x /usr/local/bin/myapp-alert.sh

TMPFILE=$(mktemp)
crontab -l 2>/dev/null | grep -v "myapp-alert" > "${TMPFILE}" || true
echo "*/5 * * * * /usr/local/bin/myapp-alert.sh" >> "${TMPFILE}"
crontab "${TMPFILE}"
rm -f "${TMPFILE}"

systemctl daemon-reload
systemctl enable --now myapp.service > /dev/null 2>&1 || true
systemctl restart rsyslog > /dev/null 2>&1 || true

echo "[Session 3] myapp running."

# =============================================================================
# SESSION 4 — nginx reverse proxy, ufw
# =============================================================================

echo "[Session 4] Installing nginx and configuring ufw..."

apt-get install -yq nginx ufw tcpdump > /dev/null 2>&1

cat > /etc/nginx/sites-available/retailedge << 'EOF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/retailedge \
  /etc/nginx/sites-enabled/retailedge > /dev/null 2>&1 || true
rm -f /etc/nginx/sites-enabled/default > /dev/null 2>&1 || true

cat > /usr/local/bin/configure-firewall.sh << EOF
#!/usr/bin/env bash
set -euo pipefail
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow from ${OPS_IP} to any port 9100 proto tcp
ufw allow in on lo
ufw --force enable
EOF

chmod +x /usr/local/bin/configure-firewall.sh
bash /usr/local/bin/configure-firewall.sh > /dev/null 2>&1 || true

systemctl enable --now nginx > /dev/null 2>&1 || true

echo "[Session 4] nginx and ufw configured."

# =============================================================================
# SESSION 5 — LVM for /var/log/myapp
# =============================================================================

echo "[Session 5] Checking LVM setup..."

apt-get install -yq lvm2 > /dev/null 2>&1

if lsblk /dev/xvdb > /dev/null 2>&1; then
  if ! pvs /dev/xvdb > /dev/null 2>&1; then
    pvcreate /dev/xvdb
    vgcreate retailedge-logs-vg /dev/xvdb
    lvcreate -L 4G -n logs retailedge-logs-vg
    mkfs.ext4 /dev/retailedge-logs-vg/logs
  fi

  if ! mountpoint -q /var/log/myapp; then
    mount /dev/retailedge-logs-vg/logs /var/log/myapp
  fi

  if ! grep -q "retailedge-logs-vg" /etc/fstab; then
    echo "/dev/retailedge-logs-vg/logs /var/log/myapp ext4 defaults 0 2" \
      >> /etc/fstab
  fi

  tune2fs -m 1 /dev/retailedge-logs-vg/logs > /dev/null 2>&1 || true
else
  echo "[Session 5] /dev/xvdb not present — skipping LVM (single-volume lab run)."
fi

cat > /usr/local/bin/disk-alert.sh << 'EOF'
#!/usr/bin/env bash
THRESHOLD=80
USAGE=$(df /var/log/myapp 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
if [ "${USAGE}" -gt "${THRESHOLD}" ]; then
  echo "[ALERT] Disk usage at ${USAGE}% on /var/log/myapp at $(date)" \
    >> /var/log/myapp/disk-alerts.log
fi
EOF

chmod +x /usr/local/bin/disk-alert.sh

TMPFILE=$(mktemp)
crontab -l 2>/dev/null | grep -v "disk-alert" > "${TMPFILE}" || true
echo "*/5 * * * * /usr/local/bin/disk-alert.sh" >> "${TMPFILE}"
crontab "${TMPFILE}"
rm -f "${TMPFILE}"

echo "[Session 5] LVM check complete."

# =============================================================================
# SESSION 6 — TLS, nginx HTTPS
# =============================================================================

echo "[Session 6] Configuring TLS for nginx..."

apt-get install -yq openssl > /dev/null 2>&1

TLS_DIR="/etc/letsencrypt/live/retailedge-lab"
mkdir -p "${TLS_DIR}"

if [ ! -f "${TLS_DIR}/fullchain.pem" ]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${TLS_DIR}/privkey.pem" \
    -out "${TLS_DIR}/fullchain.pem" \
    -subj "/CN=retailedge-lab/O=RetailEdge/C=GB" \
    > /dev/null 2>&1
fi

if [ ! -f /etc/ssl/certs/dhparam.pem ]; then
  openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048 > /dev/null 2>&1
fi

mkdir -p /etc/nginx/snippets

cat > /etc/nginx/snippets/tls-hardening.conf << 'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_dhparam /etc/ssl/certs/dhparam.pem;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
EOF

cat > /etc/nginx/sites-available/retailedge << EOF
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;
    ssl_certificate ${TLS_DIR}/fullchain.pem;
    ssl_certificate_key ${TLS_DIR}/privkey.pem;
    include snippets/tls-hardening.conf;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

nginx -t > /dev/null 2>&1 && systemctl reload nginx || true

echo "[Session 6] TLS configured."

# =============================================================================
# SESSION 7 — SSH hardening, fail2ban, auditd via Ansible
# =============================================================================

echo "[Session 7] Installing Ansible, fail2ban, auditd..."

apt-get install -yq ansible fail2ban auditd > /dev/null 2>&1

# SSH hardening (CIS-aligned subset applied directly for bootstrap speed)
SSHD_CONF="/etc/ssh/sshd_config"

grep -q "^PermitRootLogin" "${SSHD_CONF}" && \
  sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "${SSHD_CONF}" || \
  echo "PermitRootLogin no" >> "${SSHD_CONF}"

grep -q "^PasswordAuthentication" "${SSHD_CONF}" && \
  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "${SSHD_CONF}" || \
  echo "PasswordAuthentication no" >> "${SSHD_CONF}"

grep -q "^ClientAliveInterval" "${SSHD_CONF}" && \
  sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 300/' "${SSHD_CONF}" || \
  echo "ClientAliveInterval 300" >> "${SSHD_CONF}"

grep -q "^AllowUsers" "${SSHD_CONF}" && \
  sed -i 's/^AllowUsers.*/AllowUsers ubuntu/' "${SSHD_CONF}" || \
  echo "AllowUsers ubuntu" >> "${SSHD_CONF}"

sshd -t && systemctl reload ssh > /dev/null 2>&1 || true

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
backend = systemd
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw

[sshd]
enabled = true
EOF

systemctl enable --now fail2ban > /dev/null 2>&1 || true

cat > /etc/audit/rules.d/99-retailedge-hardening.rules << 'EOF'
# Watch authentication and account files
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/sudoers -p wa -k sudoers
# Log privileged binary execution
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k privileged
# Make rules immutable — must reboot to change
-e 2
EOF

service auditd restart > /dev/null 2>&1 || true

echo "[Session 7] SSH hardening, fail2ban, auditd applied."

# =============================================================================
# SESSION 8 — Confirm VPC module outputs are accessible
# (Actual Terraform resources were provisioned before this script ran)
# =============================================================================

echo "[Session 8] Session 8 VPC module — infrastructure confirmed via Terraform."
echo "  web-sg and app-sg exist, private subnet isolated."

# =============================================================================
# SESSION 9 — BROKEN STATE
# Simulate the problem: hardcode IP addresses into /etc/hosts as if a
# previous engineer "fixed" connectivity by editing /etc/hosts instead of
# configuring DNS. When this instance is replaced, these IPs will be stale.
# =============================================================================

echo ""
echo "============================================================"
echo " SESSION 9 — Introducing broken state"
echo "============================================================"

echo "[Session 9] Writing hardcoded IP entries to /etc/hosts..."

# Remove any prior lab entries to make this idempotent
sed -i '/retailedge.internal/d' /etc/hosts || true

# Write hardcoded entries using the current instance IP as a stand-in
# In a real scenario these would be the OLD instance IPs after replacement
STALE_IP="10.0.1.99"

cat >> /etc/hosts << EOF

# RetailEdge internal service addresses — HARDCODED (Session 9 broken state)
# These IPs will be WRONG after the next instance replacement.
${STALE_IP}    web.retailedge.internal
${STALE_IP}    api.retailedge.internal
${STALE_IP}    internal.retailedge.internal
EOF

echo "[Session 9] Hardcoded /etc/hosts entries written."
echo "  Stale IP used: ${STALE_IP}"
echo "  These entries will cause DNS failures after instance replacement."
echo ""
echo "[Session 9] Installing dig and nslookup..."

apt-get install -yq dnsutils > /dev/null 2>&1

echo ""
echo "============================================================"
echo " Bootstrap complete."
echo " Broken state: /etc/hosts contains hardcoded stale IPs."
echo " Your job: replace /etc/hosts entries with Route53 DNS."
echo "============================================================"
```

---

### Phase 3 — Running the Script

**Step 1 — Copy the script to the instance:**

```bash
# Replace KEY_PATH and EC2_HOST with your session values
scp \
  -i ~/.ssh/canonical_lab_key \
  bootstrap-session9.sh \
  ubuntu@<EC2_HOST>:/home/ubuntu/bootstrap-session9.sh
```

**Step 2 — SSH into the instance:**

```bash
ssh -i ~/.ssh/canonical_lab_key ubuntu@<EC2_HOST>
```

**Step 3 — Run the bootstrap:**

```bash
# Export your ops IP before running
export OPS_IP="<YOUR_OPS_IP>/32"
sudo -E bash bootstrap-session9.sh
```

**Expected runtime:** 4–7 minutes on a t2.micro with a cold apt cache.

**Successful completion looks like:**

```
============================================================
 Bootstrap complete.
 Broken state: /etc/hosts contains hardcoded stale IPs.
 Your job: replace /etc/hosts entries with Route53 DNS.
============================================================
```

**Verify the broken state is in place:**

```bash
grep "retailedge.internal" /etc/hosts
```

Expected output:

```
10.0.1.99    web.retailedge.internal
10.0.1.99    api.retailedge.internal
10.0.1.99    internal.retailedge.internal
```

---

### Phase 4 — Update GitHub Secrets

Before continuing, update the following secrets in your repository at `github.com/Nikiobilor/cloud-field-engineer-labs → Settings → Secrets and variables → Actions`:

| Secret | Value |
|---|---|
| `EC2_HOST` | New instance public IP |
| `EC2_USER` | `ubuntu` |
| `EC2_SSH_KEY` | Contents of `~/.ssh/canonical_lab_key` (private key) |
| `OPS_IP` | Your current ops IP with `/32` suffix |

---

## Prerequisites

The bootstrap satisfies all of these. Verify before starting the steps.

- ✅ EC2 instance running Ubuntu 22.04 in the Session 8 VPC (10.0.0.0/16)
- ✅ Public subnet (10.0.1.0/24) with IGW route table associated
- ✅ Private subnet (10.0.2.0/24) created but isolated
- ✅ web-sg and app-sg created with SG-source rule on port 8080
- ✅ `myapp.service` running on 127.0.0.1:8080
- ✅ nginx running on 443, proxying to myapp
- ✅ node_exporter running on 9100
- ✅ fail2ban, auditd, SSH hardening applied
- ✅ `dnsutils` installed (provides `dig` and `nslookup`)
- ✅ Hardcoded `/etc/hosts` entries present (the broken state)
- ✅ Terraform state includes S3 backend with `use_lockfile = true`

---

## Step 1 — Understand the Problem: Why Hardcoded IPs Break

**What we are doing and why**

Before writing any code, you need to be able to explain the problem to a client in plain language. This is not optional context, it is the framing that justifies the work. A CFE who deploys DNS without being able to explain the failure mode they are solving will lose the client's confidence at the first question.

On this EC2 instance, the bootstrap placed three entries in `/etc/hosts` that look like this:

```
10.0.1.99    web.retailedge.internal
10.0.1.99    api.retailedge.internal
10.0.1.99    internal.retailedge.internal
```

This pattern is extremely common in real environments. An engineer needed internal services to talk to each other, DNS was not configured, and editing `/etc/hosts` was the fastest fix. It worked, until the instance was replaced.

**Read the current broken state:**

```bash
# Show the contents of /etc/hosts
# The hardcoded entries will be visible at the bottom
cat /etc/hosts
```

```bash
# Try to resolve web.retailedge.internal
# This will resolve, but to the STALE IP, not the current instance
dig web.retailedge.internal
```

Notice the answer section returns `10.0.1.99`. That IP is not the current instance's private IP. On a real replacement, any service that tries to connect to `web.retailedge.internal` would be talking to a dead address.

```bash
# Show the current instance private IP
hostname -I | awk '{print $1}'
```

The IP from `hostname -I` and the IP in `/etc/hosts` are different. That gap is the entire problem.

> **Career insight:** `/etc/hosts` edits are a red flag in a client environment. They are a sign that DNS was not understood, not configured, or too slow to set up in a hurry. On a client engagement you will frequently encounter systems that have accumulated years of `/etc/hosts` overrides. Part of the job is knowing how to migrate them safely, which means understanding exactly how `/etc/hosts`, the VPC resolver, and Route53 interact before making any changes.

---

## Step 2 — How DNS Resolution Works on an AWS VPC Instance

**What we are doing and why**

Before you can configure Route53, you must understand the resolution chain on Ubuntu 22.04 in a VPC. Engineers who skip this step often configure Route53 correctly but observe no change in behaviour, because they do not realise that `/etc/hosts` takes precedence over DNS, or that `systemd-resolved` is sitting between the application and the VPC resolver.

**The resolution chain on Ubuntu 22.04 in a VPC:**

```
Application
    │
    ▼
getaddrinfo() / glibc NSS
    │  checks /etc/nsswitch.conf
    │  default: "hosts: files dns"
    │  "files" = /etc/hosts  ← checked FIRST
    ▼
systemd-resolved (stub resolver at 127.0.0.53:53)
    │  Ubuntu 22.04 manages /etc/resolv.conf as a symlink
    │  to /run/systemd/resolve/stub-resolv.conf
    │  which points to 127.0.0.53
    ▼
VPC Resolver (10.0.0.2, also reachable at 169.254.169.253)
    │  Every VPC has a resolver at the base-plus-two address.
    │  Base address of VPC CIDR is 10.0.0.0, so resolver is 10.0.0.2.
    │  AWS also provides the link-local address 169.254.169.253
    │  as a consistent resolver address regardless of VPC CIDR.
    ▼
Route53 Private Hosted Zone (if zone is associated with this VPC)
    │  OR
Route53 Public DNS / Internet DNS (for public names like google.com)
```

**Verify which resolver is actually in use:**

```bash
# Check what /etc/resolv.conf currently points to
# On Ubuntu 22.04 this should be a symlink to systemd-resolved stub
ls -la /etc/resolv.conf
```

```bash
# Read the actual file contents
# You should see nameserver 127.0.0.53 (the systemd-resolved stub)
cat /etc/resolv.conf
```

```bash
# Check the systemd-resolved status
# Look for the DNS server line — it should show the VPC resolver (10.0.0.2)
systemd-resolve --status | grep -5 "DNS Servers"
```

```bash
# Confirm the VPC base-plus-two resolver is reachable
# This should return DNS A records for amazonaws.com
dig @10.0.0.2 amazonaws.com A +short
```

```bash
# Also test via the link-local address
# Both addresses should return the same result
dig @169.254.169.253 amazonaws.com A +short
```

**The `/etc/nsswitch.conf` precedence rule:**

```bash
# Show the Name Service Switch configuration
# The hosts: line defines resolution order
grep "^hosts:" /etc/nsswitch.conf
```

Expected output:

```
hosts:          files dns
```

The word `files` means `/etc/hosts` is checked before DNS. This is why the hardcoded entries in `/etc/hosts` currently override any DNS query. When you remove those entries in Step 11, DNS will take over, but only because Route53 will be configured by then.

> **Edge case — what if /etc/resolv.conf is NOT a symlink?** On some custom AMIs or instances that were upgraded from older Ubuntu versions, `/etc/resolv.conf` may be a regular file pointing directly to `10.0.2`. Resolution still works, but `systemd-resolve --status` will show the resolver differently. Always check both `cat /etc/resolv.conf` and `systemd-resolve --status` to get the full picture. Never assume the resolver address without verifying.

**Summary table — VPC resolver addresses:**

| Address | Notes |
|---|---|
| `<VPC_BASE>.2` | e.g. `10.0.0.2` for VPC CIDR `10.0.0.0/16`. Always the second address in the VPC CIDR block. |
| `169.254.169.253` | Link-local address. Same resolver, different path. S guarantees this address works in any VPC. Useful when VPC CIDR is not 10.0.0.0/16 and you do not want to compute the base-plus-two. |
| `127.0.0.53` | The systemd-resolved stub. This is what `/etc/resolv.conf` points to on Ubuntu 22.04. Applications talk to this; it forwards upstream to `10.0.0.2`. |

---

## Step 3 — What Is a Route53 Private Hosted Zone?

**What we are doing and why**

You need to be able to explain the difference between a public hosted zone and a private hosted zone to a client, andrticulate why private hosted zones are the right primitive for internal service discovery. 

**Public hosted zone vs Private hosted zone:**

| Property | Public Hosted Zone | Private Hosted Zone |
|---|---|---|
| Visibility | Resolvable from anywhere on the internet | Resolvable only from associated VPCs |
| Use case | `www.retailedge.com`, `api.retailedge.com` (customer-facing) | `web.retailedge.internal`, `api.retailedge.internal` (service-to-service) |
| NS records required | Yes — NS records must be s at the registrar | No — AWS handles resolution for associated VPCs automatically |
| Cost | $0.50/zone/month + query charges | Free for zones associated with a VPC in the same account |
| External resolver | Returns real records | Returns NXDOMAIN |

**How a private hosted zone is served:**

When you associate a private hosted zone with a VPC, the VPC resolver at `10.0.0.2` automatically becomes authoritative for that zone. No configuration changes are required on the EC2 instance. Any query for a name iide `retailedge.internal` sent to `10.0.0.2` will be answered from Route53, as long as the instance is inside the associated VPC.

Queries for the same names from outside the VPC (e.g. from your laptop, from another VPC) will return NXDOMAIN. The zone does not exist from that perspective.

This is the mechanism behind split-horizon DNS, which is covered in depth in Step 4.

---

## Step 4 — Split-Horizon DNS Explained

**What we are doing and why**

Split-horizon DNS (also called split-brain DNS) is one othe most commonly misunderstood networking concepts on cloud platforms. Understanding it will come up in client conversations, architecture reviews. This step ensures you can explain it clearly before you deploy it.

**Definition:**

Split-horizon DNS is a configuration where the same DNS name resolves to different answers depending on where the query originates. Queries from inside a trusted network (the VPC) return the internal, private IP. Queries from outside return either a different answer (a public IP, a CDN address) or NXDOMAIN.

**Why it matters for internal services:**

RetailEdge's `api.retailedge.internal` should never be reachable from the public internet, not because of firewall rules alone, but because the name itself should not resolve externally. This removes an entire class of attack surface: even if a misconfigured security group briefly opened port 8080, an external attacker would have no DNS record to target.

At the same time, internal services need to talk to each other using stable, predictable names. `api.retailedge.internal` should always resolve to the correct private IP from inside the VPC, regardless of which EC2 instance is currently running that service.

**How Route53 private hosted zones implement split-horizon:**

Route53 private hosted zones are a native split-horizon implementation. The zone `retailedge.internal` is only served by the VPC resolver for associated VPCs. From outside, the zone does not exist.

**Comparison table — what resolves from where:**

| Query | From inde the VPC | From outside the VPC (internet) |
|---|---|---|
| `web.retailedge.internal` | `10.0.1.x` (A record from Route53 private zone) | NXDOMAIN |
| `api.retailedge.internal` | `10.0.2.x` (A record from Route53 private zone) | NXDOMAIN |
| `internal.retailedge.internal` | `web.retailedge.internal` → `10.0.1.x` (CNAME chain) | NXDOMAIN |
| `www.retailedge.com` | Public IP (answered from public hosted zone or internet) | Public IP (answered from internet) |

> **Career insight:** A client will sometimeask: "Can we just put `api.retailedge.internal` in a public hosted zone with the private IP?" The answer is no, for two reasons. First, a public zone resolves globally, any external resolver can query it and discover the private IP, which leaks network topology. Second, from inside the VPC the answer would come from the public internet resolver, not the local VPC resolver, adding unnecessary latency and a dependency on internet connectivity. Private hosted zones solve both problems.

---

## Step 5 — TTL lues: Trade-offs in a Cloud Environment

**What we are doing and why**

Before writing any Terraform, you need to decide what TTL to set on each DNS record. TTL (Time to Live) is the number of seconds a resolver is allowed to cache a DNS answer before querying again. In a cloud environment where IP addresses change on instance replacement, TTL choices have operational consequences.

**TTL reference table:**

| TTL Value | Appropriate for | Trade-off |
|---|---|---|
| `0` | Not recommended in production. Some resolvers treat 0 as 1. | Effectively disables caching. Every DNS query hits Route53. Higher latency and query cost. |
| `30` | Records that point to frequently-replaced instances (e.g. Auto Scaling group members, blue/green targets) | Very responsive to IP changes. Clients see the new IP within 30 seconds. Higher query volume. |
| `60` | Default for lab environments. Reasonable for records that change on instance replacement. | New IP propagates within 1 minute. Acceptable for non-latency-sensitive internal services. |
| `300` (5 min) | Records that change occasionally (e.g. load balancer IPs, service endpoints) | Good balance. Low query overhead. Up to 5 minutes of stale answers after an IP change. |
| `3600` (1 hr) | Stable records: MX records, NS records, CNAMEs pointing to stable endpoints | Very low query overhead. Changes take up to 1 hour to propagate. Not suitable for EC2 instance IPs. |
| `86400` (24 hr) | Static infrastructure (root NS records, SOA) | Minimal query overhead. Changes take a full day to propagate. Never use for instance-level A records. |

**For this session:**

The A records for `web.retailedge.internal` and `api.retailedge.internal` will use a TTL of `60`. These records point to EC2 instance private IPs that change every session when the instance is replaced. A TTL of 60 seconds means that after updating the A record in Route53, all callers inside the VPC will have the correct IP within 60 seconds, without any manual intervention.

The CNAME for `internal.retailedge.internal` will also use `60` since it chains through the A record.

> **Edge case — cached stale DNS during deployment:** If you update an A record in Route53 but a client had already cached the old answer, they will continue sending traffic to the old IP until the TTL expires. This is why low TTLs (30–60s) are recommended for records that point to instance IPs. On the day of a deployment, it is common practice to reduce the TTL to 30 seconds 10 minutes before the change, then restore it to 300 seconds after the new rd has propagated.

---

## Step 6 — Write the Terraform DNS Module

**What we are doing and why**

Terraform modules enforce reusability and separation of concerns. The DNS module lives at `terraform/modules/dns/` and owns all Route53 resources. The root configuration calls the module and passes in the VPC ID and EC2 private IPs. This means the DNS zone and its records are version-controlled, reviewable, and reproducible, not a set of console clicks that nobody documented.

**Create the module directory:*
```bash
# Create the DNS module directory inside the Terraform root
cd  terraform/modules/
mkdir dns
```

**Create `dns/variables.tf`:**

```bash
cat > dns/variables.tf << 'EOF'
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
EOF
```

**Create `dns/main.tf`:**

```bash
cat > dns/main.tf << 'EOF'
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
  name    =api.${var.zone_name}"
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
EOF
```

**Create `dns/outputs.tf`:**

```bash
cat > dns/outputs.tf << 'EOF'
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
EOF
```

**Verify the module structure:**

```bash
# Confirm all three module files exist
find dns -type f | sort
```

Expected output:

```
terraform/modules/dns/main.tf
terraform/modules/dns/outputs.tf
terraform/modules/dns/variables.tf
```

---

## Step 7 — Integre the DNS Module into Root Configuration

**What we are doing and why**

The module you wrote in Step 6 does nothing until the root `main.tf` calls it. This step wires the DNS module into the root configuration, passing in the VPC ID from the Session 8 VPC module and the EC2 instance's private IP from the existing `aws_instance` resource.

**Add the DNS module block to `terraform/main.tf`:**

Open `terraform/main.tf` and add the following block after the Session 8 VPC module block. Do not replace any existing blocks.

```hcl
# DNS module — Session 9
# Wires the private hosted zone to the Session 8 VPC.
# The vpc_id is read from the vpc module output.
# The web_private_ip is read from the EC2 instance resource.
module "dns" {
  source = "./modules/dns"

  vpc_id         = module.vpc.vpc_id
  web_private_ip = aws_instance.web.private_ip
  dns_ttl        = 60
}
```

> **Note on module output names:** The `module.vpc.vpc_id` reference assumes the Session 8 VPC module has an output named `vpc_id` in its `outputsf`. If your output has a different name, substitute it here. Run `terraform output` to check what the VPC module currently exposes.

**Add the DNS module outputs to `terraform/outputs.tf`:**

If your root configuration has an `outputs.tf`, add:

```hcl
output "route53_zone_id" {
  description = "The Route53 private hosted zone ID"
  value       = module.dns.zone_id
}

output "route53_zone_name" {
  description = "The private hosted zone domain name"
  value       = module.dns.zone_name
}

output "web_dns_record" {
  description = "FQDN of the web A record"
  value       = module.dns.web_record_fqdn
}

output "api_dns_record" {
  description = "FQDN of the API A record"
  value       = module.dns.api_record_fqdn
}
```

---

## Step 8 — Apply the Terraform Changes

**What we are doing and why**

With the DNS module written and integrated, it is time to apply the changes. Terraform will create the Route53 private hosted zone, three DNS records, and associate the zone with the VPC. This happens in the AWS contr plane, no changes are required on the EC2 instance itself. The VPC resolver automatically picks up the new zone.

**From your local machine (not the EC2 instance):**

```bash
# Move into the Terraform root directory
cd terraform
```

```bash
# Initialise modules — required whenever a new module source is added
terraform init
```

```bash
# Review the planned changes before applying
# You should see: +3 resources to add (zone, 2 A records, 1 CNAME)
terraform plan
```

Review the plan output carefully. Youhould see:

```
+ aws_route53_zone.private (via module.dns)
+ aws_route53_record.web   (via module.dns)
+ aws_route53_record.api   (via module.dns)
+ aws_route53_record.internal_cname (via module.dns)
```

No existing resources should be modified or destroyed. If you see any `~` (modify) or `-` (destroy) symbols on Session 8 resources, stop and investigate before applying.

```bash
# Apply the changes
# -auto-approve skips the interactive yes/no confirmation prompt
terraform apply \
  -auto-approve
```

```bash
# After apply, show the DNS-related outputs
# These confirm the zone ID and record FQDNs were created
terraform output
```

**Note the `route53_zone_id` output value.** You will use it in the console verification step.

> **Edge case — `ConflictingDomainExists` error:** If you see this error during apply, a private hosted zone for `retailedge.internal` already exists in your account from a previous run. Run `terraform import module.dns.aws_route53_zone.private <ZONE_ID>` to bring the existing zone unr Terraform management, then re-run `terraform apply`.

---

## Step 9 — Verify DNS Resolution from Inside the Instance

**What we are doing and why**

Terraform successfully creating the Route53 resources does not mean the EC2 instance can resolve them yet. You must verify resolution from inside the VPC to confirm that the association between the private hosted zone and the VPC is working, and that the VPC resolver is answering correctly. 

**SSH into the instance:**

```bash
ssh -i ~/.ssh/canonical_lab_y ubuntu@<EC2_HOST>
```
To remove the address in /etc/hosts
Run 
sudo sed -i '/retailedge.internal/d' /etc/hosts
sudo systemd-resolve --flush-caches
**Test resolution using `dig`:**

```bash
# Query web.retailedge.internal using the default resolver
# The ANSWER SECTION should show the EC2 private IP
dig web.retailedge.internal
```

Look at the output carefully:

```
;; ANSWER SECTION:
web.retailedge.internal. 60 IN A 10.0.1.x
```

- The `60` is the TTL you set.
- The `10.0.1.x` should match the current instance's private IP.
- The response should come from `10.0.0.2` (the VPC resolver).

```bash
# Query api.retailedge.internal
# Should return the placeholder IP 10.0.2.10
dig api.retailedge.internal
```

```bash
# Query the CNAME record
# Should return CNAME pointing to web.retailedge.internal, then the A record
dig internal.retailedge.internal
```

Expected output for the CNAME query:

```
;; ANSWER SECTION:
internal.retailedge.internal. 60 IN CNAME web.retailedge.internal.
web.retailedge.internal.      60 IN A     10.0.1.x
```

`dig` follows the CNAME chain automatically and shows both records.

**Test resolution using `nslookup`:**

```bash
# nslookup is useful for clients who are more familiar with Windows environments
nslookup web.retailedge.internal
```

```bash
nslookup api.retailedge.internal
```

```bash
nslookup internal.retailedge.internal
```

**Query the VPC resolver directly:**

```bash
# Bypass systemd-resolved and query the VPC resolver directly
# This confirms the zone is available at the resolver level
dig @10.0.0.2 web.retailedge.internal
```

```bash
# Also test via the link-local address
dig @169.254.169.253 web.retailedge.internal
```

Both should return identical answers.

**Confirm the name does NOT resolve from outside the VPC:**

Run this from your local machine (outside the VPC):

```bash
# From your laptop, this should return NXDOMAIN
# If it returns an answer, the zone is not actually private
dig web.retailedge.internal
```

Expected output:

```
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: xxxxx
```

> **Interpreting `dig` output — quick reference:**
>
> | Field | Meaning |
> |---|---|
> | `status: NOERROR` | Query succeeded, record exists |
> | `status: NXDOMAIN` | Name does not exist in DNS |
> | `ANSWER SECTION` | The actual DNS records returned |
> | `AUTHORITY SECTION` | Which nameservers are authoritative for this zone |
> | `SERVER: 127.0.0.53` | Query went through systemd-resolved stub |
> | `SERVER: 10.0.0.2` | Query went directly to VPC resolver |
> | TTL value | Sends remaining in resolver cache |

---

## Step 10 — Verify from the AWS Console

**What we are doing and why**

Route53 has an excellent visual interface for DNS management that your clients will use directly. Knowing how to navigate it — and how to explain what they are looking at — is part of the CFE role. Console verification also provides a sanity check independent of `dig` or Terraform output.

**Navigate to the hosted zone:**

1. Open the AWS Console and go to **Route53 → Hosted zones**.
2. Ysee `retailedge.internal` listed with type **Private**.
3. Click on the zone name.

**Verify the records:**

You should see the following records in the zone:

| Name | Type | Value | TTL |
|---|---|---|---|
| `retailedge.internal` | NS | (Route53 internal nameservers — do not modify) | 172800 |
| `retailedge.internal` | SOA | (Route53 internal SOA — do not modify) | 900 |
| `web.retailedge.internal` | A | `10.0.1.x` (your EC2 private IP) | 60 |
| `api.retailedge.internal` | A | `10.0.2.10` (placeholder60 |
| `internal.retailedge.internal` | CNAME | `web.retailedge.internal` | 60 |

> **Note on NS and SOA records:** Route53 automatically creates these system records for every hosted zone. The NS record for a private hosted zone uses Route53's internal nameserver addresses, these are different from the public NS records you would set at a domain registrar. You do not configure them, and you should not modify them. Terraform will not manage them unless you explicitly import and declare them, which is generally not done.

**Verify the VPC association:**

1. In the hosted zone view, click on the **Hosted zone details** tab.
2. Under **VPCs**, confirm that your VPC ID (from `terraform output`) is listed.
3. If it is not listed, the zone was not associated during Terraform apply, go back to Step 8 and check the plan output.

**Check the console query tool (optional):**

Route53 does not have a built-in "test query" tool in the console for private hosted zones, queries from the console originate from outside the VPC and will return NXDOMAIN. This is expected and is itself evidence that split-horizon is working. For query testing, always use `dig` or `nslookup` from inside the EC2 instance.

---

## Step 11 — Remove the /etc/hosts Hardcoded Entries

**What we are doing and why**

Now that Route53 is serving the correct DNS records for `retailedge.internal`, the hardcoded `/etc/hosts` entries introduced by the bootstrap must be removed. Because `/etc/hosts` is checked before DNS (due to `nsswitch.conf`), leaving thetale entries in place means the instance would never actually use Route53, it would keep returning `10.0.1.99` regardless of what Route53 says.

This step is the operational fix that closes the ticket. Everything before this was infrastructure preparation. This is the moment of change.

**First, confirm the broken entries are still present:**

```bash
# Show the retailedge.internal entries currently in /etc/hosts
grep "retailedge.internal" /etc/hosts
```

```bash
# Confirm these still resolve to the stale IP via /etc/hosts
# Before removal, dig returns 10.0.1.99 (from /etc/hosts, not Route53)
dig web.retailedge.internal +short
```

**Remove the stale entries:**

```bash
# Remove all lines containing retailedge.internal from /etc/hosts
# The sed -i command edits the file in place
# The pattern matches the entire line
sudo sed -i '/retailedge.internal/d' /etc/hosts
```

**Verify the entries are gone:**

```bash
# This should return no output if the sed command succeeded
grep "retailedge.internal" /etc/hosts || echo "No hardcoded entries found."
```

**Verify DNS now resolves via Route53:**

```bash
# This should now return the actual EC2 private IP (from Route53)
# Not the stale 10.0.1.99 (from the old /etc/hosts entries)
dig web.retailedge.internal +short
```

```bash
# Cross-check against the actual instance private IP
# These two values should now match
echo "DNS answer:    $(dig web.retailedge.internal +short)"
echo "Instance IP:   $(hostname -I | awk '{print $1}')"
```

> **Edge case — systemd-resolved cac:** If `dig` still returns `10.0.1.99` after removing the `/etc/hosts` entries, systemd-resolved may have cached the old answer. Flush the cache with: `sudo systemd-resolve --flush-caches`. Then re-run the dig command.

---

## Step 12 — Confirm End-to-End Service Connectivity by Name

**What we are doing and why**

DNS resolution working in `dig` is necessary but not sufficient. You should verify that the services on this instance are reachable using their DNS names — not just their IPs. This is what tlient cares about: can `api.retailedge.internal` be used in a config file, an environment variable, or a service definition, and will it reliably resolve to the right place?

```bash
# Test HTTP connectivity to web.retailedge.internal
# This should proxy through nginx to myapp and return "RetailEdge myapp OK"
curl -sk https://web.retailedge.internal --resolve \
  "web.retailedge.internal:443:$(dig web.retailedge.internal +short)"
```

> The `--resolve` flag is needed here because our self-signed TLS certificate was issued for `retailedge-lab`, not `web.retailedge.internal`. In production with a valid cert, you would use `curl -sk https://web.retailedge.internal` directly.

```bash
# Verify node_exporter is reachable on the metrics port by DNS name
# This simulates a Prometheus scrape config using a DNS name instead of IP
curl -s "http://web.retailedge.internal:9100/metrics" | head -5
```

```bash
# Confirm myapp is running and healthy via its service name
systemctl is-active myapp.service nginx.service node_exporter.service
```

**Check that DNS-based resolution persists after a TTL expiry:**

```bash
# Wait for TTL to expire and query again
# The answer should be identical — Route53 re-serves the same record
sleep 65
dig web.retailedge.internal +short
```

The answer should still be the correct private IP, not `10.0.1.99`. This confirms that the fix is durable, not just cached from the first query.

---

## Step 13 — Handover Document

**What we are doing and why**

Every ticket that touches production infructure requires a written handover. The document below is what a CFE would deliver to the RetailEdge platform team after completing this engagement. It is the record of what changed, why it changed, and what the team needs to know going forward.

Create the file on the EC2 instance:

```bash
cat > ~/HANDOVER-SESSION-09.md << 'EOF'
# Handover Document — DNS-Based Service Discovery
## RetailEdge Ltd — Internal Platform Team
### Engagement Reference: TICKET-009
### Date: $(date +%Y-%m-%d)
### Engineer: [YName]

---

## Summary

Internal services on the RetailEdge EC2 environment were using hardcoded IP
addresses in /etc/hosts to reference each other by name. These entries became
stale on every EC2 instance replacement, causing connectivity failures that
required manual updates across multiple config files.

The fix: a Route53 private hosted zone (retailedge.internal) was created and
associated with the VPC using Terraform. DNS A records and a CNAME record were
registered for the web and API tiers. The hardcoded /etc/hosts entries were
removed. All internal service names now resolve via DNS and will continue to
resolve correctly after instance replacements.

---

## What Changed

| Component | Before | After |
|---|---|---|
| /etc/hosts | 3 hardcoded IP entries for retailedge.internal names | No retailedge.internal entries (DNS-driven) |
| Route53 | No private hosted zone | retailedge.internal zone, associated with VPC |
| DNS records | None | web (A), api (A), internal (CNAME) |
| Terraform | Modules: vpc only | Modules: vpc + dns |

---

## DNS Records Created

| Name | Type | Value | TTL |
|---|---|---|---|
| web.retailedge.internal | A | <WEB_EC2_PRIVATE_IP> | 60 |
| api.retailedge.internal | A | 10.0.2.10 (placeholder) | 60 |
| internal.retailedge.internal | CNAME | web.retailedge.internal | 60 |

The api.retailedge.internal A record uses a placeholder IP.
Update this record in Terraform (terraform/modules/dns/main.tf, var.api_private_ip)
when the app tier EC2 instance is provisioned.

---

## How to Update a DNS Record After Instance Replacement

1. Note the new EC2 private IP from the AWS Console or:
   terraform output (after re-applying Terraform with the new instance)

2. In terraform/main.tf, update the dns module block:
   module "dns" {
     web_private_ip = "<NEW_PRIVATE_IP>"
   }

3. Run: terraform apply -auto-approve

4. On the new EC2 instance, verify:
   dig web.retailedge.internal +short

The record update propagates to all VPC instances within 60 seconds
(the configured TTL). No /etc/hosts edits are required.

---

## Key Operational Notes

- The retailedge.internal zone is PRIVATE. It is only resolvable from within
  the associated VPC. External resolvers return NXDOMAIN. This is intentional.

- Resolution uses the VPC resolver at 10.0.0.2. No EC2 instance configuration
  changes were required. Resolution is automatic for any instance in the VPC.

- TTL is set to 60 seconds on all records to minimise propagation delay after
  instance replacement. If query volume becomes a concern, raise to 300 seconds.

- The Terraform state for DNS resources is stored in the same S3 backend as
  all other session resources. Zone ID and record FQDNs are available as
  Terraform outputs.

---

## Verification Commands (run from inside the VPC)

  dig web.retailedge.internal
  dig api.retailedge.internal
  dig internal.retailedge.internal
  nslookup web.retailedge.internal

Expected: ANSWER SECTION returns the correct private IP for each query.

---

## Files Changed

  /etc/hosts                            (hardcoded entries removed)
  terraform/modules/dns/main.tf         (new)
  terraform/modules/dns/variables.tf    (new)
  terraform/modules/dns/outputs.tf      (new)
  terraform/main.tf                     (dns module block added)
  terraform/outputs.tf                  (dns outputs added)

EOF
```

```bash
cat ~/HANDOVER-SESSION-09.md
```

---

## Step 14 — Commit Your Work

**What we are doing and why**

Everything Terraform-managed must be committed to the repository. The DNS module is production code. It musbe version-controlled, reviewable, and reproducible by any engineer on the team — not just you.

On your local machine:

```bash
# Stage the new Terraform module and modified root files
git add \
  terraform/modules/dns/main.tf \
  terraform/modules/dns/variables.tf \
  terraform/modules/dns/outputs.tf \
  terraform/main.tf \
  terraform/outputs.tf
```

```bash
# Stage the bootstrap script and handover document
git add \
  bootstrap-session9.sh \
  HANDOVER-SESSION-09.md
```

```bash
# Commit with a multiine message describing the change
git commit -m "Session 9: Route53 private hosted zone for DNS-based service discovery

- Add terraform/modules/dns/ with main.tf, variables.tf, outputs.tf
- Create Route53 private hosted zone retailedge.internal
- Register A records: web and api tiers (api uses placeholder 10.0.2.10)
- Register CNAME: internal.retailedge.internal -> web.retailedge.internal
- Associate zone with Session 8 VPC via vpc_id module output
- Wire dns module into root main.tf and outputs.tf
- TTL set to 60s on all records (EC2 IPs change on instance replacement)
- Remove hardcoded /etc/hosts entries; resolution is now fully DNS-driven
- Verify split-horizon: names resolve from inside VPC, NXDOMAIN from outside
- bootstrap-session9.sh: cumulative rebuild + broken state (/etc/hosts stale IPs)
- HANDOVER-SESSION-09.md: platform team operational guide

TICKET-009 closed."
```

```bash
# Push to the main branch
git push origin main
```

---

## Verification Checklist

Run these commands from inside the EC2 instance unless noted otherwise.

| Check | Command | Expected Output |
|---|---|---|
| No hardcoded entries remain | `grep "retailedge.internal" /etc/hosts` | No output |
| `web` A record resolves | `dig web.retailedge.internal +short` | EC2 private IP |
| `api` A record resolves | `dig api.retailedge.internal +short` | `10.0.2.10` |
| CNAME chain resolves | `dig internal.retailedge.internal` | CNAME + A record in ANSWER SECTION |
| Resolution via VPC resolver | `dig @10.0.0.2 web.retailedge.internal +short` | EC2 private IP |
| Resolution via link-local | `dig @169.254.169.253 web.retailedge.internal +short` | EC2 private IP |
| No resolution from outside VPC | `dig web.retailedge.internal` (from laptop) | `status: NXDOMAIN` |
| systemd-resolved upstream | `systemd-resolve --status \| grep -A3 "DNS Servers"` | `10.0.0.2` listed |
| resolv.conf is a symlink | `ls -la /etc/resolv.conf` | Points to `stub-resolv.conf` |
| All services still running | `systemctl is-active myapp nginx node_exporter fail2ban` | `active` for each |
| Terraform outputs present | `terraform output` (local machine) | zone_id, web_dns_record, api_dns_record |

---

## Troubleshooting Reference

| Symptom | Diagnostic Command | Fix |
|---|---|---|
| `dig` returns NXDOMAIN from inside instance | `dig @10.0.0.2 web.retailedge.internal` | Zone may not be associated with VPC. Check Route53 console → Hosted zone details → VPCs. Re-run `terraform apply`. |
| `dig` still returns stale IP after `/etc/hosts` removal | `systemd-resolve --flusches` then re-run dig | systemd-resolved cache held old answer. Flush resolves it. |
| `/etc/hosts` check returns hardcoded entry | `grep retailedge.internal /etc/hosts` | Re-run `sudo sed -i '/retailedge.internal/d' /etc/hosts` |
| `terraform apply` fails with `ConflictingDomainExists` | `aws route53 list-hosted-zones-by-name --dns-name retailedge.internal` | Import existing zone: `terraform import module.dns.aws_route53_zone.private <ZONE_ID>` |
| `module.dns.zone_id` not in `terraform output` | `terraform refresh` | Terraform state is stale. Refresh syncs state with actual resources. |
| `nslookup` returns wrong server address | `cat /etc/resolv.conf` | If nameserver is not `127.0.0.53`, systemd-resolved may be bypassed. Check `ls -la /etc/resolv.conf`. |
| `dig @10.0.0.2` fails (connection refused) | `ping 10.0.0.2` | VPC DNS support may be disabled. Check `aws ec2 describe-vpc-attribute --vpc-id <VPC_ID> --attribute enableDnsSupport`. The Terraform VPC module should have `enable_dns_support = true`. |
| TTL not 60 in dig output | `dig web.retailedge.internal` (check TTL field) | Record was created outside Terraform. Import and re-apply. |

---

## What You Learned This Session

| Skill | Career Asset for a CFE |
|---|---|
| Route53 private hosted zones | Every AWS client will ask about internal DNS. Knowing how to configure, associate, and verify a private zone is a baseline expectation on any Canonical AWS engagement. |
| VPC resolver and base-plus-two rule | Diagnosing DNS failures on EC2 always starts with understanding the resolution chain. Knowing 169.254.169.253 and 10.0.0.2 means you can verify DNS before any Route53 changes are made. |
| systemd-resolved on Ubuntu 22.04 | Canonical ships Ubuntu. Understanding how systemd-resolved interacts with /etc/resolv.conf and the VPC resolver is directly transferable to every Canonical client running Ubuntu on AWS. |
| Split-horizon DNS | This is an architectural concept, not just a configuration. Being able to explain why a name resolves differently from inside versus outside a VPC — and why that matters for security — elevates you from operator to architect in a client conversation. |
| TTL trade-offs in cloud environments | Low TTL for volatile IPs, high TTL for stable endpoints. Knowing this prevents outages during blue/green deployments and Auto Scaling events. |
| Terraform module composition | The dns module pattern — variables.tf, main.tf, outputs.tf — is how you build reusable, reviewable infrastructure. This pattern scales from a single hosted z full multi-region DNS architecture. |
| /etc/hosts vs DNS precedence | nsswitch.conf controls which source wins. Understanding this lets you explain to a client exactly why removing /etc/hosts entries is safe once DNS is configured. |
| Console verification of DNS resources | Route53 console is what clients use day-to-day. Being fluent in it — and knowing its limitations (no in-console query test for private zones) — is part of handover and training work on a CFE engagement. |

---

## Go Deeper

**1 â-VPC DNS association**
A private hosted zone can be associated with multiple VPCs — including VPCs in different accounts. What are the steps required to associate a private hosted zone in Account A with a VPC in Account B? What IAM permissions and cross-account authorisation are required? How does this pattern apply to a hub-and-spoke VPC architecture?

**2 — Health-check based DNS failover**
Route53 supports health checks that monitor an endpoint and automatically update DNS records when a health cheails. How would you configure a Route53 health check for `web.retailedge.internal`? What record types support failover routing? What is the difference between active-passive failover and active-active failover at the DNS layer, and when would a client choose each?

**3 — Route53 resolver inbound and outbound endpoints for hybrid DNS**
The VPC resolver only answers DNS queries originating inside the VPC. In a hybrid environment — where on-premises servers need to resolve `retailedge.internal`, or EC2 inses need to resolve on-premises hostnames like `app.corp.local` — the VPC resolver alone is not sufficient. What are Route53 resolver inbound endpoints and outbound endpoints? When would you deploy each? What is the cost and operational overhead compared to a private hosted zone?

**4 — DNS-based service discovery vs a service mesh**
A client asks: "We've heard about Consul and Istio — when would we use those instead of Route53 private hosted zones?" Write a structured answer distinguishing DNS-based s discovery (what you built this session) from a service mesh. Consider: mTLS between services, traffic policies and retries, health-aware routing, operational complexity, and cost. For a small team running five to ten services on EC2, which would you recommend, and why? At what point does the recommendation change?

**Recommended reading:**

- AWS documentation: [Working with private hosted zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
- AWS documentation: [DNS attributes for your VPC](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-dns.html)
- RFC 8499: DNS terminology — read the definitions of "authoritative server", "recursive resolver", and "stub resolver"
- Terraform registry: `aws_route53_zone` and `aws_route53_record` resource documentation

---



