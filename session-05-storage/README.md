# TICKET-005 — Session 5: Storage Under Pressure — LVM, EBS Expansion & Full-Disk Recovery

> **Canonical CFE Training Series** | Session 5 of 32 | `CFE-005`
> **Scenario:** A client's production server has run out of disk space. The application is throwing write errors. The database has stopped accepting inserts. You have been called in to recover the system without data loss and without taking it offline.

---

## The Ticket

```
TICKET ID:    CFE-005
PRIORITY:     Critical — Production Down
ASSIGNED TO:  Cloud Field Engineer (You)
CLIENT:       RetailEdge Ltd — E-commerce platform, Lagos & London
ENVIRONMENT:  Ubuntu 22.04 LTS on AWS EC2 (gp3 EBS volume)

SUBJECT: Server disk completely full. Application throwing write errors.
         Database stopped accepting new orders.

DESCRIPTION:
The RetailEdge production server is reporting "No space left on device"
errors across multiple services. myapp (configured in Session 3) is failing
to write logs. The PostgreSQL database has halted because it cannot write
WAL (Write-Ahead Log) files. The node_exporter metrics from Session 1 show
disk utilisation at 100%.

The root volume was provisioned as 8GB in our Terraform config (Session 1).
The ops team suspects the /var/log directory has grown unchecked and the
application generates large temporary files during peak processing.

The server cannot be taken offline, orders are still arriving and must be
processed once storage is restored.

We need someone to:
1. Identify what is consuming the disk without making things worse
2. Immediately free enough space to stabilise the system
3. Expand the EBS volume and grow the filesystem online (no reboot)
4. Set up LVM so future storage expansion is trivial
5. Configure monitoring to alert before disk hits 100% again
6. Document everything for the support team

ACCEPTANCE CRITERIA:
- [ ] Disk usage diagnosed to the file and directory level
- [ ] Emergency space freed to restore service stability
- [ ] EBS volume expanded from 8GB to 20GB online
- [ ] Filesystem grown to use new space (no reboot required)
- [ ] LVM configured for flexible future expansion
- [ ] Disk usage alert added to the monitoring cron (from Session 3)
- [ ] logrotate reviewed and tightened (from Session 3)
- [ ] All changes documented in handover README
```

---

## Session Goals

By the end of this session you will have:

- Rebuilt the full cumulative environment from Sessions 1–4 using a single bootstrap script
- Diagnosed disk usage under pressure using `df`, `du`, `lsof`, and `ncdu`
- Freed emergency disk space safely on a live production server
- Expanded an AWS EBS volume online and grown the filesystem without a reboot
- Understood and configured LVM (Logical Volume Manager) for flexible storage
- Isolated the application log directory onto a dedicated LVM volume
- Added disk usage alerting to the existing monitoring stack from Session 3

Storage incidents are one of the most common and most stressful production emergencies. A full disk does not just stop writes, it can corrupt databases, crash systemd, and prevent SSH login. The tools and mental model in this session will let you respond calmly and systematically rather than in a panic.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Session Bootstrap — Recreating the Environment](#session-bootstrap--recreating-the-environment)
3. [Prerequisites](#prerequisites)
4. [Step 1 — Triage: Assess the Damage Without Making It Worse](#step-1--triage-assess-the-damage-without-making-it-worse)
5. [Step 2 — Emergency Space Recovery](#step-2--emergency-space-recovery)
6. [Step 3 — Expand the EBS Volume in AWS](#step-3--expand-the-ebs-volume-in-aws)
7. [Step 4 — Grow the Filesystem Online (No Reboot)](#step-4--grow-the-filesystem-online-no-reboot)
8. [Step 5 — Understand and Configure LVM](#step-5--understand-and-configure-lvm)
9. [Step 6 — Add Disk Usage Alerting](#step-6--add-disk-usage-alerting)
10. [Step 7 — Tighten logrotate to Prevent Recurrence](#step-7--tighten-logrotate-to-prevent-recurrence)
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
BEFORE this session (broken state, what the bootstrap creates)
┌──────────────────────────────────────────────────────────────────┐
│  AWS EC2 — Ubuntu 22.04                                          │
│                                                                  │
│  EBS Root Volume (gp3, 8GB)  ████████████████████ 100% FULL     │
│  /dev/xvda1 (ext4, 8GB) mounted at /                            │
│                                                                  │
│  Disk consumers:                                                 │
│  ├── /var/log/myapp/     3.2GB  (synthetic large log files)      │
│  ├── /var/log/journal/   1.8GB  (journal not vacuumed)           │
│  ├── /tmp/               0.9GB  (synthetic temp files)           │
│  └── system + services   2.1GB                                   │
│                                                                  │
│  Services running but degraded:                                  │
│  ├── myapp.service     → write errors on /var/log/myapp          │
│  ├── node_exporter     → metrics show 100% disk                  │
│  ├── nginx             → access log writes failing               │
│  └── ufw               → firewall rules intact from Session 4    │
└──────────────────────────────────────────────────────────────────┘

AFTER this session (recovered and improved state)
┌──────────────────────────────────────────────────────────────────┐
│  AWS EC2 — Ubuntu 22.04                                          │
│                                                                  │
│  EBS Root Volume (gp3, 20GB) ████████░░░░░░░░░░░░ ~42% used    │
│  /dev/xvda (20GB) ── /dev/xvda1 grown online via growpart        │
│                                                                  │
│  Second EBS Volume (gp3, 5GB) attached as /dev/xvdb             │
│                                                                  │
│  LVM Stack:                                                      │
│  Physical Volume (PV) → /dev/xvdb                               │
│  Volume Group (VG)    → retailedge-logs-vg (5GB pool)           │
│  Logical Volume (LV)  → logs (4GB) mounted at /var/log/myapp    │
│                                                                  │
│  Filesystem layout:                                              │
│  /               → ext4 on /dev/xvda1  (20GB)                   │
│  /var/log/myapp  → ext4 on LV logs     (4GB, isolated)          │
│                                                                  │
│  New monitoring:                                                 │
│  cron */5 → disk-alert.sh → df -h → Slack if any FS > 80%       │
└──────────────────────────────────────────────────────────────────┘

AWS (two-account view):
  EC2 root volume:   /dev/xvda  (20GB, expanded online)
  EC2 second volume: /dev/xvdb  (5GB, LVM logs)
  Security Group:    22, 80, 443 (any) | 9100 (ops IP only)
```

**Why LVM matters for a CFE:** Without LVM, a filesystem is directly tied to a partition, and a partition is directly tied to a single disk. To resize, you must resize the partition, then the filesystem, with multiple failure points. With LVM, a logical volume is a flexible slice of a storage pool. You can extend it online in three commands, add new disks to the pool without repartitioning, and snapshot it for backups. Every serious production Linux deployment uses LVM, and knowing how to work with it confidently is a core field engineer skill.

---

## Session Bootstrap — Recreating the Environment

**What we are doing and why:** Since you terminate your EC2 instance after each session, this session starts with a blank Ubuntu 22.04 instance. The bootstrap rebuilds the complete cumulative state from Sessions 1 through 4, kernel tuning, node_exporter, myapp, journald, logrotate, rsyslog alerting, nginx, ufw, and the configure-firewall script. It then deliberately fills the disk to simulate the scenario described in the ticket. This gives you a real broken environment to diagnose and fix, not a clean lab.

### Bootstrap Phase 1 — Provision the EC2 instance with Terraform

Navigate to your Session 1 Terraform directory. The Security Group already has ports 22, 80, 443, and 9100 open from Session 4. No Terraform changes are needed for this session, reuse the existing config.

```bash
cd cloud-field-engineer-labs/session-01-linux-tuning/terraform/

# If you have not already initialised since your last session
terraform init

# Review the plan — should show a clean set of resources to create
terraform plan

# Deploy
terraform apply
# Type 'yes' to confirm

# Export the new server IP immediately, you will use it throughout this session
export SERVER_IP=$(terraform output -raw instance_public_ip)
echo "New server IP: $SERVER_IP"
```

> Every time you terminate and recreate an EC2 instance, AWS assigns a new public IP from its address pool. The private IP (inside the VPC) also changes. This is expected behaviour. The fix for production is an Elastic IP, a static address that stays assigned to your account regardless of instance lifecycle. For this training series, we export the IP to a shell variable and update GitHub Secrets at the start of each session. This is the correct approach for a cost-managed lab environment.

### Bootstrap Phase 2 — The `bootstrap-session5.sh` script

Create the bootstrap script in your repository. This script installs and configures everything built across Sessions 1–4 cumulatively, then introduces the full-disk scenario.

```bash
mkdir -p session-05-storage/scripts
nano session-05-storage/scripts/bootstrap-session5.sh
```

```bash
#!/usr/bin/env bash
# session-05-storage/scripts/bootstrap-session5.sh
#
# Bootstraps the EC2 instance to the full cumulative state of Sessions 1-4,
# then introduces the full-disk scenario that Session 5 diagnoses and resolves.
#
# Run once on a fresh Ubuntu 22.04 instance:
#   sudo bash bootstrap-session5.sh YOUR_SLACK_WEBHOOK_URL YOUR_OPS_IP
#
# Arguments:
#   $1 — Slack webhook URL (for alerting scripts from Session 3)
#   $2 — Ops workstation IP (for ufw node_exporter rule from Session 4)
#
# What this script builds (cumulative):
#   Session 1: kernel tuning, node_exporter v1.7.0 as systemd service
#   Session 3: myapp.service, journald persistence, logrotate, rsyslog,
#              myapp-alert.sh cron script
#   Session 4: nginx reverse proxy, ufw firewall, configure-firewall.sh,
#              tcpdump
#   Session 5: fills the disk to simulate the ticket scenario

set -euo pipefail

SLACK_WEBHOOK="${1:-}"
OPS_IP="${2:-$(curl -s ifconfig.me)}"

echo "======================================================="
echo "  Session 5 Bootstrap — RetailEdge Lab Environment"
echo "  $(date --iso-8601=seconds)"
echo "  Slack webhook: ${SLACK_WEBHOOK:-(not provided)}"
echo "  Ops IP: $OPS_IP"
echo "======================================================="

# ── PHASE 1: SYSTEM UPDATES AND TOOLS ────────────────────────────────────────
echo ""
echo "[Phase 1/9] Updating system and installing tools..."

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
    ufw \
    lvm2 \
    ncdu \
    cloud-guest-utils

# cloud-guest-utils provides growpart — needed for online partition expansion in Step 4
# lvm2 is the LVM toolset — needed for Step 5
# ncdu is the interactive disk explorer — needed for Step 1

echo "[Phase 1/9] Done."

# ── PHASE 2: KERNEL TUNING (Session 1) ───────────────────────────────────────
echo ""
echo "[Phase 2/9] Applying kernel tuning (Session 1)..."

cat > /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
# Canonical Lab — Session 1 kernel tuning for RetailEdge Ltd
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
echo "[Phase 2/9] Done."

# ── PHASE 3: NODE_EXPORTER (Session 1) ───────────────────────────────────────
echo ""
echo "[Phase 3/9] Installing node_exporter v1.7.0 (Session 1)..."

NODE_EXPORTER_VERSION="1.7.0"

# || true prevents failure if the user already exists on a re-run
useradd --system --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"*

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

echo "[Phase 3/9] Done. node_exporter running on :9100"

# ── PHASE 4: MYAPP SERVICE (Session 3) ───────────────────────────────────────
echo ""
echo "[Phase 4/9] Setting up myapp service (Session 3)..."

useradd --system --no-create-home --shell /bin/false myappuser 2>/dev/null || true

mkdir -p /opt/myapp
mkdir -p /var/log/myapp

cat > /opt/myapp/app.py << 'APPEOF'
#!/usr/bin/env python3
"""
Simulated RetailEdge myapp — Canonical CFE Training Session 5
Listens on 127.0.0.1:8080 (loopback only).
All external traffic arrives via nginx reverse proxy on port 80.
"""
import http.server
import socketserver
import logging

LOG_FILE = "/var/log/myapp/app.log"
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)

class AppHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        logging.info(f"GET {self.path} from {self.client_address[0]}")
        body = b'{"status": "ok", "service": "RetailEdge myapp", "session": 5}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # Suppress default stdout logging

with socketserver.TCPServer(("127.0.0.1", 8080), AppHandler) as httpd:
    logging.info("myapp started on 127.0.0.1:8080")
    httpd.serve_forever()
APPEOF

chmod +x /opt/myapp/app.py
chown -R myappuser:myappuser /opt/myapp
chown -R myappuser:adm /var/log/myapp

cat > /etc/systemd/system/myapp.service << 'EOF'
[Unit]
Description=RetailEdge Application (simulated — Session 5)
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

echo "[Phase 4/9] Done. myapp running on 127.0.0.1:8080"

# ── PHASE 5: JOURNALD, LOGROTATE, RSYSLOG, ALERTING (Session 3) ──────────────
echo ""
echo "[Phase 5/9] Configuring journald, logrotate, rsyslog, alerting (Session 3)..."

# journald persistence
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

# logrotate for myapp NOTE: deliberately WITHOUT maxsize
# Session 5 adds maxsize as a lesson learned from this incident
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

# rsyslog forwarding rule
cat > /etc/rsyslog.d/49-myapp.conf << 'EOF'
if $programname == 'myapp' then {
    action(
        type="omfwd"
        target="logs.example.com"
        port="514"
        protocol="tcp"
        template="RSYSLOG_SyslogProtocol23Format"
    )
    stop
}
EOF

systemctl restart rsyslog 2>/dev/null || true

# myapp-alert.sh (Session 3)
cat > /usr/local/bin/myapp-alert.sh << 'ALERTEOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICE="myapp.service"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"
HOSTNAME=$(hostname -f)
STATE=$(systemctl is-active "$SERVICE" 2>/dev/null || true)
if [[ "$STATE" != "active" ]]; then
    JOURNAL=$(journalctl -u "$SERVICE" -n 20 --no-pager 2>&1)
    MESSAGE="*ALERT* \`${SERVICE}\` on \`${HOSTNAME}\` is *${STATE}*.\n\`\`\`${JOURNAL}\`\`\`"
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"$MESSAGE\"}"
    fi
    echo "$(date --iso-8601=seconds) ALERT: $SERVICE is $STATE" >> /var/log/myapp-alert.log
fi
ALERTEOF

chmod +x /usr/local/bin/myapp-alert.sh

# Add the myapp-alert cron entry
CRON_LINE="*/5 * * * * SLACK_WEBHOOK_URL=\"${SLACK_WEBHOOK}\" /usr/local/bin/myapp-alert.sh"
( crontab -l 2>/dev/null | grep -v 'myapp-alert' || true; echo "$CRON_LINE" ) | crontab -

echo "[Phase 5/9] Done."

# ── PHASE 6: NGINX REVERSE PROXY (Session 4) ─────────────────────────────────
echo ""
echo "[Phase 6/9] Configuring nginx reverse proxy (Session 4)..."

cat > /etc/nginx/sites-available/myapp << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/myapp
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "[Phase 6/9] Done. nginx running on :80 → 127.0.0.1:8080"

# ── PHASE 7: UFW FIREWALL (Session 4) ────────────────────────────────────────
echo ""
echo "[Phase 7/9] Configuring ufw firewall (Session 4)..."

cat > /usr/local/bin/configure-firewall.sh << 'FWEOF'
#!/usr/bin/env bash
set -euo pipefail
OPS_IP="${1:?Usage: configure-firewall.sh OPS_IP}"
ufw --force disable
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh   comment "SSH access"
ufw allow http  comment "HTTP — proxied to myapp via nginx"
ufw allow https comment "HTTPS — TLS termination via nginx"
ufw allow from "$OPS_IP" to any port 9100 proto tcp \
    comment "node_exporter — ops team only"
ufw allow in on lo comment "loopback — internal service communication"
ufw --force enable
ufw status verbose
FWEOF

chmod +x /usr/local/bin/configure-firewall.sh
/usr/local/bin/configure-firewall.sh "$OPS_IP"

echo "[Phase 7/9] Done. ufw configured with clean ruleset."

# ── PHASE 8: FILL THE DISK (Session 5 scenario) ──────────────────────────────
echo ""
echo "[Phase 8/9] Filling disk to simulate full-disk incident (Session 5 scenario)..."
#
# We deliberately consume disk space to reproduce the ticket scenario.
# Three things are filling the disk in production:
#   1. Unrotated myapp log files (logrotate maxsize was never set)
#   2. Journal files that were never vacuumed despite the 500MB config
#   3. Application temporary files not cleaned up after processing
#
# We simulate this by writing synthetic files to the same locations.
# The dd command writes blocks of zeros from /dev/zero.
#   bs=1M  = 1 megabyte block size
#   count  = number of blocks to write
#
# We leave ~200MB free so SSH and basic commands still work.
# The df output at the end of this phase will confirm the disk state.

DISK_TOTAL_MB=$(df --output=size -m / | tail -1 | tr -d ' ')
TARGET_USED_MB=$(( DISK_TOTAL_MB - 200 ))
CURRENT_USED_MB=$(df --output=used -m / | tail -1 | tr -d ' ')
TO_FILL_MB=$(( TARGET_USED_MB - CURRENT_USED_MB ))

if [[ $TO_FILL_MB -gt 0 ]]; then
    # Write synthetic myapp logs (simulates weeks of unrotated logs)
    mkdir -p /var/log/myapp
    LOGFILE_MB=$(( TO_FILL_MB * 60 / 100 ))   # 60% of fill goes to myapp logs
    JOURNALFILE_MB=$(( TO_FILL_MB * 25 / 100 )) # 25% to journal overflow
    TMPFILE_MB=$(( TO_FILL_MB * 15 / 100 ))     # 15% to temp files

    echo "  Writing ${LOGFILE_MB}MB to /var/log/myapp/ (simulated unrotated logs)..."
    dd if=/dev/zero of=/var/log/myapp/app-accumulated.log \
        bs=1M count="${LOGFILE_MB}" status=none 2>/dev/null || true

    echo "  Writing ${JOURNALFILE_MB}MB to /var/log/journal/ (simulated journal overflow)..."
    dd if=/dev/zero of=/var/log/journal/synthetic-overflow.tmp \
        bs=1M count="${JOURNALFILE_MB}" status=none 2>/dev/null || true

    echo "  Writing ${TMPFILE_MB}MB to /tmp/ (simulated app temp files)..."
    dd if=/dev/zero of=/tmp/myapp-processing-cache.tmp \
        bs=1M count="${TMPFILE_MB}" status=none 2>/dev/null || true
fi

# Fix ownership on the log directory
chown -R myappuser:adm /var/log/myapp

echo "[Phase 8/9] Done. Disk is now full."
df -h / | tail -1

# ── PHASE 9: FINAL SUMMARY ───────────────────────────────────────────────────
echo ""
echo "======================================================="
echo "  Bootstrap Complete — Session 5 Environment Ready"
echo "======================================================="
echo ""
echo "  Services:"
systemctl is-active node_exporter  && echo "  ✓ node_exporter   :9100" \
                                   || echo "  ✗ node_exporter   FAILED"
systemctl is-active myapp.service  && echo "  ✓ myapp           127.0.0.1:8080" \
                                   || echo "  ✗ myapp           FAILED"
systemctl is-active nginx          && echo "  ✓ nginx           :80 → myapp" \
                                   || echo "  ✗ nginx           FAILED"
echo ""
echo "  Disk state (the incident you are walking into):"
df -h /
echo ""
echo "  Largest consumers:"
du -h --max-depth=2 /var/log 2>/dev/null | sort -rh | head -6
echo ""
echo "  Session 5 scenario is live."
echo "  The disk is full. Services are throwing write errors."
echo "  Begin with Step 1: Triage — assess the damage."
echo "======================================================="
```

### Bootstrap Phase 3 — Copy and run the script on the fresh instance

```bash
# Copy the bootstrap script to the server
scp -i ~/.ssh/canonical_lab_key \
    session-05-storage/scripts/bootstrap-session5.sh \
    ubuntu@$SERVER_IP:/tmp/bootstrap-session5.sh

# SSH into the server
ssh -i ~/.ssh/canonical_lab_key ubuntu@$SERVER_IP

# Run the bootstrap as root
# Pass your Slack webhook URL and your ops IP as arguments
sudo bash /tmp/bootstrap-session5.sh \
    "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" \
    "$(curl -s ifconfig.me)"
```


The script runs in nine phases and takes approximately 4–6 minutes on a t3.micro. When it completes, you will see a summary confirming all services are running and the disk state. The final `df -h /` output will show the root filesystem at or above 95%, that is the scenario you are about to fix.

> If the disk fills completely during the bootstrap and the script itself runs out of space, you may see an error on Phase 8. This is fine, it means the disk was already smaller than expected (an older Ubuntu base image may have more packages pre-installed). The scenario is still valid. SSH in and run `df -h /` to confirm the disk is at or near 100%.

### Bootstrap Phase 4 — Update GitHub Secrets with the new IP

```bash
# Get the new server IP from Terraform output (run from your local machine)
terraform output instance_public_ip
```

Update in GitHub: **Repository → Settings → Secrets and variables → Actions**

| Secret | Action |
|---|---|
| `EC2_HOST` | Update with the new IP from `terraform output` |
| `EC2_USER` | No change — always `ubuntu` |
| `EC2_SSH_KEY` | Update only if you regenerated your SSH key pair this session |
| `OPS_IP` | Update if your workstation IP has changed: `curl ifconfig.me` |

---

## Prerequisites

The bootstrap above satisfies all of these. Confirm each before proceeding:

- ✅ AWS EC2 instance running Ubuntu 22.04 LTS with all Sessions 1–4 services installed
- ✅ Root filesystem at 95–100% capacity (confirmed by bootstrap Phase 8)
- ✅ `node_exporter` running on `:9100`, `myapp` on `127.0.0.1:8080`, `nginx` on `:80`
- ✅ `ufw` active with clean ruleset from Session 4
- ✅ SSH access confirmed (you are connected via the bootstrap run)
- ✅ AWS CLI configured locally with credentials from Session 1
- ✅ GitHub Secrets updated: `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`, `OPS_IP`
- ✅ Slack webhook URL available for alerting

---

## Step 1 — Triage: Assess the Damage Without Making It Worse

**What we are doing and why:** When a disk is full, the instinct is to start deleting files immediately. This is wrong and potentially catastrophic. Deleting the wrong files or deleting files that are still open by a running process, can corrupt a database, destroy log evidence you need for the post-mortem, or make the situation worse without freeing any space. Spend the first ten minutes collecting facts. Understand what is full, what is using the space, and what is safe to touch before touching anything.

### 1a. Check overall disk usage

```bash
# df = disk free — shows usage at the filesystem level
# -h = human-readable units (KB, MB, GB)
# -T = show filesystem type (ext4, tmpfs, xfs, etc.)
df -hT
```

Example output on the bootstrapped server:

```
Filesystem     Type      Size  Used Avail Use% Mounted on
/dev/xvda1     ext4      7.7G  7.5G  200M  97% /
tmpfs          tmpfs     483M     0  483M   0% /dev/shm
tmpfs          tmpfs      97M  1.1M   96M   1% /run
/dev/xvda15    vfat       99M  5.8M   93M   6% /boot/efi
```

The `Use%` column is your first signal. Note that `tmpfs` filesystems (`/dev/shm`, `/run`) live entirely in RAM, they are not disk problems. Focus on the `ext4` line for `/`.

> A subtlety that matters in a real incident: ext4 reserves 5% of filesystem blocks for the root user by default. This means a non-root process hits "No space left on device" when `df` shows 95% full, the remaining 5% is reserved for root. When `df` shows 100%, even root processes are blocked. You can reclaim that reserved space immediately with `tune2fs -m 1 /dev/xvda1` — reducing the reservation from 5% to 1% and instantly freeing ~320MB on an 8GB disk. We use this as our first emergency action in Step 2.

```bash
# Also check inode usage — a disk can be "full" in two ways
# Out of blocks (data space) — the common case
# Out of inodes (file slots) — caused by millions of tiny files
df -i
# A filesystem with IUse% at 100% is inode-exhausted
# All the free blocks in the world will not help, you cannot create new files
```

### 1b. Find what is consuming the space

```bash
# du = disk usage — shows consumption at the directory level
# --max-depth=1 = one level deep from the root
# -h = human-readable, sort -rh = sort by size descending
# 2>/dev/null = suppress permission denied errors on protected directories
sudo du -h --max-depth=1 / 2>/dev/null | sort -rh | head -20
```

Drill into the biggest directories:

```bash
# Investigate /var — the most common location for runaway log growth
sudo du -h --max-depth=2 /var 2>/dev/null | sort -rh | head -20

# Find every file larger than 100MB anywhere on the filesystem
sudo find / -type f -size +100M 2>/dev/null | xargs ls -lh | sort -k5 -rh
# -type f = files only, not directories
# -size +100M = larger than 100MB
# xargs ls -lh = get size details for each result
# sort -k5 -rh = sort by the fifth column (file size) in human-readable reverse order
```

### 1c. Use ncdu for interactive exploration

```bash
# ncdu = NCurses Disk Usage, an interactive visual disk usage explorer
# Installed by the bootstrap script
sudo ncdu /
# Arrow keys navigate the tree
# Enter descends into a directory
# The largest items appear at the top automatically
# 'q' to quit — do NOT press 'd' to delete anything yet
```

> `ncdu` is the tool that experienced Linux engineers reach for first on a full-disk incident. It gives you the entire directory tree ranked by size in an interactive interface, no repeated `du` commands, no complex `sort` pipelines. You can drill from `/` all the way to the offending log file in under 30 seconds. Install it on every server you manage.

### 1d. Find files held open by processes, the hidden space trap

```bash
# lsof = list open files
# A file that has been deleted with rm is NOT freed from disk
# until every process that has it open closes its file descriptor.
# This is the most common cause of "I deleted everything but df still shows full."
sudo lsof | grep deleted
```

If you see entries here, the disk will not free until those processes are restarted or until they close the file descriptor. This is why log rotation uses `postrotate` to signal the application to reopen log files rather than deleting them directly.

```bash
# Find large deleted files still held open (most actionable for emergency recovery)
sudo lsof | grep deleted | awk '{ if ($7 ~ /^[0-9]/ && $7+0 > 52428800) print $0 }' \
    | sort -k7 -rn | head -10
# 52428800 = 50MB in bytes — only show files larger than 50MB
```

---

## Step 2 — Emergency Space Recovery

**What we are doing and why:** Before expanding the disk (which takes a few minutes to complete at the AWS level), we free enough space to stabilise the system, get services writing again and stop the error cascade. We target only safe, clearly recoverable space: reserved filesystem blocks, package manager cache, journal overflow, and temp files. We do not delete application data, database files, or anything we have not confirmed is safe.

### 2a. Reduce the ext4 reserved block percentage (instant, no data deleted)

```bash
# ext4 reserves 5% of blocks for root by default.
# On an 8GB disk: 5% = ~400MB. Reducing to 1% frees ~320MB instantly.
# -m 1 = set reserved block percentage to 1%
# Safe to run on a live, mounted filesystem, no data is touched.
sudo tune2fs -m 1 /dev/xvda1   
# verify the hypervisor type(xen-based or nitro based) using the command lsblk (commands captured are for xen )

# Verify and check the new free space
sudo tune2fs -l /dev/xvda1 | grep -i "reserved block"
df -h /
# You should see ~320MB appear as free space
```

### 2b. Clear the package manager cache

```bash
# apt caches every downloaded .deb package in /var/cache/apt/archives/
# These are safe to delete, they can be re-downloaded if needed
# On an active server this cache can reach several hundred MB
sudo apt-get clean

# Also remove packages installed as dependencies that are no longer needed
sudo apt-get autoremove -y

df -h /
```

### 2c. Vacuum the systemd journal

```bash
# journald may have grown beyond its 500MB configured limit.
# --vacuum-size forces it to delete oldest entries until it is under the threshold.
sudo journalctl --vacuum-size=200M
# We set 200MB — safely below the 500MB configured limit

# Also remove entries older than 7 days
sudo journalctl --vacuum-size=7d

# Confirm the journal size is now under control
journalctl --disk-usage

# Remove the synthetic journal file placed by the bootstrap
sudo rm -f /var/log/journal/synthetic-overflow.tmp
df -h /
```

### 2d. Clear temporary files

```bash
# Check what is in /tmp before deleting
sudo ls -lah /tmp/ | sort -k5 -rh | head -20

# Remove the synthetic temp file placed by the bootstrap
sudo rm -f /tmp/myapp-processing-cache.tmp

# Remove any other files in /tmp older than 1 day
sudo find /tmp -type f -mtime +1 -delete 2>/dev/null || true

df -h /
```

### 2e. Force logrotate to compress existing logs

```bash
# Run logrotate now with --force to compress uncompressed old logs
# This does not delete data — it compresses it in place
sudo logrotate --force /etc/logrotate.conf

# Remove the synthetic large log file placed by the bootstrap
# This simulates what logrotate would have done had maxsize been configured
sudo rm -f /var/log/myapp/app-accumulated.log

df -h /
# We should now have enough headroom to proceed with the EBS expansion
```

### 2f. Verify services have recovered from write errors

```bash
# Check that myapp is no longer throwing write errors
sudo systemctl status myapp.service
sudo journalctl -u myapp.service -n 10

# Confirm the application can write to its log directory
sudo -u myappuser touch /var/log/myapp/write-test.tmp \
    && echo "Write: OK" \
    && sudo rm /var/log/myapp/write-test.tmp

# Check nginx is healthy
sudo systemctl status nginx
```

---

## Step 3 — Expand the EBS Volume in AWS

**What we are doing and why:** Emergency space recovery stabilises the stem and buys time. The permanent fix is expanding the underlying EBS volume. AWS allows you to increase an EBS volume's size while it is attached and in use, no snapshot, no downtime, no reboot required. The expansion happens at the AWS infrastructure level. The OS and filesystem do not automatically recognise the new space, Steps 4 and 5 handle that.

### 3a. Find your EBS volume ID

```bash
# Query the EC2 instance metadata service to get the instance ID
# 169.254.169.254 is the link-local address of the metadata service
# It is always reachable from inside an EC2 instance and nowhere else
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
echo "Instance ID: $INSTANCE_ID"
```

From your **local machine** (not the SSH session):

```bash
# Find the root EBS volume attached to this instance
# --query extracts just the volume ID from the JSON response using JMESPath syntax
# --output text removes surrounding quotes from the output
VOLUME_ID=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)

echo "Root volume ID: $VOLUME_ID"
```

### 3b. Check the current volume state

```bash
# Confirm the current size and type before modifying
aws ec2 describe-volumes \
    --volume-ids $VOLUME_ID \
    --query 'Volumes[0].{Size:Size,State:State,VolumeType:VolumeType,IOPS:Iops}' \
    --output table
```

### 3c. Expand the volume to 20GB

```bash
# Modify the volume size, this is an online operation, no instance stop required
# AWS permits one modification per volume per 6-hour period
aws ec2 modify-volume \
    --volume-id $VOLUME_ID \
    --size 20

# Poll until the modification state reaches 'completed'
# The state progresses: modifying → optimizing → completed
aws ec2 describe-volumes-modifications \
    --volume-ids $VOLUME_ID \
    --query 'VolumesModifications[0].{State:ModificationState,Progress:Progress,TargetSize:TargetSize}' \
    --output table
# Re-run this command every 30 sec until State shows 'completed'
# Typically takes 1-3 minutes for a small volume
```

> Why does this not require downtime? EBS volumes are network-attached block devices, not physical drives inside the server. When you increase the size, AWS provisions additional storage in their infrastructure and extends the block device's address space. From the EC2 instance's perspective, the block device suddenly has more sectors. The OS still thinks the partition ends at 8GB because the partition table and filesystem have not been updated yet, that is what Steps 4 and 5 do.

### 3d. Verify the OS can see the new block device size

Back on the server (SSH session):

```bash
# lsblk shows the block device tree including sizes
lsblk
# Expected: xvda shows 20G, but xvda1 still shows 8G
# This confirms the expansion is visible at the block device level
# but the partition table has not been updated yet

# Confirm at the byte level using blockdev
sudo blockdev --getsize64 /dev/xvda
# 20GB = 21474836480 bytes
```

---

## Step 4 — Grow the Filesystem Online (No Reboot)

**What we are doing and why:** We now have a 20GB block device with an 8GB partition and an 8GB filesystem on it. We need to expand the partition to fill the new block device space, then expand the filesystem to fill the partition. Both operations can be performed on a live, mounted filesystem. This is one of the most impressive demonstrations a field engineer can give a client: expanding a production disk with zero downtime.

### 4a. Expand the partition with owpart

```bash
# growpart extends a partition to fill all available space on the disk
# It is part of cloud-guest-utils, installed by the bootstrap script
# Arguments: the disk device, then the partition number to expand
sudo growpart /dev/xvda 1
# Expected output: CHANGED: partition=1 start=... old: size=... new: size=...

# Verify the partition has grown
lsblk
# Expected: xvda1 now shows 20G (matching the block device)
```

> `growpart` works by reading the current partition table, computing the new end sector from the disk geometry (total sectors minus any alignment padding), and rewriting the partition table entry. It does not touch the filesystem, the filesystem still thinks the partition ends at the old boundary until `resize2fs` tells it otherwise.

### 4b. Grow the ext4 filesystem

```bash
# resize2fs grows an ext4 filesystem to fill its containing partition
# When called without a size argument, it fills all available partition space
# This is safe to run on a live, mounted filesystem, ext4 supports online resize
sudo resize2fs /dev/xvda1
# Expected output:
# Filesystem at /dev/xvda1 is mounted on /; on-line resizing required
# The filesystem on /dev/xvda1 is now XXXXXXX (4k) blocks long.

# Confirm the filesystem now shows the full 20GB
df -h /
# Expected: Size shows ~20GB, Use% significantly reduced
```

> For XFS filesystems, common on Red Hat, CentOS, Rocky Linux, and AlmaLinux, the command is `sudo xfs_growfs /` instead of `resize2fs`. Running `resize2fs` on an XFS filesystem will fail with an error. Always check the filesystem type with `df -T` before choosing the grow command. In production, you will encounter both.

### 4c. Confirm end-to-end

```bash
# Full picture: block device, partition, filesystem all aligned
lsblk -f
# -f shows filesystem type and mount point alongside size

# Write test to confirm the disk is usable
sudo touch /var/tmp/disk-expansion-test && echo "Write OK" \
    && sudo rm /var/tmp/disk-expansion-test

# Confirm services are stable with the expanded disk
sudo systemctl status myapp.service nginx node_exporter
```

---

## Step 5 — Understand and Configure LVM

**What we are doing and why:** The disk is expanded and the system is stable. Now we set up LVM so the next storage growth request is a three-command operation instead of a multi-step emergency. LVM (Logical Volume Manager) adds a flexible abstraction layer between physical storage and filesystems. We will add a second EBS volume, create an LVM stack on it, and move the myapp log directory onto its own isolated vole. This means a future log runaway can never fill the root filesystem and crash the server.

### 5a. The LVM mental model, understand this before running commands

```
Physical world          LVM world               Filesystem world
──────────────          ─────────               ────────────────

/dev/xvdb (5GB) ──→  Physical Volume (PV)
                      "raw block device
                       registered with LVM"
                         │
                      Volume Group (VG)
                      "retailedge-logs-vg"
                      "a named pool of all
                       PV space — 5GB"
                             │
               ┌─────────────┴──────────────┐
               ▼                            ▼
        Logical Volume               (1GB free in VG
        "logs" (4GB)                  for future use)
        "a virtual part         carved from the VG"
               │
               ▼
        ext4 filesystem
        mounted at /var/log/myapp
```

The key insight: a Logical Volume is a flexible virtual partition inside the Volume Group pool. You can extend it without touching partition tables, add new disks to the pool transparently, and snapshot it for backups. This is why LVM is the standard for production Linux storage.

### 5b. Add a second EBS volume for the LVM logs volume

From your **local machine**:

```bash
# Fine availability zone of the running instance
# A new EBS volume must be in the same AZ to be attached
AZ=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
    --output text)

echo "Availability Zone: $AZ"

# Create a 5GB gp3 volume in the same AZ
NEW_VOLUME_ID=$(aws ec2 create-volume \
    --availability-zone $AZ \
    --volume-type gp3 \
    --size 5 \
    --tag-specifications \
        'ResourceType=volume,Tags=[{Key=Name,Value=retailedge-lvm-logs},{Key=Session,Value=05}]' \
    --query 'VolumeId' \
    --output text)

echo "New volume ID: $NEW_VOLUME_ID"

# Wait for the volume to reach the 'available' state before attaching
aws ec2 wait volume-available --volume-ids $NEW_VOLUME_ID
echo "Volume is available."

# Attach to the instance as /dev/xvdb
aws ec2 attach-volume \
    --volume-id $NEW_VOLUME_ID \
    --instance-id $INSTANCE_ID \
    --device /dev/xvdb

aws ec2 wait volume-in-use --volume-ids $NEW_VOLUME_ID
echo "Volume attached as /dev/xvdb."
```

On the server, confirm the new volume is visible:

```bash
lsblk
# Expected: xvdb (5GB) appears alongside xvda (20GB)
# xvdb has no partition table and no filesystem — it is a blank block device
```

### 5c. Create the Physical Volume

```bash
# pvcreate initialises the block device for LVM use
# It writes LVM metadata (a UUID and configuration) to the start of the device
# This does NOT format the device or create a filesystem, it just registers it with LVM
sudo pvcreate ev/xvdb

# Verify the PV was created
sudo pvdisplay /dev/xvdb
# Key fields: PV Size (5GB), Allocatable (yes), PE Size (4MB), Total PE (count of 4MB extents)
```

> PEs (Physical Extents) are LVM's unit of allocation, typically 4MB each. When you create a logical volume of 4GB, you are allocating 1024 PEs from the VG's pool. LVM sizes are always rounded to PE boundaries, which is why you may see minor discrepancies between requested and actual sizes.

### 5d. Create the Volume Group

```bash
# vgcreate creates a new VG from one or more PVs
# Arguments: VG name, then one or more PV device paths
sudo vgcreate retailedge-logs-vg /dev/xvdb

# Verify
sudo vgdisplay retailedge-logs-vg
# Key fields: VG Size (5GB), Free PE/Size (how much is unallocated)
```

### 5e. Create the Logical Volume

```bash
# lvcreate carves a logical volume from the VG's free space
# -L 4G = size of exactly 4 gigabytes
# -n logs = name this LV 'logs'
# retailedge-logs-vg = which VG to allocate from
sudo lvcreate -L 4G -n logs retailedge-logs-vg

# Verify
sudo lvdisplay retailedge-logs-vg/logs
# Key field: LV Path = /dev/retailedge-logs-vg/logs
# This is the device path used for mkfs and mount
```

### 5f. Create a filesystem and mount at /var/log/myapp

```bash
# Format the LV with ext4
sudo mkfs.ext4 /dev/retailedge-logs-vg/logs

# Preserve existing logs before remounting
sudo mv /var/log/myapp /var/log/myapp-backup

# Re-create the mount point directory
sudo mkdir -p /var/log/myapp

# Mount the new LV at /var/log/myapp
sudo mount /dev/retailedge-logs-vg/logs /var/log/myapp

# Restore existing logs to the new volume
sudo mv /var/log/myapp-backup/* /var/log/myapp/ 2>/dev/null || true
sudo rm -rf /var/log/myapp-backup

# Fix ownership so myapp can write
sudo chown -R myappuser:adm /var/log/myapp
```

### 5g. Make the mount persistent across reboots

```bash
# Always use the UUID in fstab, never the device path
# Device paths (/dev/xvdb) can change across reboots; UUIDs never do
LV_UUID=$(sudo blkid -s UUID -o value /dev/retailedge-logs-vg/logs)
echo "LV UUID: $LV_UUID"

# Back up fstab before editing — a mistake here can prevent the server from booting
sudo cp /etc/fstab /etc/fstab.backup.session5

# Append the mount entry
echo "UUID=$LV_UUID /var/log/myapp ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
# nofail = do not halt boot if this volume fails to mount
# 0 2    = do not dump; check filesystem second after root on boot
```

```bash
# Test the fstab entry without rebooting
# If this succeeds silently, the entry is correct
# If it error fix fstab before the next reboot
sudo umount /var/log/myapp
sudo mount -a
df -h /var/log/myapp
# Expected: 4GB filesystem mounted from /dev/mapper/retailedge--logs--vg-logs
```

### 5h. Demonstrate how easy future expansion is with LVM

```bash
# When the logs volume needs more space in the future, these three commands are all it takes:

# 1. Extend the LV by 1 more gigabyte (using the remaining free space in the VG)
sudo lvextend -L +500MB /dev/retailedge-logs-vg/logs

# 2. Grow the filesystem to fill the extended LV — no unmount needed
sudo resize2fs /dev/retailedge-logs-vg/logs

# 3. Verify
df -h /var/log/myapp
# Expected: filesystem now shows 5GB

# Compare this with the equivalent on a non-LVM partition:
# resize the EBS volume, wait for AWS, growpart, resize2fs, verify fstab — multiple steps
# With LVM and an available VG: three commands, under 10 seconds, zero downtime
```

---

## Step 6 — Add Disk Usage Alerting

**What we are doing and why:** This incident happened because nobody knew the disfilling up. The myapp service health alerting from Session 3 did not cover disk usage. We now add a disk-specific alert that fires at 80%, giving the ops team hours or days of advance warning before it becomes a production crisis. This is the shift from reactive firefighting to proactive operations.

### 6a. Create the disk alert script

```bash
sudo nano /usr/local/bin/disk-alert.sh
```

```bash
#!/usr/bin/env bash
# /usr/local/bin/disk-alert.sh
#
# Checks disk usage on all real (non-virtual) mounted filesystems.
# Fires a Slack alert if any filesystem exceeds the configured threshold.
# Runs every 5 minutes via cron alongside the myapp-alert.sh from Session 3.
#
# Environment variables:
#   SLACK_WEBHOOK_URL — Slack incoming webhook URL
#   DISK_THRESHOLD    — Alert when usage exceeds this % (default: 80)

set -euo pipefail

SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"
THRESHOLD="${DISK_THRESHOLD:-80}"
HOSTNAME=$(hostname -f)
ALERT_LOG="/var/log/disk-alert.log"

# Check only real filesystems — exclude tmpfs, devtmpfs, squashfs (snap packages)
# These virtual filesystems report unusual usage values by design — not disk problems
# grep -v filters OUT the filesystem types we do not want to check
OVER_THRESHOLD=$(df -h --output=source,fstype,pcent,target \
    | grep -v -E 'tmpfs|devtmpfs|squashfs|udev|Filesystem' \
    | awk -v threshold="$THRESHOLD" '{
        gsub(/%/, "", $3)           # strip the % sign from the pcent column
        if ($3+0 >= threshold+0) {  # numeric comparison after stripping %
          print $0
        }
    }')

if [[ -n "$OVER_THRESHOLD" ]]; then
    # Include the full df table in the alert for immediate context
    FULL_DF=$(df -h --output=source,fstype,size,used,avail,pcent,target \
        | grep -v -E 'tmpfs|devtmpfs|squashfs|udev')

    MESSAGE="*DISK ALERT* on \`${HOSTNAME}\` — filesystem(s) above ${THRESHOLD}%.\n\`\`\`${FULL_DF}\`\`\`"

    if [[ -n "$SLACK_WEBHOOK" ]]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H "Content-Type: application/json" \
          -d "{\"text\": \"$MESSAGE\"}"
    fi

    echo "$(date --iso-8601=seconds) DISK ALERT on ${HOSTNAME}: over ${THRESHOLD}%:" \
        >> "$ALERT_LOG"
    echo "$OVER_THRESHOLD" >> "$ALERT_LOG"
fi

# Exits silently if everything is under threshold.
# Cron only sends email if the script produces stdout or stderr output.
```

```bash
sudo chmod +x /usr/local/bin/disk-alert.sh
```

### 6b. Test the script

```bash
# Test with a low threshold to force an alert (confirm Slack receives it)
sudo SLACK_WEBHOOK_URL="your-webhook-url" DISK_THRESHOLD=10 /usr/local/bin/disk-alert.sh
# Expected: Slack alert received

# Test at normal threshold — should be silent now that disk is healthy
sudo SLACK_WEBHOOK_URL="your-webhook-url" DISK_THRESHOLD=80 /usr/local/bin/disk-alert.sh
# Expected: no output (all filesystems under 80%)
```

### 6c. Add to cron alongside the Session 3 service health check

```bash
sudo crontab -e
```

The crontab should now contain both alert jobs:

```
# Service health check from Session 3
*/5 * * * SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK" /usr/local/bin/myapp-alert.sh

# Disk usage alert — Session 5
*/5 * * * * SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK" DISK_THRESHOLD=80 /usr/local/bin/disk-alert.sh
```

> Why two separate cron jobs rather than one combined script? Single-responsibility principle. The service health script knows about systemd units. The disk alert script knows about filesystems. If a new service is added, you update the service scriptIf a new filesystem is mounted, the disk script picks it up automatically. Combining them makes both harder to maintain and test independently.

---

## Step 7 — Tighten logrotate to Prevent Recurrence

**What we are doing and why:** The bootstrap deliberately configured logrotate without a `maxsize` directive, exactly as Session 3 left it. A high-traffic application can generate gigabytes of logs within a single day, long before the daily rotation fires. The lesson from this incident is `maxsize`: rotatemmediately when a log file reaches a size threshold, regardless of whether the time-based interval has elapsed. This one change would have prevented this incident.

```bash
sudo nano /etc/logrotate.d/myapp
```

Update the configuration:

```
/var/log/myapp/*.log {
    daily

    # NEW — the direct lesson from this incident:
    # Rotate immediately if any log file exceeds 100MB, even mid-day.
    # Without this, a verbose application can generate 3GB of logs
    # between daily rotation cycles and fill thdisk entirely.
    maxsize 100M

    # Reduced from 14 to 7 days.
    # 14 days of high-volume logs was a significant contributor to the full disk.
    # 7 days provides sufficient history for incident investigation.
    rotate 7

    compress
    delaycompress
    missingok
    notifempty
    create 0640 myappuser adm
    sharedscripts
    postrotate
        systemctl kill -s HUP myapp.service 2>/dev/null || true
    endscript
}
```

```bash
# Validate the updated configuration before relying on it
sudo logrotate --debug /etc/logrotate.d/myapp
# No errors = configuration is syntactically valid

# Force a rotation to confirm maxsize behaviour works
sudo logrotate --force /etc/logrotate.d/myapp
ls -lah /var/log/myapp/
# You should see the log file rotated and the new empty app.log created
```

---

## Step 8 — Write the Handover Document

```bash
mkdir -p session-05-storage/docs
cat > session-05-storage/docs/HANDOVER-TICKET-005.md << 'HANDOVER'
# HANDOVER DOCUMENT
## TICKET-005: Storage Under Pressure — Fuisk Recovery & LVM Configuration

**Client:** RetailEdge Ltd
**Engineer:** [Your Name]
**Date:** [Date]
**Status:** Resolved — 48-hour observation period recommended

---

## Executive Summary

The 8GB root EBS volume reached 100% capacity, causing application write
failures and database halts. Three contributing factors combined: unrotated
myapp logs (logrotate had no maxsize limit), journal files that had grown
beyond the configured limit, and uncleared application temp files. The root
volume was expand to 20GB online without downtime. The myapp log directory
was isolated onto a dedicated 4GB LVM volume so log growth can never fill the
root filesystem again. Disk alerting now fires to Slack at 80% threshold.

---

## Root Cause Analysis

1. logrotate had no maxsize directive — a single verbose log file grew to 3.2GB
   between daily rotation cycles without triggering rotation.
2. journald vacuum had not been enforced since the 500MB limit was configured
   in Session 3 — the journal had grown to 1.8GB No disk usage alerting existed — the disk reached 100% with no notification.

---

## Changes Made

| Component | Before | After |
|---|---|---|
| EBS root volume | 8GB | 20GB (expanded online, no reboot) |
| Root filesystem | 8GB ext4 on /dev/xvda1 | 20GB ext4, grown with growpart + resize2fs |
| /var/log/myapp | On root filesystem | Isolated 4GB LVM logical volume |
| LVM | Not configured | VG: retailedge-logs-vg, LV: logs (4GB on /dev/xvdb) |
| logrotate maxsize | Not set | 100MB per file |
| logrotatretention | 14 days | 7 days |
| Disk alerting | None | Slack alert at 80% threshold, every 5 minutes |
| ext4 reserved blocks | 5% (~400MB) | 1% (~200MB, freed 320MB) |

---

## Current Storage Layout

| Filesystem | Size | Mount Point | Purpose |
|---|---|---|---|
| /dev/xvda1 | 20GB | / | Root: OS, application, database |
| /dev/retailedge-logs-vg/logs | 4GB | /var/log/myapp | Isolated application logs |

---

## Files Created or Modified

| File | Change |
|---|---|
| /etc/fstab | Added LVM log volume mount (UUID-based) |
| /etc/fstab.backup.session5 | Backup of original fstab |
| /etc/logrotate.d/myapp | Added maxsize 100M, reduced rotation to 7 days |
| /usr/local/bin/disk-alert.sh | New disk usage monitoring script |
| Root crontab | Added disk-alert.sh at */5 * * * * |

---

## How to Expand Storage in Future

Log volume (/var/log/myapp) needs more space:
    sudo lvextend -L +2G /dev/retailedge-logs-vg/logs
    sudo resize2fs /dev/retailedge-logs-vg/logs
    df -h /var/log/myapp

Root filesystem (/) needs more space:
1. Expand EBS volume via AWS CLI: aws ec2 modify-volume --volume-id VOL_ID --size NEW_SIZE
2. Wait for completion: aws ec2 describe-volumes-modifications --volume-ids VOL_ID
3. Grow partition: sudo growpart /dev/xvda 1
4. Grow filesystem: sudo resize2fs /dev/xvda1

---

## Monitoring

Disk checked every 5 minutes via cron.
Alert fires to Slack when any real filesystem exceeds 80%.
Local alert log: /var/log/disk-alert.log

If an alert fires:
  1. df -h — identify which filesystem
  2. suddu -h --max-depth=2 /var/log | sort -rh | head -20
  3. Logs: sudo logrotate --force /etc/logrotate.conf
  4. Journal: sudo journalctl --vacuum-size=200M
  5. Still full: expand the relevant volume using the runbook above

---

## Rollback Instructions

To remove LVM and return /var/log/myapp to the root filesystem:
    sudo rsync -av /var/log/myapp/ /var/log/myapp-from-lvm/
    sudo umount /var/log/myapp
    sudo sed -i '/retailedge-logs-vg/d' /etc/fstab
    sudo mv /var/log/myapp-from-lvm/* /var/log/myapp/
    # To destroy the LVM stack entirely (data loss — run above rsync first):
    # sudo lvremove /dev/retailedge-logs-vg/logs
    # sudo vgremove retailedge-logs-vg
    # sudo pvremove /dev/xvdb
HANDOVER
```

---

## Step 9 — Commit Your Work to GitHub

```bash
cd /path/to/cloud-field-engineer-labs/

git add session-05-storage/

git commit -m "session-05: EBS expansion, LVM, disk alerting, and bootstrap for TICKET-005

- Added bootstrap-session5.sh: rebuilds Sessions 1-4 environment cumulatively,
  fidisk to simulate full-disk incident (Phase 8 writes synthetic files)
- Documented full disk triage: df, du, lsof, ncdu — observe before touching
- tune2fs: reduced ext4 reserved blocks 5% → 1% (freed 320MB instantly)
- EBS root volume expanded 8GB → 20GB online (growpart + resize2fs, no reboot)
- Second EBS volume (5GB) attached and configured with LVM
- LVM: PV /dev/xvdb, VG retailedge-logs-vg, LV logs (4GB)
- /var/log/myapp isolated on LVM volume — log growth cannot fill root filesystem
- logrotat maxsize 100M, retention reduced 14 → 7 days
- disk-alert.sh: Slack notification when any filesystem exceeds 80%
- cron: disk-alert.sh added alongside Session 3 myapp-alert.sh
- Handover document: root cause, storage layout, expansion runbook, rollback steps"

git push origin main
```

---

## Verification Checklist

```bash
# 1. Root filesystem has healthy free space
df -h /
# Expected: Size ~20GB, Use% well below 80%

# 2. LVM log volume is mounted and healthy
df -h /var/log/myapp
# Expected: ~4GB filestem mounted from LVM

# 3. LVM stack is intact
sudo pvdisplay   # Physical volumes
sudo vgdisplay   # Volume groups
sudo lvdisplay   # Logical volumes

# 4. fstab entry survives a remount cycle
sudo umount /var/log/myapp
sudo mount -a
df -h /var/log/myapp
# Expected: still mounted after remount

# 5. myapp can write to its log directory
sudo -u myappuser touch /var/log/myapp/write-test.tmp \
    && echo "Write: OK" \
    && sudo rm /var/log/myapp/write-test.tmp

# 6. logrotate config is valid with new maxsize
sudo logrotate --debug /etc/logrotate.d/myapp
# Expected: no errors

# 7. Disk alert script fires correctly
sudo SLACK_WEBHOOK_URL="your-url" DISK_THRESHOLD=10 /usr/local/bin/disk-alert.sh
# Expected: Slack alert received

# 8. Both cron jobs are registered
sudo crontab -l | grep -E "myapp-alert|disk-alert"
# Expected: two cron lines

# 9. All services healthy after storage changes
systemctl is-active myapp.service nginx node_exporter
# Expected: active active active

# 10. No open deleted files consuming space
sudo lsof | grep deleted | wc -l
# Expected: 0 or very small number
```

---

## Troubleshooting Reference

| Symptom | Diagnostic command | Fix |
|---|---|---|
| Bootstrap Phase 8 errors mid-run (disk fills during script) | `df -h /` | Fine — disk is full as intended. SSH still works. Proceed to Step 1. |
| `df` still shows 100% after deleting files | `sudo lsof \| grep deleted` | Files held open by process — restart the process |
| `growpart` returns "NOCHANGE" | `lsblk` | AWS EBS modification yet complete — wait and retry |
| `resize2fs` errors on XFS filesystem | `df -T /` | Use `sudo xfs_growfs /` instead of `resize2fs` |
| LVM volume not mounting at boot | `sudo systemctl status var-log-myapp.mount` | Check UUID in fstab: `blkid /dev/retailedge-logs-vg/logs` |
| `lvextend` reports "not enough free PEs" | `sudo vgdisplay` | VG pool exhausted — attach a new EBS volume and run `sudo vgextend` |
| Disk alert fires on tmpfs | `df -T` | Confirm grep in script excludes `tmpfs` — should work bult |
| EBS `modify-volume` returns error | AWS CLI output | Only one volume modification per 6-hour period — wait and retry |
| fstab error prevents boot | AWS Console → EC2 → Connect → Session Manager | Edit `/etc/fstab`, remove the bad line, reboot |
| GitHub Actions SSH fails after new server | Check `EC2_HOST` secret | IP changed — update `EC2_HOST` with `terraform output instance_public_ip` |

---

## What You Learned This Session

**Systematic triage under pressure.** You did not start dele on a full disk. You used `df`, `du`, `lsof`, and `ncdu` to build a complete picture first, then acted with evidence. This discipline is the difference between a controlled recovery and an incident that turns a disk problem into a data loss event.

**Online disk expansion with zero downtime.** You expanded an AWS EBS volume, grew a live partition with `growpart`, and extended an active ext4 filesystem with `resize2fs`, all without stopping the application or the instance. This is one of the most practically valuable demonstrations a field engineer can give a client.

**The LVM abstraction stack.** You understand all three layers: Physical Volumes (raw block devices registered with LVM), Volume Groups (storage pools), and Logical Volumes (flexible virtual partitions). You know why `lvextend` + `resize2fs` is three commands versus the multi-step complexity of non-LVM expansion. And you know why the root filesystem cannot be easily converted to LVM on a live server, it requires a rescue environment.

**Filesystem isolation as a reliability pattern.** By moving `/var/log/myapp` onto its own LVM volume, a log runaway now fills that 4GB volume and stops — it cannot cascade into filling the root filesystem, crashing systemd, or locking out SSH. This separation-of-concerns pattern is standard in production Linux deployments.

**The `lsof | grep deleted` pattern.** You now know the most common source of "I deleted everything but the disk is still full" confusion. Files are not freed until every process with them open oses the file descriptor. This pattern resolves a huge category of storage incidents that stump engineers who do not know it.

**Proactive alerting over reactive firefighting.** The 80% disk alert means the next storage growth will generate a Slack notification with hours or days to respond — not a 2am "the site is down" call when the disk hits 100%.

---

## Go Deeper

- What is the difference between `lvextend` and `lvresize`? When would you use `lvresize` to shrink a volume, and what precautions must y take?
- Read about LVM snapshots: `lvcreate -s`. How are they used to back up a live database without downtime, and what write amplification cost do they introduce?
- What is thin provisioning in LVM? How does it differ from thick provisioning, and what happens when a thin pool runs out of space?
- Research `ext4` vs `XFS` for write-heavy log workloads. Why does Red Hat default to XFS for new installations?
- What does `tune2fs -l /dev/xvda1` reveal? What other performance-relevant filesystem parameters can be tuned without reformatting?
- Investigate AWS EBS volume types: `gp2` vs `gp3` vs `io2`. What is the difference in IOPS provisioning model, and when would a database workload justify `io2`?

---



---

*CFE Training Series — Session 5 | TICKET-005*

