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
