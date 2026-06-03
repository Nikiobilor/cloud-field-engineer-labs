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
#   Safe to run multiple times. Uses || true guards on commands that fail
#   if already applied. Package installs are idempotent via apt-get.
#
# EXPECTED RUNTIME: 3-5 minutes
# MUST RUN AS: sudo bash bootstrap-session6.sh
# =============================================================================

set -euo pipefail   # Exit on error, treat unset vars as errors, pipe failures matter
# Note: set -e means any command that fails exits the script immediately.
# The || true guards below intentionally bypass this for expected failures.

# =============================================================================
# PHASE 0 — SYSTEM UPDATE
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 0: System update and base packages"
echo "=============================================="

export DEBIAN_FRONTEND=noninteractive   # Suppress interactive prompts during apt

apt-get update -q                       # Refresh package index (-q = quiet)
apt-get upgrade -yq                     # Apply security updates non-interactively
apt-get install -yq \
    curl \          # HTTP requests — used by health check scripts
    wget \          # File downloads
    git \           # Version control
    tcpdump \       # Packet capture (from Session 4)
    nginx \         # Reverse proxy (from Session 4)
    ufw \           # Uncomplicated Firewall (from Session 4)
    python3 \       # Application runtime (from Session 3)
    rsyslog \       # Syslog daemon (from Session 3)
    logrotate \     # Log rotation daemon (from Session 3)
    lvm2 \          # LVM tools (from Session 5)
    certbot \                    # Let's Encrypt client
    python3-certbot-nginx        # Certbot nginx plugin — handles config rewriting

echo "[OK] Base packages installed"

# =============================================================================
# PHASE 1 — SESSION 1: KERNEL TUNING
# Restores the sysctl tuning file from Session 1.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 1: Kernel tuning (Session 1)"
echo "=============================================="

cat > /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
# Canonical CFE Lab — kernel tuning parameters
# Applied in Session 1

# Maximum number of queued connections for listen()
# Default 128 is too low for production web services
net.core.somaxconn = 65535

# Allow TIME_WAIT sockets to be reused for new connections
# Reduces connection establishment latency under load
net.ipv4.tcp_tw_reuse = 1

# Reduce swappiness: prefer keeping process memory in RAM
# Default 60; lower value means less aggressive swap usage
vm.swappiness = 10

# Increase the size of the TCP receive and send buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

# Apply the tuning parameters to the running kernel
sysctl --system > /dev/null 2>&1   # --system loads all conf files; redirect output to reduce noise

echo "[OK] Kernel tuning applied"

# =============================================================================
# PHASE 2 — SESSION 1: NODE_EXPORTER
# Installs Prometheus node_exporter as a systemd service on port 9100.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 2: node_exporter (Session 1)"
echo "=============================================="

NODE_EXPORTER_VERSION="1.7.0"
NODE_EXPORTER_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"

# Only download and install if the binary doesn't already exist
if [ ! -f /usr/local/bin/node_exporter ]; then
    echo "  Downloading node_exporter v${NODE_EXPORTER_VERSION}..."
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_ARCHIVE}.tar.gz" \
        -O /tmp/node_exporter.tar.gz

    tar -xzf /tmp/node_exporter.tar.gz -C /tmp/     # Extract archive
    mv /tmp/${NODE_EXPORTER_ARCHIVE}/node_exporter /usr/local/bin/   # Install binary
    rm -rf /tmp/node_exporter.tar.gz /tmp/${NODE_EXPORTER_ARCHIVE}   # Clean up
    echo "  Binary installed at /usr/local/bin/node_exporter"
else
    echo "  node_exporter binary already present — skipping download"
fi

# Create dedicated system user for node_exporter (no login shell, no home dir)
# Running services as dedicated users is a security best practice
useradd --system --no-create-home --shell /bin/false node_exporter || true

# Write the systemd unit file
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

systemctl daemon-reload                           # Reload systemd to pick up new unit file
systemctl enable node_exporter --quiet            # Enable at boot
systemctl restart node_exporter                   # Start (or restart if already running)

echo "[OK] node_exporter running on port 9100"

# =============================================================================
# PHASE 3 — SESSION 3: MYAPP SERVICE AND LOGGING
# Restores the simulated application, journald config, logrotate, and rsyslog.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 3: myapp service and logging (Session 3)"
echo "=============================================="

# Create the application directory
mkdir -p /opt/myapp

# Write the simulated Python HTTP application
# This is a minimal HTTP server for demonstration purposes
cat > /opt/myapp/app.py << 'EOF'
#!/usr/bin/env python3
"""
RetailEdge myapp — simulated application server.
Listens on 127.0.0.1:8080 (loopback only).
nginx proxies external traffic to this service.
"""
import http.server
import socketserver

PORT = 8080
BIND = "127.0.0.1"   # Loopback only — never exposed directly to the internet

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/plain")
        self.end_headers()
        self.wfile.write(b"RetailEdge myapp OK\n")

    def log_message(self, format, *args):
        # Write access logs to our custom log file for logrotate management
        import datetime
        with open("/var/log/myapp/access.log", "a") as f:
            f.write(f"{datetime.datetime.now()} - {format % args}\n")

with socketserver.TCPServer((BIND, PORT), Handler) as httpd:
    httpd.serve_forever()
EOF

# Create the application log directory
# This is the LVM mountpoint configured in Session 5
mkdir -p /var/log/myapp
chown -R www-data:www-data /var/log/myapp || true   # www-data may not own it yet

# Write the systemd unit for myapp
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
# Capture stdout/stderr to the journal with these identifiers
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
EOF

# Configure journald for persistent storage with size limits
mkdir -p /var/log/journal                         # Enable persistent storage
cat > /etc/systemd/journald.conf.d/canonical-lab.conf << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
MaxRetentionSec=1month
EOF

# Configure logrotate for the myapp log files
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

# Configure rsyslog to forward myapp messages
cat > /etc/rsyslog.d/49-myapp.conf << 'EOF'
# Forward myapp syslog messages to the dedicated log file
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
# Restores the myapp health check cron job.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 4: Health check cron (Session 3)"
echo "=============================================="

# Write the health check script
# In a real environment, replace SLACK_WEBHOOK_URL with the actual webhook
cat > /usr/local/bin/myapp-alert.sh << 'SCRIPT'
#!/usr/bin/env bash
# myapp-alert.sh — checks myapp health and sends Slack alert on failure
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/REPLACE_ME}"

if ! systemctl is-active --quiet myapp.service; then
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
        -H 'Content-type: application/json' \
        --data '{"text":"[ALERT] myapp.service is not running on '"$(hostname)"'"}' || true
fi
SCRIPT

chmod +x /usr/local/bin/myapp-alert.sh

# Install cron job — run every 5 minutes
# crontab -l lists existing crontab; we only add if not already present
(crontab -l 2>/dev/null | grep -v "myapp-alert"; echo "*/5 * * * * /usr/local/bin/myapp-alert.sh") | crontab -

echo "[OK] myapp health check cron installed"

# =============================================================================
# PHASE 5 — SESSION 4: NGINX REVERSE PROXY (HTTP ONLY)
# Restores nginx as a reverse proxy on port 80.
# NOTE: This is intentionally HTTP-only — the broken state for Session 6.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 5: nginx HTTP reverse proxy (Session 4)"
echo "=============================================="

# Remove the default nginx site to avoid conflicts
rm -f /etc/nginx/sites-enabled/default

# Write the HTTP-only nginx configuration — this is the "before" state
# the engineer will upgrade to HTTPS in Session 6
cat > /etc/nginx/sites-available/retailedge << 'EOF'
# RetailEdge nginx configuration — HTTP ONLY (Session 4 state)
# WARNING: This configuration serves plaintext HTTP.
# Session 6 will add TLS termination.
server {
    listen 80;                        # Listen on all interfaces, port 80
    server_name _;                    # Match any hostname (lab environment)

    access_log /var/log/nginx/retailedge-access.log;
    error_log  /var/log/nginx/retailedge-error.log;

    location / {
        proxy_pass http://127.0.0.1:8080;          # Forward to myapp
        proxy_set_header Host $host;               # Preserve the original Host header
        proxy_set_header X-Real-IP $remote_addr;   # Pass client IP to the application
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme; # Will be 'http' until we add TLS
    }
}
EOF

ln -sf /etc/nginx/sites-available/retailedge /etc/nginx/sites-enabled/retailedge

nginx -t   # Test configuration before restarting (exits non-zero if invalid)
systemctl enable nginx --quiet
systemctl restart nginx

echo "[OK] nginx running HTTP-only on port 80 (Session 6 scenario: no TLS)"

# =============================================================================
# PHASE 6 — SESSION 4: UFW FIREWALL
# Restores the UFW configuration. Note: 443 is NOT yet allowed — the engineer
# will add it in Step 9 of the session.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 6: UFW firewall (Session 4)"
echo "=============================================="

# Determine the ops IP from environment or use a placeholder
OPS_IP="${OPS_IP:-203.0.113.10/32}"   # RFC 5737 documentation IP as placeholder

cat > /usr/local/bin/configure-firewall.sh << FWSCRIPT
#!/usr/bin/env bash
# configure-firewall.sh — idempotent UFW configuration
# Source of truth for this server's firewall policy

ufw --force reset             # Reset to clean state; --force skips the confirmation prompt

ufw default deny incoming     # Block all inbound traffic by default
ufw default allow outgoing    # Allow all outbound traffic (DNS, apt, etc.)

ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP (redirect to HTTPS)'
# NOTE: 443/tcp intentionally missing here — the engineer adds it in Session 6 Step 9
ufw allow from ${OPS_IP} to any port 9100 proto tcp comment 'node_exporter ops only'
ufw allow in on lo             # Allow all loopback traffic

ufw --force enable             # Enable without prompting (would disconnect SSH if used interactively!)
FWSCRIPT

chmod +x /usr/local/bin/configure-firewall.sh
bash /usr/local/bin/configure-firewall.sh

echo "[OK] UFW configured (note: port 443 not yet open — part of Session 6)"

# =============================================================================
# PHASE 7 — SESSION 5: LVM STORAGE
# Restores LVM on /dev/xvdb for /var/log/myapp.
# If /dev/xvdb is not attached (e.g. first bootstrap before EBS attach),
# this phase is skipped gracefully.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 7: LVM storage (Session 5)"
echo "=============================================="

if [ -b /dev/xvdb ]; then
    echo "  /dev/xvdb detected — configuring LVM..."

    # Only create PV if not already a PV
    if ! pvs /dev/xvdb > /dev/null 2>&1; then
        pvcreate /dev/xvdb
    fi

    # Only create VG if it doesn't exist
    if ! vgdisplay retailedge-logs-vg > /dev/null 2>&1; then
        vgcreate retailedge-logs-vg /dev/xvdb
    fi

    # Only create LV if it doesn't exist
    if ! lvdisplay /dev/retailedge-logs-vg/logs > /dev/null 2>&1; then
        lvcreate -L 4G -n logs retailedge-logs-vg
        mkfs.ext4 /dev/retailedge-logs-vg/logs
    fi

    # Add fstab entry if not already present
    if ! grep -q "retailedge-logs-vg" /etc/fstab; then
        echo "/dev/retailedge-logs-vg/logs /var/log/myapp ext4 defaults 0 2" >> /etc/fstab
    fi

    # Mount if not already mounted
    mountpoint -q /var/log/myapp || mount /var/log/myapp

    # Reduce reserved blocks to 1% (default is 5%, wasteful on data volumes)
    tune2fs -m 1 /dev/retailedge-logs-vg/logs > /dev/null 2>&1

    echo "[OK] LVM configured — /var/log/myapp on /dev/retailedge-logs-vg/logs"
else
    echo "  [SKIP] /dev/xvdb not found — LVM phase skipped"
    echo "  Ensure the second EBS volume is attached in the AWS console"
fi

# =============================================================================
# PHASE 8 — SESSION 5: DISK ALERT CRON
# Restores the disk usage monitoring cron.
# =============================================================================
echo ""
echo "=============================================="
echo " PHASE 8: Disk alert cron (Session 5)"
echo "=============================================="

cat > /usr/local/bin/disk-alert.sh << 'SCRIPT'
#!/usr/bin/env bash
# disk-alert.sh — alerts if any filesystem exceeds 80% usage
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
SCRIPT

chmod +x /usr/local/bin/disk-alert.sh
(crontab -l 2>/dev/null | grep -v "disk-alert"; echo "*/5 * * * * /usr/local/bin/disk-alert.sh") | crontab -

echo "[OK] Disk alert cron installed"

# =============================================================================
# PHASE 9 — SCENARIO STATE CONFIRMATION
# Print a summary of what is running and what the engineer will fix.
# =============================================================================
echo ""
echo "=============================================================="
echo " SESSION 6 ENVIRONMENT READY"
echo "=============================================================="
echo ""
echo " Services running:"
echo "   ✓ node_exporter  — port 9100 (ops IP only)"
echo "   ✓ myapp          — 127.0.0.1:8080 (loopback only)"
echo "   ✓ nginx          — port 80 (HTTP reverse proxy)"
echo "   ✓ rsyslog        — syslog forwarding active"
echo ""
echo " Firewall (UFW):"
echo "   ✓ 22/tcp   — SSH (any)"
echo "   ✓ 80/tcp   — HTTP (any)"
echo "   ✗ 443/tcp  — NOT OPEN (engineer adds in Step 9)"
echo "   ✓ 9100/tcp — ops IP only"
echo ""
echo " Scenario state:"
echo "   ✗ No TLS certificate installed"
echo "   ✗ nginx serving plaintext HTTP only"
echo "   ✗ No HTTP→HTTPS redirect"
echo "   ✗ No Certbot renewal timer"
echo ""
echo " The engineer walks into a server that is live on HTTP"
echo " and must implement full TLS termination for TICKET-006."
echo ""
echo "=============================================================="
