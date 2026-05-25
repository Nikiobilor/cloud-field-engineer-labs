# TICKET-004 — Session 4: Network Diagnostics, Firewall Configuration & Connectivity Restoration

> **Canonical CFE Training Series** | Session 4 of 32 | `CFE-004`
> **Scenario:** A client's web app is unreachable from the internet. Internal services cannot talk to each other either. You have been called in to diagnose and fix it.

---

## The Ticket

```
TICKET ID:    CFE-004
PRIORITY:     Critical
ASSIGNED TO:  Cloud Field Engineer (You)
CLIENT:       RetailEdge Ltd — E-commerce platform, Lagos & London
ENVIRONMENT:  Ubuntu 22.04 LTS on AWS EC2

SUBJECT: Web application completely unreachable from outside.
         Internal services also failing to communicate.

DESCRIPTION:
Following last week's server changes, customers can no longer reach the
RetailEdge web application. The ops team also reports that myapp (port 8080)
cannot reach the internal database, and the node_exporter metrics endpoint
(port 9100, configured in Session 1) has also gone dark.

A junior engineer ran some iptables commands yesterday to "tighten security"
but did not document what they changed. Nobody knows the current state of
the firewall. The application process is running (confirmed via systemd from
Session 3) but connections are not reaching it.

We need someone to:
1. Diagnose the current network and firewall state without assumptions
2. Restore external connectivity to the web application
3. Fix internal service-to-service communication
4. Put a clean, documented firewall ruleset in place
5. Leave monitoring and diagnostic tooling in place for the support team

ACCEPTANCE CRITERIA:
- [ ] Current firewall state fully documented before any changes
- [ ] ufw configured with explicit, documented rules
- [ ] External access to the web app (port 80/443) restored
- [ ] node_exporter (port 9100) accessible from the ops IP only
- [ ] myapp (port 8080) accessible internally
- [ ] tcpdump used to verify traffic is actually flowing
- [ ] iptables rules audited and cleaned up
- [ ] All changes deployed via GitHub Actions
- [ ] Handover README written for the support team
```

---

## Session Goals

By the end of this session you will have:

- Rebuilt the session environment from scratch using a reusable bootstrap script
- Audited a live server's network state using `ss`, `netstat`, `ip`, and `iptables`
- Used `tcpdump` to capture and inspect real network traffic
- Configured `ufw` (Uncomplicated Firewall) with a clean, documented ruleset
- Understood the relationship between `ufw`, `iptables`, and the Linux kernel's `netfilter`
- Diagnosed and fixed both external connectivity and internal service communication
- Deployed the firewall configuration via GitHub Actions to EC2

Networking is the skill that separates a competent Linux engineer from an exceptional one. Almost every production incident has a network dimension — packet drops, wrong ports, misconfigured firewalls, routing issues. The tools in this session are tools you will reach for on every engagement.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Session Bootstrap — Recreating the Environment](#session-bootstrap--recreating-the-environment)
3. [Prerequisites](#prerequisites)
4. [Step 1 — Audit the Current Network State (Before Touching Anything)](#step-1--audit-the-current-network-state-before-touching-anything)
5. [Step 2 — Capture Live Traffic with tcpdump](#step-2--capture-live-traffic-with-tcpdump)
6. [Step 3 — Understand the Firewall Stack: netfilter, iptables, and ufw](#step-3--understand-the-firewall-stack-netfilter-iptables-and-ufw)
7. [Step 4 — Audit and Document the Broken iptables State](#step-4--audit-and-document-the-broken-iptables-state)
8. [Step 5 — Configure ufw with a Clean Ruleset](#step-5--configure-ufw-with-a-clean-ruleset)
9. [Step 6 — Verify Connectivity End-to-End](#step-6--verify-connectivity-end-to-end)
10. [Step 7 — Deploy via GitHub Actions to AWS EC2](#step-7--deploy-via-github-actions-to-aws-ec2)
11. [Step 8 — Write the Handover Document](#step-8--write-the-handover-document)
12. [Step 9 — Commit Your Work to GitHub](#step-9--commit-your-work-to-github)
13. [Verification Checklist](#verification-checklist)
14. [Troubleshooting Reference](#troubleshooting-reference)
15. [What You Learned This Session](#what-you-learned-this-session)
16. [Go Deeper](#go-deeper)
17. [Next Session](#next-session)

---

## Architecture Overview

```
INTERNET
    │
    │ HTTP:80 / HTTPS:443
    ▼
┌──────────────────────────────────────────────────────────────────┐
│  AWS Security Group (first layer — AWS network level)            │
│  Allows: 22, 80, 443 from 0.0.0.0/0                             │
│  Allows: 9100 from Ops IP only                                   │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│  AWS EC2 — Ubuntu 22.04                                          │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Linux Kernel — netfilter (second layer — OS level)        │  │
│  │                                                            │  │
│  │  ufw → iptables rules → netfilter chains                   │  │
│  │                                                            │  │
│  │  INPUT chain:                                              │  │
│  │  ├── ALLOW  tcp:22   from 0.0.0.0/0  (SSH)                │  │
│  │  ├── ALLOW  tcp:80   from 0.0.0.0/0  (HTTP)               │  │
│  │  ├── ALLOW  tcp:443  from 0.0.0.0/0  (HTTPS)              │  │
│  │  ├── ALLOW  tcp:9100 from OPS_IP/32  (node_exporter)      │  │
│  │  ├── ALLOW  lo (loopback — internal services)              │  │
│  │  └── DROP   everything else                                │  │
│  │                                                            │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │  Services (bootstrapped at session start)            │  │  │
│  │  │  ├── myapp        :8080  (loopback only)             │  │  │
│  │  │  ├── node_exporter:9100  (managed by systemd)        │  │  │
│  │  │  └── nginx        :80    (public-facing proxy)       │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘

Ops Workstation ──SSH:22──────────→ EC2 (SSH access)
Ops Workstation ──HTTP:9100───────→ EC2 (node_exporter metrics)
Internet        ──HTTP:80─────────→ EC2 → nginx → myapp:8080
```

**Why there are two firewall layers:** AWS Security Groups operate at the hypervisor level, they filter traffic before it ever reaches the operating system. `ufw`/`iptables` operate inside the OS kernel. Both must allow traffic for a connection to succeed. A common mistake is fixing one layer and forgetting the other. In this session the Security Group is correctly configured, the break is at the OS firewall layer.

---

## Session Bootstrap — Recreating the Environment

**What we are doing and why:** In a professional engagement, a server is long-lived and carries state from previous work. In this training series, you terminate the EC2 instance after each session to manage AWS costs, which is the right practice. That means each session must begin by rebuilding the environment to the state it would have been in had the server been running continuously.

This is itself a valuable skill. A field engineer is often asked to reproduce a client's environment, stand up a staging server that mirrors production, or recover from a terminated instance. The ability to codify an environment as a script, and rebuild it in minutes, is the difference between a professional and someone who "just does things manually".

### What we need to recreate for Session 4

The following services were set up in Sessions 1 and 3 and must be running before the firewall work begins:

| Service | Session origin | Port | Purpose |
|---|---|---|---|
| `node_exporter` | Session 1 | 9100 | Prometheus metrics exporter |
| `myapp` (simulated) | Session 3 | 8080 | The client application |
| `nginx` | Session 4 new | 80 | Reverse proxy (new this session) |

We also need to recreate the **broken firewall state** that the scenario describes, a misconfigured iptables that blocks HTTP/HTTPS. The bootstrap script does this deliberately so you practice diagnosing and fixing a real problem, not a clean environment.

### Bootstrap Phase 1 — Provision the EC2 instance with Terraform

If you still have your Terraform files from Session 1, you can reuse them with one change: the security group needs port 80 and 443 opened. Navigate to your Session 1 Terraform directory and update the security group.

```bash
cd cloud-field-engineer-labs/session-01-linux-tuning/terraform/
```

Open `main.tf` and add these two ingress blocks to the `aws_security_group` resource, alongside the existing SSH and port 9100 rules:

```hcl
# Add inside the aws_security_group "lab_sg" resource block:

# Allow HTTP from anywhere — the web application
ingress {
  description = "HTTP web traffic"
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

# Allow HTTPS from anywhere — for when TLS is configured (Session 6)
ingress {
  description = "HTTPS web traffic"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
```

Then deploy:

```bash
terraform init    # Re-initialise in case provider versions changed
terraform plan    # Review — you should see 2 security group rules being added
terraform apply   # Confirm with 'yes'

# Save your new server IP
export SERVER_IP=$(terraform output -raw instance_public_ip)
echo "New server IP: $SERVER_IP"
```

> Why update the Terraform file rather than adding the rules in the AWS console? Because the Terraform state file (`terraform.tfstate`) tracks every resource Terraform manages. If you add rules manually in the console, the next `terraform apply` will remove them, it will see them as "drift" from the declared state. Always make infrastructure changes in code.

### Bootstrap Phase 2 — Create and run the environment setup script

Create a bootstrap script that installs and configures everything Sessions 1 and 3 built, plus introduces the broken firewall state the scenario requires.

In your repository, create this file:

```bash
mkdir -p session-04-networking/scripts
nano session-04-networking/scripts/bootstrap-session4.sh
```

```bash
#!/usr/bin/env bash
# session-04-networking/scripts/bootstrap-session4.sh
#
# Bootstraps the EC2 instance to the state it would be in after Sessions 1-3,
# then introduces the broken firewall condition that Session 4 diagnoses and fixes.
#
# Run once on a fresh Ubuntu 22.04 instance:
#   sudo bash bootstrap-session4.sh
#
# What this script builds:
#   - node_exporter v1.7.0 (Session 1)
#   - A simulated myapp service on port 8080 (Session 3)
#   - nginx as a reverse proxy on port 80 (new in Session 4)
#   - Kernel tuning from Session 1
#   - A deliberately broken iptables configuration (the Session 4 scenario)

set -euo pipefail

echo "======================================================"
echo " Session 4 Bootstrap — RetailEdge Lab Environment"
echo " $(date --iso-8601=seconds)"
echo "======================================================"

# ── PHASE 1: SYSTEM UPDATES AND TOOLS ────────────────────────────────────────
echo ""
echo "[Phase 1] Updating system and installing tools..."

apt-get update -y
apt-get upgrade -y
apt-get install -y \
    htop \
    iotop \
    sysstat \
    net-tools \
    curl \
    wget \
    vim \
    jq \
    tree \
    tcpdump \
    nginx \
    ufw

echo "[Phase 1] Done."

# ── PHASE 2: KERNEL TUNING (from Session 1) ──────────────────────────────────
echo ""
echo "[Phase 2] Applying kernel tuning (Session 1)..."

cat > /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
# Canonical Lab — Session 1 kernel tuning
# Applied for: RetailEdge Ltd
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

sysctl --system > /dev/null

echo "[Phase 2] Done."

# ── PHASE 3: NODE_EXPORTER (from Session 1) ──────────────────────────────────
echo ""
echo "[Phase 3] Installing node_exporter v1.7.0 (Session 1)..."

NODE_EXPORTER_VERSION="1.7.0"

# Create the dedicated service user
# useradd will fail if the user already exists — the || true prevents the script
# from exiting if we are re-running on an existing server
useradd --system --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
mv node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*

# Write the systemd unit file
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
    --web.listen-address=:9100 \
    --collector.systemd \
    --collector.processes
Restart=on-failure
RestartSec=5s
PrivateTmp=yes
ProtectSystem=full
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

echo "[Phase 3] Done. node_exporter running on :9100"

# ── PHASE 4: SIMULATED MYAPP SERVICE (from Session 3) ────────────────────────
echo ""
echo "[Phase 4] Setting up simulated myapp service (Session 3)..."
# In a real engagement, the client's application would already be installed.
# Here we simulate it with a minimal Python HTTP server so all the networking
# and systemd concepts apply to a real running process.

# Create the dedicated service user
useradd --system --no-create-home --shell /bin/false myappuser 2>/dev/null || true

# Create the app directory and a minimal application
mkdir -p /opt/myapp
mkdir -p /var/log/myapp

cat > /opt/myapp/app.py << 'APPEOF'
#!/usr/bin/env python3
"""
Simulated RetailEdge myapp for Canonical CFE Training — Session 4
Listens on 127.0.0.1:8080 (loopback only — not accessible from outside directly)
All external traffic reaches it via nginx reverse proxy on port 80.
"""
import http.server
import socketserver
import logging
import os

LOG_FILE = "/var/log/myapp/app.log"
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)

class AppHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        logging.info(f"GET {self.path} from {self.client_address[0]}")
        body = b"""{"status": "ok", "service": "RetailEdge myapp", "session": 4}"""
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Suppress default stdout logging — we use our own file logger
        pass

PORT = 8080
# Bind to 127.0.0.1 only — myapp is internal, nginx proxies to it
with socketserver.TCPServer(("127.0.0.1", PORT), AppHandler) as httpd:
    logging.info(f"myapp started on 127.0.0.1:{PORT}")
    httpd.serve_forever()
APPEOF

chmod +x /opt/myapp/app.py
chown -R myappuser:myappuser /opt/myapp
chown -R myappuser:adm /var/log/myapp

# Write the systemd unit file for myapp
cat > /etc/systemd/system/myapp.service << 'EOF'
[Unit]
Description=RetailEdge Application (simulated — Session 4)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=myappuser
Group=myappuser
WorkingDirectory=/opt/myapp
ExecStart=/usr/bin/python3 /opt/myapp/app.py
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp
Restart=on-failure
RestartSec=10s
StartLimitInterval=300s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable myapp.service
systemctl start myapp.service

echo "[Phase 4] Done. myapp running on 127.0.0.1:8080"

# ── PHASE 5: NGINX REVERSE PROXY ─────────────────────────────────────────────
echo ""
echo "[Phase 5] Configuring nginx as reverse proxy for myapp..."
# nginx listens on port 80 (public) and forwards requests to myapp on port 8080 (loopback).
# This is the standard pattern for production web services:
# - nginx handles TLS termination, static files, and connection management
# - The application process only deals with application logic
# - The application never needs to run as root (port 80 requires root without authbind)

cat > /etc/nginx/sites-available/myapp << 'EOF'
server {
    listen 80;
    server_name _;   # Match any hostname — fine for a lab

    location / {
        # Forward all requests to myapp running on loopback
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF

# Enable the site by creating a symlink in sites-enabled
# Disable the default site that ships with nginx
ln -sf /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/myapp
rm -f /etc/nginx/sites-enabled/default

# Test the config before reloading — never reload nginx without testing first
nginx -t

systemctl enable nginx
systemctl restart nginx

echo "[Phase 5] Done. nginx reverse proxy running on :80 → 127.0.0.1:8080"

# ── PHASE 6: JOURNALD PERSISTENCE (from Session 3) ───────────────────────────
echo ""
echo "[Phase 6] Configuring journald persistence (Session 3)..."

mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal

cat > /etc/systemd/journald.conf << 'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=500M
SystemKeepFree=100M
SystemMaxFileSize=50M
MaxRetentionSec=1month
ForwardToSyslog=no
EOF

systemctl restart systemd-journald

echo "[Phase 6] Done."

# ── PHASE 7: LOGROTATE (from Session 3) ──────────────────────────────────────
echo ""
echo "[Phase 7] Configuring logrotate for myapp (Session 3)..."

cat > /etc/logrotate.d/myapp << 'EOF'
/var/log/myapp/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 myappuser adm
    sharedscripts
    postrotate
        systemctl kill -s HUP myapp.service 2>/dev/null || true
    endscript
}
EOF

echo "[Phase 7] Done."

# ── PHASE 8: BREAK THE FIREWALL (the Session 4 scenario) ────────────────────
echo ""
echo "[Phase 8] Introducing the broken firewall state (Session 4 scenario)..."
# This phase deliberately replicates what the junior engineer did:
# Set the default INPUT policy to DROP without adding HTTP/HTTPS allow rules.
# This is the exact broken state that Session 4 asks you to diagnose and fix.
#
# IMPORTANT: SSH is explicitly allowed first so you do not lose your connection.
# In the real incident, SSH stayed working because the junior engineer's session
# kept the connection alive — but new connections to port 80/443/9100 were blocked.

# Ensure ufw is disabled so we are working with raw iptables
ufw --force disable 2>/dev/null || true

# Allow SSH explicitly so we do not lock ourselves out
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Now set the default policy to DROP — this blocks everything not explicitly allowed above
# This means: HTTP (80), HTTPS (443), and node_exporter (9100) are all silently dropped
iptables -P INPUT DROP

echo "[Phase 8] Done. Broken firewall state applied."
echo "          Ports 80, 443, and 9100 are now BLOCKED."
echo "          SSH (22) is still accessible."

# ── FINAL SUMMARY ─────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Bootstrap Complete"
echo "======================================================"
echo ""
echo " Services running:"
systemctl is-active node_exporter && echo "  ✓ node_exporter  :9100 (blocked by firewall)" || echo "  ✗ node_exporter FAILED"
systemctl is-active myapp.service && echo "  ✓ myapp          127.0.0.1:8080 (loopback only)" || echo "  ✗ myapp FAILED"
systemctl is-active nginx && echo "  ✓ nginx          :80 (blocked by firewall)" || echo "  ✗ nginx FAILED"
echo ""
echo " Firewall state (broken — Session 4 will fix this):"
iptables -L INPUT --line-numbers -n
echo ""
echo " Session 4 is ready. Begin with Step 1: Audit the Current Network State."
echo "======================================================"
```

### Bootstrap Phase 3 — Run the script on your fresh EC2 instance

```bash
# From your local machine, copy the bootstrap script to the server
scp -i ~/.ssh/canonical_lab_key \
    session-04-networking/scripts/bootstrap-session4.sh \
    ubuntu@$SERVER_IP:/tmp/bootstrap-session4.sh

# SSH into the server
ssh -i ~/.ssh/canonical_lab_key ubuntu@$SERVER_IP

# Run the bootstrap script as root
# sudo -E preserves the current user's environment variables
sudo bash /tmp/bootstrap-session4.sh
```

The script will run for approximately 3–5 minutes. Watch the phase headings to track progress. When it completes, you will see a summary confirming all three services are running and the broken firewall state is active.

### Bootstrap Phase 4 — Update GitHub Secrets with the new IP

Every time you terminate and recreate the EC2 instance, the public IP address changes. The GitHub Secrets must be updated before the Actions workflow will work.

```bash
# Find the new IP (from the Terraform output or the AWS console)
echo $SERVER_IP
```

Update in GitHub: **Repository → Settings → Secrets and variables → Actions**

| Secret | New value |
|---|---|
| `EC2_HOST` | The new public IP from `terraform output instance_public_ip` |
| `EC2_USER` | `ubuntu` (this never changes) |
| `EC2_SSH_KEY` | Only update if you regenerated your key pair (unlikely) |

> Why does the IP change? EC2 instances receive a public IP from AWS's pool of addresses when they start. When you terminate and recreate, you get a different IP from the pool. The fix for production is an **Elastic IP** (a static IP address that stays assigned to your account) or a DNS name pointed at the instance. For this training series, updating the GitHub Secret after each session is the correct approach.

### Verifying the bootstrap is complete

Before proceeding to Step 1 of the session, confirm this checklist from your SSH session:

```bash
# All three services should be active
systemctl is-active node_exporter
systemctl is-active myapp.service
systemctl is-active nginx

# Confirm the broken firewall is in place (ports 80, 443, 9100 should be unreachable)
# From your LOCAL MACHINE (not the SSH session):
curl --connect-timeout 5 http://$SERVER_IP/
# Expected: curl: (28) Connection timed out — firewall is DROP, not REJECT

# SSH should still work (confirmed by the fact you are connected)
echo "SSH is working"

# node_exporter should be unreachable from outside
curl --connect-timeout 5 http://$SERVER_IP:9100/metrics
# Expected: curl: (28) Connection timed out
```

If all of the above matches expectations — services running, HTTP blocked, SSH open — your environment exactly matches the scenario described in the ticket. You are ready to begin the session.

---

## Prerequisites

Now that the bootstrap is complete, the following are satisfied:

- ✅ AWS EC2 instance running Ubuntu 22.04 LTS with all session dependencies
- ✅ `node_exporter` running on port 9100 (installed by bootstrap, blocked by firewall)
- ✅ `myapp.service` running on `127.0.0.1:8080` (simulated, managed by systemd)
- ✅ `nginx` running on port 80 (blocked by broken firewall)
- ✅ Broken firewall state active — INPUT policy is DROP with no HTTP/HTTPS rules
- ✅ SSH access confirmed working
- ✅ GitHub Secrets updated: `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`
- ✅ Your ops workstation IP: run `curl ifconfig.me` to confirm it

---

## Step 1 — Audit the Current Network State (Before Touching Anything)

**What we are doing and why:** The most dangerous thing a field engineer can do is start making changes without first understanding the current state. This is especially true for networking, a wrong rule can lock you out of the server entirely, with no way back in. Spend the first 20 minutes of any network incident collecting facts, not applying fixes. Document everything you find. This creates your baseline and your evidence trail.

### 1a. Identify every listening port and which process owns it

```bash
# ss = Socket Statistics — the modern replacement for netstat
# -t = TCP sockets only
# -u = include UDP sockets
# -l = listening sockets only (not established connections)
# -p = show which process owns each socket (requires sudo for other users' processes)
# -n = show port numbers, not service names — avoids ambiguity (e.g. "http" vs "80")
sudo ss -tulpn
```

Expected output on our bootstrapped server:

```
Netid  State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
tcp    LISTEN  0       128     0.0.0.0:22           0.0.0.0:*          sshd
tcp    LISTEN  0       511     127.0.0.1:8080       0.0.0.0:*          python3 (myapp)
tcp    LISTEN  0       128     0.0.0.0:80           0.0.0.0:*          nginx
tcp    LISTEN  0       128     0.0.0.0:9100         0.0.0.0:*          node_exporter
```

Read this output carefully. The `Local Address` column tells you exactly what each service is reachable on:

| Local Address | Meaning | Implication |
|---|---|---|
| `0.0.0.0:80` | Listening on all interfaces | Reachable from anywhere — subject to firewall |
| `127.0.0.1:8080` | Listening on loopback only | Only reachable from the same machine, no firewall rule will make it reachable from outside |
| `0.0.0.0:9100` | Listening on all interfaces | Reachable from anywhere, firewall should restrict this |

This output already tells us something important: the application processes are healthy. Every service is listening on the right port. The problem is not the application, it is the firewall.

> This is the most common diagnostic mistake: assuming the application is broken when traffic cannot reach it. `ss -tulpn` tells you in seconds whether the problem is the application (not listening) or the network/firewall (listening but blocked). If you see the port in `ss`, the application is fine. Look at the firewall next.

```bash
# Show all currently established connections, who is talking to this server right now?
sudo ss -tnp state established
# On a fresh bootstrapped server you will see only your SSH connection.
# On a production server, you would also see database connections, monitoring agents, etc.
```

### 1b. Inspect the network interfaces and routing table

```bash
# Show all network interfaces and their assigned IP addresses
ip addr show
```

You will see three interfaces:

- `lo` — loopback (`127.0.0.1/8`). This is the virtual interface that allows the server to talk to itself. myapp is bound here.
- `eth0` (or `ens5` on newer instance types) — the primary network interface with the private EC2 IP (e.g. `10.0.1.45`). This is how traffic from the internet reaches the server after AWS translates the public IP.
- No public IP on the interface — EC2 performs Network Address Translation (NAT) at the AWS level. The instance never sees its own public IP on an interface.

```bash
# Show the routing table, how does the server decide where to send packets?
ip route show
```

```
default via 10.0.1.1 dev eth0 proto dhcp src 10.0.1.45 metric 100
10.0.1.0/24 dev eth0 proto kernel scope link src 10.0.1.45
```

The `default` route is where all outbound traffic goes that does not match a more specific destination. On EC2, this points to the VPC router (`10.0.1.1`), which then routes to the internet gateway. If this route is missing, the server cannot reach the internet, and reply packets cannot get back to clients.

```bash
# Test basic connectivity from the server outward
ping -c 3 8.8.8.8
# Can we reach Google's DNS server? Tests internet routing.

ping -c 3 google.com
# Can we resolve and reach google.com? Tests DNS resolution + routing.

curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080
# Can myapp respond on the loopback interface? Tests the app itself.
# Expected: 200, myapp is healthy on loopback even though port 80 is blocked
```

### 1c. Check DNS resolution

```bash
# Test DNS resolution
nslookup google.com

# Check which DNS server the system is using
cat /etc/resolv.conf
# On Ubuntu 22.04 with systemd-resolved, you will see 127.0.0.53
# This is the local DNS stub resolver, it forwards requests to AWS's DNS (169.254.169.253)
```

> Why check DNS during a firewall investigation? Broken DNS looks like a connectivity problem. If `ping 8.8.8.8` works but `ping google.com` fails, the problem is DNS, not the firewall. These are completely different problems with different fixes. Systematically separating IP connectivity from DNS resolution is a discipline that saves diagnostic time on every incident.

---

## Step 2 — Capture Live Traffic with tcpdump

**What we are doing and why:** `tcpdump` captures raw network packets at the OS level. It lets you see exactly what traffic is arriving, what is being rejected, and what the firewall is dropping, in real time. When someone says "I cannot reach port 80", tcpdump tells you whether packets are even arriving at the server. If they arrive but get dropped, you see them in tcpdump but the client never gets a response. If they do not arrive at all, the problem is upstream of the OS.

### 2a. Install tcpdump

```bash
# tcpdump was installed by the bootstrap script, but confirm it is available
which tcpdump
# Expected: /usr/sbin/tcpdump
# If not found: sudo apt-get install -y tcpdump
```

### 2b. Capture traffic and interpret what you see

Open a second terminal, SSH into the server, and run the capture. Use your first terminal to generate traffic from your laptop.

```bash
# Terminal 1 (on the server): watch for any traffic arriving on port 80
sudo tcpdump -i eth0 -n port 80
# -i eth0: listen on the primary network interface
# -n: do not resolve IPs or port names — faster and less ambiguous
# port 80: filter for traffic to or from port 80 only

# Terminal 2 (your laptop): try to connect
curl --connect-timeout 5 http://$SERVER_IP/
# Expected: times out — the firewall is DROPping packets
```

In the tcpdump output on the server, you will see:

```
IP YOUR_IP.54321 > SERVER_IP.80: Flags [S], seq 123456789, ...
IP YOUR_IP.54321 > SERVER_IP.80: Flags [S], seq 123456789, ...
IP YOUR_IP.54321 > SERVER_IP.80: Flags [S], seq 123456789, ...
```

You see SYN (`[S]`) packets arriving from your laptop, the first step of the TCP three-way handshake. But you see no SYN-ACK (`[S.]`) being sent back. The server is receiving the packets but not responding. This is the signature of a DROP firewall rule: the packet arrives at the OS, is inspected by netfilter, and is silently discarded.

**The three scenarios tcpdump reveals:**

| tcpdump shows | Client result | Root cause |
|---|---|---|
| SYN packets arriving, then RST sent back | "Connection refused" immediately | Port is open to the OS but nothing is listening on it |
| SYN packets arriving, no response | `curl` hangs then times out | Firewall is DROPping the packet, our current situation |
| No packets at all | `curl` times out immediately | AWS Security Group is blocking, or routing issue upstream of the OS |
| SYN arriving, SYN-ACK sent, ACK received | Connection succeeds | Traffic is flowing, problem is at the application layer |

> The DROP vs REJECT distinction has a user experience implication that field engineers must understand. A DROP rule discards the packet silently, the client sends SYN, waits for the full TCP timeout (usually 75 seconds), then gives up. A REJECT rule sends back an ICMP "port unreachable" immediately, the client fails in milliseconds. From a user perspective, DROP looks like "the server is very slow" while REJECT looks like "connection refused". In our case, the junior engineer used DROP (the default iptables behaviour when no rule matches), which is why clients experience extreme latency rather than an immediate error.

### 2c. Save a capture as evidence

```bash
# Capture 30 packets on port 80 and save to a file
# -c 30: stop after 30 packets
# -w: write to a file in pcap format (readable by Wireshark)
sudo tcpdump -i eth0 -n -c 30 port 80 -w /tmp/port80-broken-state.pcap

# Generate the traffic while the capture runs (from your laptop):
# curl --connect-timeout 5 http://$SERVER_IP/

# Copy the capture to your laptop for the handover record
# (run this from your laptop, not the SSH session)
scp -i ~/.ssh/canonical_lab_key ubuntu@$SERVER_IP:/tmp/port80-broken-state.pcap ./
```

This `.pcap` file is your evidence that you diagnosed the problem before touching the firewall. It goes into the handover document.

---

## Step 3 — Understand the Firewall Stack: netfilter, iptables, and ufw

**What we are doing and why:** Before changing any firewall rules, you need to understand the stack you are working with. Many engineers treat `ufw` and `iptables` as competing tools they are not. They are layers of the same system. Misunderstanding this relationship leads to rules that conflict, cancel each other out, or disappear on reboot.

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 3: ufw (Uncomplicated Firewall)                          │
│  A user-facing abstraction. You write: "allow port 80".         │
│  ufw translates this into iptables rules and applies them.      │
│  Rules survive reboots. Best tool for operational management.   │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: iptables                                              │
│  A command-line interface to the kernel's netfilter framework.  │
│  More powerful and flexible than ufw, but more complex.         │
│  ufw generates iptables rules under the hood.                   │
│  Manual iptables rules do NOT survive reboot by default.        │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1: netfilter (Linux kernel)                              │
│  The actual packet filtering engine inside the kernel.          │
│  iptables and nftables are both interfaces to configure it.     │
│  This is where packets are actually accepted or dropped.        │
└─────────────────────────────────────────────────────────────────┘
```

**The key operational rule:** Pick one tool to manage the firewall and use only that tool. The junior engineer in this scenario mixed manual `iptables` commands with the existing `ufw` setup. When you mix them, you get conflicts that are extremely difficult to debug. Our fix: audit the `iptables` mess, wipe it, and hand sole control to `ufw`.

**Understanding iptables tables and chains:**

iptables organises rules into tables, and each table contains chains:

| Table | Purpose | When you use it |
|---|---|---|
| `filter` | Accept, reject, or drop packets | Almost always, this is the firewall table |
| `nat` | Port forwarding and IP masquerading | Load balancers, routers, port redirects |
| `mangle` | Modify packet headers (TTL, QoS) | Advanced traffic shaping, rarely needed |

Within the `filter` table, traffic flows through three built-in chains:

| Chain | When a packet hits it |
|---|---|
| `INPUT` | Packet is destined for this machine |
| `OUTPUT` | Packet was created by this machine |
| `FORWARD` | Packet is passing through (if machine is a router) |

> For an application server, you almost exclusively manage the `INPUT` chain. A request arriving from the internet on port 80 hits the `INPUT` chain. The chain walks through its rules top to bottom, and the first rule that matches decides the fate of the packet: ACCEPT (let it through), DROP (discard silently), or REJECT (discard and notify the sender).

---

## Step 4 — Audit and Document the Broken iptables State

**What we are doing and why:** We look at the exact iptables rules that are causing the problem. This is not optional, we document the broken state before fixing it. The handover document must explain what was wrong, and you need to understand the exact rules before you can safely remove them.

```bash
# List all rules in the filter table with full details
# -L = list rules
# -v = verbose: show packet/byte counters, interface names, and options
# -n = numeric: show IPs and port numbers, not hostnames and service names
# --line-numbers = show rule numbers (needed if you want to delete specific rules)
sudo iptables -L -v -n --line-numbers
```

You will see output like this:

```
Chain INPUT (policy DROP)     ← THE PROBLEM: default is DROP, not ACCEPT
num   pkts bytes target  prot opt in     out     source    destination
1      145 11640 ACCEPT  tcp  --  *      *       0.0.0.0/0 0.0.0.0/0  tcp dpt:22
2       87  6260 ACCEPT  all  --  *      *       0.0.0.0/0 0.0.0.0/0  state RELATED,ESTABLISHED
3        4   336 ACCEPT  all  --  lo     *       0.0.0.0/0 0.0.0.0/0

Chain FORWARD (policy ACCEPT)
(empty)

Chain OUTPUT (policy ACCEPT)
(empty)
```

The critical line is `Chain INPUT (policy DROP)`. This is the default policy, what happens to a packet if no rule matches it. With `DROP` as the policy, every packet that does not match one of the three explicit rules is silently discarded. The three existing rules allow SSH (22), established connections, and loopback, but there is no rule for port 80, 443, or 9100.

```bash
# Save the complete broken state to a file, this is your rollback point
# and your evidence for the handover document
sudo iptables-save > /tmp/iptables-broken-state.txt
cat /tmp/iptables-broken-state.txt

# Also check the nat table for any unexpected port forwarding
sudo iptables -t nat -L -v -n --line-numbers
```

> `iptables-save` outputs rules in a format that `iptables-restore` can read back exactly. Always save before changing. If you break SSH connectivity during a firewall change, you can recover via AWS Systems Manager Session Manager (which does not use the OS network stack) and run `sudo iptables-restore < /tmp/iptables-broken-state.txt`.

---

## Step 5 — Configure ufw with a Clean Ruleset

**What we are doing and why:** We flush the broken iptables rules and configure `ufw` from scratch with a clean, fully documented ruleset. Every rule gets a comment explaining why it exists, not for the machine, but for the next engineer who reads it. A firewall without documented reasoning is a liability.

### 5a. Confirm your SSH session will survive

```bash
# Check your current public IP, this is what appears as the source in SSH connections
# Run this from your LOCAL MACHINE terminal, not the SSH session
curl ifconfig.me
# Note this IP, if you need to add it explicitly to a rule, this is the value
```

> The cardinal rule of remote firewall management: if you are about to enable a default-deny firewall, the rule that allows your SSH connection must already be in place before you enable it. In our case, `ufw allow ssh` is always the first rule we add. If you enable `ufw` before adding the SSH rule, your current session survives (existing TCP connections are not dropped by a new firewall rule) but you will not be able to reconnect if the session drops.

### 5b. Reset ufw to a clean state

```bash
# Disable ufw completely, this removes ufw's iptables rules
# (the broken manual rules we documented in Step 4 are separate and will be cleared in 5c)
sudo ufw disable

# Reset all ufw rules to factory defaults, removes every custom rule
# Type 'y' to confirm
sudo ufw reset

# Now flush the manually-added iptables rules from the bootstrap script
# -F = flush (delete all rules in the chain)
sudo iptables -F INPUT
sudo iptables -F OUTPUT
sudo iptables -F FORWARD

# Reset the default policies to ACCEPT, safe starting point
sudo iptables -P INPUT ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -P FORWARD ACCEPT

# Verify we are at a clean state
sudo iptables -L -v -n
# Expected: all chains empty, all policies ACCEPT
```

### 5c. Set secure default policies

```bash
# Deny all incoming traffic by default.
# Security principle: default deny, explicit allow.
# Every service that needs external access must have a rule, nothing is open by accident.
sudo ufw default deny incoming

# Allow all outgoing traffic by default.
# The server must be able to initiate connections outward:
# package downloads (apt), external APIs, DNS queries, NTP time sync.
sudo ufw default allow outgoing
```

### 5d. Add rules, most important first

```bash
# ── Rule 1: SSH ────────────────────────────────────────────────────────────────
# ALWAYS add this first, before enabling ufw.
# 'ssh' is a named service, ufw resolves it to 22/tcp via /etc/services
# This is equivalent to: sudo ufw allow 22/tcp
sudo ufw allow ssh comment "SSH operations access"

# ── Rule 2: HTTP ───────────────────────────────────────────────────────────────
# Allow inbound HTTP traffic from the internet.
# nginx on port 80 receives this traffic and proxies it to myapp.
sudo ufw allow http comment "HTTP — proxied to myapp via nginx"

# ── Rule 3: HTTPS ──────────────────────────────────────────────────────────────
# Allow HTTPS traffic. The nginx rule exists, TLS termination is configured in Session 6.
# Add the firewall rule now — it is easier to allow a port early than to debug
# why HTTPS is not working after TLS is configured.
sudo ufw allow https comment "HTTPS — TLS termination via nginx (Session 6)"

# ── Rule 4: node_exporter — restricted to ops IP only ─────────────────────────
# The Prometheus metrics endpoint reveals sensitive system information.
# Never expose it to the public internet.
# Replace YOUR_OPS_IP with the output of: curl ifconfig.me
OPS_IP=$(curl -s ifconfig.me)
sudo ufw allow from $OPS_IP to any port 9100 proto tcp \
    comment "node_exporter metrics — ops workstation only"

# The 'comment' keyword embeds the reason in the rule itself.
# Run 'sudo ufw status verbose' and you will see the comment alongside each rule.
# This is non-optional in professional environments.

# ── Rule 5: Loopback interface ─────────────────────────────────────────────────
# Allow all traffic on the loopback interface (127.0.0.1).
# nginx forwards requests to myapp via loopback.
# If this rule is missing, nginx cannot reach myapp even though they are on the same machine.
sudo ufw allow in on lo comment "loopback — nginx to myapp internal communication"
```

### 5e. Enable ufw

```bash
# Enable ufw, this writes all the rules to iptables and registers ufw to start at boot.
# Type 'y' when prompted about SSH connections.
sudo ufw enable

# Review the final ruleset
sudo ufw status verbose
```

Expected output:

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere                   # SSH operations access
80/tcp                     ALLOW IN    Anywhere                   # HTTP — proxied to myapp via nginx
443/tcp                    ALLOW IN    Anywhere                   # HTTPS — TLS termination via nginx
9100/tcp                   ALLOW IN    YOUR_OPS_IP                # node_exporter metrics — ops only
Anywhere on lo             ALLOW IN    Anywhere                   # loopback — internal comms
```

### 5f. Verify ufw is enabled at boot

```bash
# ufw must start before services that depend on network protection
sudo systemctl is-enabled ufw
# Expected: enabled

sudo systemctl status ufw
# Expected: active (exited) — ufw applies rules and exits, it does not stay running
```

### 5g. Inspect the iptables rules ufw generated

```bash
# Show the actual iptables rules — this demystifies ufw completely
# Every ufw rule translates into one or more iptables rules
sudo iptables -L -v -n

# Compare before and after
diff /tmp/iptables-broken-state.txt <(sudo iptables-save)
```

This `diff` output is the exact evidence of what changed. It belongs in the handover document.

---

## Step 6 — Verify Connectivity End-to-End

**What we are doing and why:** A firewall change is not closed until every affected path is tested. This is not bureaucracy — it is professional practice. The test results are your proof of resolution. If a path still does not work, you have not finished.

### 6a. Test from the server itself (internal paths)

```bash
# Confirm all services are still listening
sudo ss -tulpn

# Test myapp responds on loopback (direct, not through nginx)
 -s http://127.0.0.1:8080
# Expected: {"status": "ok", "service": "RetailEdge myapp", "session": 4}

# Test nginx can reach myapp through loopback proxy (the full internal path)
curl -s http://127.0.0.1/
# Expected: same JSON response — nginx proxied the request to myapp successfully

# Test node_exporter responds locally
curl -s http://127.0.0.1:9100/metrics | head -5
# Expected: Prometheus metrics output
```

### 6b. Test from your laptop (external paths)

```bash
# Test HTTP is now accessible from the ternet
curl -v http://$SERVER_IP/
# Expected: 200 OK with JSON body from myapp

# Test node_exporter is accessible from your ops IP
curl -s http://$SERVER_IP:9100/metrics | head -5
# Expected: Prometheus metrics output

# Test SSH is still accessible
ssh -i ~/.ssh/canonical_lab_key -o ConnectTimeout=5 ubuntu@$SERVER_IP echo "SSH OK"
# Expected: SSH OK
```

### 6c. Use tcpdump to confirm the fix with packet evidence

```bash
# Terminal 1 (on the server): capture the traffic
sudo tcpdump -i eth0 -n port 80 -c 20

# Terminal 2 (your laptop): make a request
curl http://$SERVER_IP/
```

In the tcpdump output you should now see the complete TCP three-way handshake:

```
IP YOUR_IP.54321 > SERVER_IP.80: Flags [S]     ← SYN: your laptop opens the connection
IP SERVER_IP.80 > YOUR_IP.54321: Flags [S.]    ← SYN-ACK: server accepts (NEW — was missing before)
IP YOUR_IP.54321 > SERVER_IP.80: Flags [.]     ← ACK: handshake complete
IP YOUR_IP.54321 > SERVER_IP.80: Flags [P.]    ← PSH: HTTP GET request
IP SERVER_UR_IP.54321: Flags [P.]    ← PSH: HTTP response from nginx/myapp
```

The presence of `[S.]` (SYN-ACK) packets where there were none before is your definitive packet-level proof that the firewall rule was the problem and is now fixed.

---

## Step 7 — Deploy via GitHub Actions to AWS EC2

**What we are doing and why:** The firewall configuration we built manually must go into version control. If this server is ever rebuilt, and in this training series it is, at the start of every session, the rules mus reproducible from code with no manual steps. We encode the complete firewall configuration in a script, and GitHub Actions deploys and applies it automatically on every push.

### 7a. Create the idempotent firewall configuration script

```bash
nano session-04-networking/scripts/configure-firewall.sh
```

```bash
#!/usr/bin/env bash
# session-04-networking/scripts/configure-firewall.sh
#
# Configures ufw firewall rules for the RetailEdge EC2 instance.
# This script is IDEMPOTENT — safe to run multiple tis.
# Running it again produces the same result as running it once.
#
# Usage:
#   sudo bash configure-firewall.sh OPS_IP
#
# Example:
#   sudo bash configure-firewall.sh 41.58.100.200
#
# This script is deployed and executed by GitHub Actions on every push
# to main that modifies files in session-04-networking/.

set -euo pipefail

OPS_IP="${1:?Error: OPS_IP argument is required. Usage: configure-firewall.sh OPS_IP}"

echo "==> Configuring firewall for RetailEdge EC2"
echo "==> Ops IP: $OPS_IP"
echo "==> $(date --iso-8601=seconds)"

# Reset to a known-clean state
# --force skips the confirmation prompt — required for non-interactive use in CI/CD
echo "==> Resetting ufw..."
ufw --force disable
ufw --force reset

# Default policies: deny incoming, allow outgoing
echo "==> Setting default policies..."
ufw default deny incoming
ufw default allow outgoing

# Add rules in priority order
echo "==> Adding firewall rules..."

ufw allow ssh   comment "SSH access"
ufw allow http  comment "HTTP — proxied to myapp vianx"
ufw allow https comment "HTTPS — TLS termination via nginx"

ufw allow from "$OPS_IP" to any port 9100 proto tcp \
    comment "node_exporter — ops team only"

ufw allow in on lo \
    comment "loopback — internal service communication"

# Enable — this applies rules to iptables and marks ufw for boot
echo "==> Enabling ufw..."
ufw --force enable

# Report the final state
echo "==> Configuration complete."
ufw status verbose
```

```bash
chmod +x session-04-networking/scripts/configure-firewall.### 7b. Create the GitHub Actions workflow

```bash
mkdir -p .github/workflows
nano .github/workflows/deploy-session4.yml
```

```yaml
# .github/workflows/deploy-session4.yml
#
# Deploys the Session 4 firewall configuration to EC2.
# Triggered on any push to main that modifies files in session-04-networking/.

name: Deploy Session 4 — Firewall Configuration

on:
  push:
    branches:
      - main
    paths:
      - 'session-04-networking/**'
      - '.github/workflows/deploy-session4.yml'

jobs:
  deploy-rewall:
    name: Apply firewall config to EC2
    runs-on: ubuntu-latest

    steps:
      # Pull the repository code onto the Actions runner.
      # Without this, the runner has no access to our scripts.
      - name: Checkout repository
        uses: actions/checkout@v4

      # Load the SSH private key into the runner's ssh-agent.
      # Subsequent SSH and SCP commands authenticate without specifying a key file.
      - name: Set up SSH agent
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.EC2_SSH_KEY }}

      # Copy the firewall script to /tmp on the server.
      # SCP cannot sudo — we copy to /tmp first, then move with sudo in the next step.
      # -o StrictHostKeyChecking=no accepts the host key automatically —
      # required for non-interactive CI runs (the runner has never seen this host before).
      - name: Copy firewall script to EC2
        run: |
          scp -o StrictHostKeyChecking=no \
            session-04-networking/scripts/configfirewall.sh \
            ${{ secrets.EC2_USER }}@${{ secrets.EC2_HOST }}:/tmp/configure-firewall.sh

      # SSH in and apply the firewall configuration.
      # OPS_IP is stored as a secret — never hardcode an IP in a workflow file.
      - name: Apply firewall configuration
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key: ${{ secrets.EC2_SSH_KEY }}
          script: |
            set -e
            do mv /tmp/configure-firewall.sh /usr/local/bin/configure-firewall.sh
            sudo chmod +x /usr/local/bin/configure-firewall.sh
            sudo /usr/local/bin/configure-firewall.sh "${{ secrets.OPS_IP }}"
            echo "Firewall deployment complete."

      # Verify SSH is still accessible post-firewall change.
      # If this step fails (because the firewall locked out SSH), the workflow
      # fails and the team is notified immediately via GitHub notifications.
      - name: Smoke test — verifSSH is still accessible
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key: ${{ secrets.EC2_SSH_KEY }}
          script: |
            echo "Post-deployment SSH confirmation."
            sudo ufw status verbose
            echo "Firewall deployment verified."
```

Add `OPS_IP` to GitHub Secrets: **Repository → Settings → Secrets and variables → Actions → New repository secret**, name `OPS_IP`, valucurl ifconfig.me`.

---

## Step 8 — Write the Handover Document

```bash
mkdir -p session-04-networking/docs
cat > session-04-networking/docs/HANDOVER-TICKET-004.md << 'EOF'
# HANDOVER DOCUMENT
## TICKET-004: Network Diagnostics, Firewall Configuration & Connectivity Restoration

**Client:** RetailEdge Ltd
**Engineer:** [Your Name]
**Date:** [Date]
**Status:** Resolved — 48-hour monitoring period recommended

---

## Executive Summary

A junior engineer applied ad-hoc iptables commands that set the def INPUT
chain policy to DROP without adding corresponding ALLOW rules for HTTP and HTTPS.
All three application services (nginx on port 80, node_exporter on port 9100)
were reachable at the process level but silently dropped at the OS firewall level.
The application process (myapp) was healthy throughout — the failure was entirely
at the firewall layer.

Connectivity has been fully restored. The firewall has been rebuilt from scratch
using ufw with documented rules, committed to version control, and deploy via
GitHub Actions so future changes are reproducible and auditable.

---

## Diagnostic Evidence

Collected before any changes were made:

- `ss -tulpn` output confirmed all services (nginx, myapp, node_exporter, sshd)
  were listening on the correct ports. Application processes were healthy.
- `tcpdump` on port 80 confirmed SYN packets arriving from clients but no SYN-ACK
  being sent — signature of an iptables DROP rule (not a REJECT or process fault).
- `iptables -L -v -n` confirmed: Chain INPUT defat policy was DROP. No rules
  existed for ports 80, 443, or 9100. Three rules existed (SSH, ESTABLISHED, lo).
- Broken state saved to /tmp/iptables-broken-state.txt on the server.

---

## Root Cause

The following iptables command was run without prior planning:
    iptables -P INPUT DROP

This sets the default policy for all unmatched input packets to DROP.
Without corresponding ALLOW rules for ports 80, 443, and 9100, all
non-SSH traffic was silently discarded.

---

## Changes Made

| Component | Before | After |
|---|---|---|
| iptables INPUT default policy | DROP (misconfigured) | DENY via ufw (intentional, with explicit allows) |
| Port 80 (HTTP) | Blocked — no rule | ALLOW from anywhere |
| Port 443 (HTTPS) | Blocked — no rule | ALLOW from anywhere |
| Port 9100 (node_exporter) | Blocked — no rule | ALLOW from OPS_IP only |
| Loopback interface | Partially blocked | ALLOW all (nginx → myapp internal path) |
| SSH (port 22) | Allowed (existing rule) | ALLOW from anywhere (explicit ufw rule) |
|l management | Mixed iptables + ufw | ufw only (single-tool policy enforced) |
| Config in version control | No | Yes — deployed via GitHub Actions |

---

## Current Firewall Rules

| Port | Protocol | Source | Reason |
|---|---|---|---|
| 22 | TCP | Anywhere | SSH access |
| 80 | TCP | Anywhere | HTTP — proxied to myapp via nginx |
| 443 | TCP | Anywhere | HTTPS — TLS termination via nginx (Session 6) |
| 9100 | TCP | OPS_IP only | node_exporter — ops team only |
| All | All | Loopback only | nginpp internal communication |
| All (outbound) | All | Anywhere | Package updates, external APIs |

---

## Files Created

| Location | Purpose |
|---|---|
| /usr/local/bin/configure-firewall.sh | Idempotent firewall config script |
| .github/workflows/deploy-session4.yml | CI/CD deployment pipeline |

---

## How to Add Future Rules

Never use raw iptables on this server. Always use ufw:

    sudo ufw allow PORT/proto comment "reason for this rule"

After any manual change, update configure-firewall.sh in the GitHub repository
so the change is recorded and will be reapplied if the server is rebuilt.

---

## How to Roll Back

    sudo ufw disable
    # WARNING: removes all firewall rules. Only use in emergency.
    # To reapply: sudo /usr/local/bin/configure-firewall.sh YOUR_OPS_IP

---

## Support Team Diagnostic Commands

    sudo ufw status verbose              # Current firewall rules
    sudo tcpdump -i eth0 -n port 80      # Live traffic on port 80
    sudo ss -tulpn                       # All listening services
    sudo iptables -L INPUT -v -n         # Raw iptables INPUT chain
    curl -v http://127.0.0.1/            # Test nginx → myapp internal path
EOF
```

---

## Step 9 — Commit Your Work to GitHub

```bash
cd /path/to/cloud-field-engineer-labs/

git add session-04-networking/

git commit -m "session-04: network diagnostics, ufw configuration, and bootstrap script for TICKET-004

- Added bootstrap-session4.sh: rebuilds Sessions 1+3 environment from scratch
  (node_exporter, myapp, nginx, kerneling, journald, logrotate)
  and introduces broken iptables state matching the ticket scenario
- Documented full diagnostic process: ss, tcpdump, iptables audit
- Flushed broken iptables state, rebuilt clean ruleset with ufw
- Rules: SSH (any), HTTP (any), HTTPS (any), node_exporter (ops IP), loopback
- configure-firewall.sh: idempotent, commented, version-controlled
- GitHub Actions workflow: automated firewall deploy + SSH smoke test
- Full handover document with root cause, evidence, rollback, and rule rationale"

git push origin main
```

---

## Verification Checklist

```bash
# 1. Bootstrap completed successfully (services running)
systemctl is-active node_exporter myapp.service nginx
# Expected: active active active

# 2. ufw is active with correct rules
sudo ufw status verbose
# Expected: SSH, HTTP, HTTPS, 9100 (ops IP), loopback rules present

# 3. ufw starts at boot
sudo systemctl is-enabled ufw
# Expected: enabled

# 4. myapp responds on loopback
curl -s http://127.0.0.1:8080
# Expected: JSON response

# 5. nginx proxies to myapp correctly
curl -s http://127.0.0.1/
# Expected: same JSON response via nginx proxy

# 6. HTTP accessible from the internet (run from your laptop)
curl -s -o /dev/null -w "%{http_code}" http://$SERVER_IP/
# Expected: 200

# 7. node_exporter accessible from ops IP (run from your laptop)
curl -s -o /dev/null -w "%{http_code}" http://$SERVER_IP:9100/metrics
# Expected: 200

# 8. SSH accessible (run from your laptop)
ssh -i ~/.ssh/canonical_lab_key -o ConnectTimeout=5 ubuntu@$SERVER_IP echo "SSH OK"
# Expected: SSH OK

# 9. tcpdump shows SYN-ACK on port 80 (two terminals required)
# Terminal 1 (server): sudo tcpdump -i eth0 -n port 80 -c 10
# Terminal 2 (laptop): curl http://$SERVER_IP/
# Expected: [S.] SYN-ACK packets visible in tcpdump
```

---

## Troubleshooting Reference

| Symptom | Diagnostic command | Fix |
|---|---|---|
| Bootstrap script fails at Phase 3 (node_exporter download) | Check network: `curl -I github.com` | Verify EC2 has internet access — check route table aninternet gateway in Terraform |
| myapp.service fails to start | `journalctl -u myapp.service -n 30` | Check Python is installed: `python3 --version`; check `/opt/myapp/app.py` exists |
| nginx fails to start | `nginx -t` then `journalctl -u nginx -n 20` | Config syntax error — check `/etc/nginx/sites-enabled/myapp` |
| SSH locked out after firewall change | Use AWS Console → EC2 → Connect → Session Manager | Run `sudo iptables -P INPUT ACCEPT` then redo ufw setup |
| Port 80 still blocked after ufw| `sudo iptables -L INPUT -v -n` | Manual iptables rules may conflict — run `sudo iptables -F && sudo ufw disable && sudo ufw enable` |
| node_exporter times out from laptop | `sudo ufw status` then check your IP | Your ops IP may have changed — update the rule: `sudo ufw delete` old rule, add new one |
| tcpdump shows no packets at all | Check AWS Security Group in console | Block is at AWS level — add inbound rule for port 80 in the Security Group |
| GitHub Actions SSH fails after new server | Chec_HOST` secret | IP changed when server was recreated — update `EC2_HOST` secret with new IP |
| `ufw allow` creates duplicate rules | `sudo ufw status numbered` | Delete duplicates: `sudo ufw delete RULE_NUMBER` |

---

## What You Learned This Session

**Environment bootstrapping as a professional discipline.** You now have a repeatable script that rebuilds a multi-session environment from scratch in under 5 minutes. This pattern, encoding environment state as code, is the foundation of reliable infrastrture. You will use it every time a client asks you to reproduce an issue, set up a staging environment, or recover from a terminated instance.

**The two-layer firewall model.** Every AWS server has two firewalls: the Security Group at the hypervisor level, and iptables/ufw at the OS level. You now know how to test each layer independently with `tcpdump` (OS-level) and by checking AWS Security Group rules (AWS-level). Knowing which layer is blocking, and how to test each, is the skill that turns a 2-hour debugging session into a 10-minute diagnosis.

**`ss` for socket inspection.** You can read the `Local Address` column and immediately understand reachability. `127.0.0.1:8080` means no firewall rule in the world will make that port reachable from outside. `0.0.0.0:80` means it is reachable from anywhere subject to firewall. This distinction resolves a huge category of "why can't I reach my service" tickets.

**`tcpdump` for packet-level proof.** SYN with no SYN-ACK means DROP. SYN with RST means REJECT or nothing listening. No packets at all means upstream block. These three patterns map directly to three different problems with three different fixes. You can now determine which one you have in under 60 seconds.

**Single-tool firewall policy.** Mixing manual `iptables` commands with `ufw` is what caused this incident. You enforced the single-tool rule and understand why it matters. The next engineer who touches this server has one tool, one place to look, and documented reasons for every rule.

---


*Canonical CFE Training Series — Session 4 | TICKET-004*

