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
