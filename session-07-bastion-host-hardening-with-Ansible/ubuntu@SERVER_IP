#!/bin/bash
# =============================================================================
# bootstrap-session7.sh
# Canonical CFE Training Series — Session 7
# Rebuilds cumulative state (Sessions 1-6) and introduces the broken/weak
# SSH configuration that the session's Ansible playbook will harden.
# Idempotent: safe to run multiple times.
# =============================================================================
set -euo pipefail

echo "============================================================"
echo " RetailEdge Lab Bootstrap — Session 7"
echo " Start time: $(date)"
echo "============================================================"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE A: System baseline (from Session 1)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[PHASE A] Applying kernel tuning parameters..."

cat > /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
# RetailEdge Lab — kernel tuning
net.core.somaxconn = 1024
net.ipv4.tcp_tw_reuse = 1
vm.swappiness = 10
net.ipv4.ip_local_port_range = 1024 65535
EOF

sysctl --system > /dev/null 2>&1
echo "[PHASE A] Kernel parameters applied."

# ─────────────────────────────────────────────────────────────────────────────
# PHASE B: Monitoring — node_exporter (from Session 1)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[PHASE B] Installing node_exporter v1.7.0..."

NODE_EXPORTER_VERSION="1.7.0"
NODE_EXPORTER_USER="node_exporter"

id "$NODE_EXPORTER_USER" &>/dev/null || useradd --no-create-home --shell /bin/false "$NODE_EXPORTER_USER"

if [ ! -f /usr/local/bin/node_exporter ]; then
    cd /tmp
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
    chown "$NODE_EXPORTER_USER":"$NODE_EXPORTER_USER" /usr/local/bin/node_exporter
fi

cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter --quiet
systemctl start node_exporter || true
echo "[PHASE B] node_exporter status: $(systemctl is-active node_exporter)"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE C: Application service (from Session 3)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[PHASE C] Setting up myapp.service (simulated Python HTTP app)..."

apt-get install -y python3 rsyslog > /dev/null 2>&1

mkdir -p /opt/myapp /var/log/myapp

cat > /opt/myapp/app.py << 'EOF'
#!/usr/bin/env python3
import http.server, socketserver, logging, os

logging.basicConfig(
    filename='/var/log/myapp/app.log',
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        logging.info(f"GET {self.path} from {self.client_address[0]}")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"RetailEdge App OK")
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 8080), Handler) as httpd:
    httpd.serve_forever()
EOF

cat > /etc/systemd/system/myapp.service << 'EOF'
[Unit]
Description=RetailEdge MyApp (simulated)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/myapp/app.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
EOF

# journald persistent storage
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal || true
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-persistent.conf << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
MaxRetentionSec=2592000
EOF

# rsyslog forwarding rule for myapp
cat > /etc/rsyslog.d/49-myapp.conf << 'EOF'
if $programname == 'myapp' then /var/log/myapp/syslog.log
& stop
EOF

systemctl daemon-reload
systemctl enable myapp --quiet
systemctl start myapp || true
systemctl restart rsyslog || true
echo "[PHASE C] myapp status: $(systemctl is-active myapp)"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE D: Nginx reverse proxy + ufw firewall (from Session 4)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[PHASE D] Installing nginx and configuring ufw..."

apt-get install -y nginx ufw tcpdump > /dev/null 2>&1

cat > /etc/nginx/sites-available/myapp << 'EOF'
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
ln -sf /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/myapp
rm -f /etc/nginx/sites-enabled/default || true
nginx -t && systemctl enable nginx --quiet && systemctl restart nginx || true

# configure-firewall.sh (idempotent ufw setup)
cat > /usr/local/bin/configure-firewall.sh << 'FWEOF'
#!/bin/bash
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
# OPS_IP is set by the engineer — this is a placeholder for the lab
OPS_IP="${OPS_IP:-0.0.0.0/0}"
ufw allow from "$OPS_IP" to any port 9100 comment 'Prometheus node_exporter'
ufw allow in on lo comment 'loopback'
ufw --force enable
FWEOF
chmod +x /usr/local/bin/configure-firewall.sh
/usr/local/bin/configure-firewall.sh
echo "[PHASE D] nginx status: $(systemctl is-active nginx) | ufw: $(ufw status | head -1)"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE E: LVM / disk management (from Session 5)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[PHASE E] Configuring LVM for /var/log/myapp..."

apt-get install -y lvm2 > /dev/null 2>&1

# Only attempt LVM setup if /dev/xvdb exists (second EBS volume)
if [ -b /dev/xvdb ]; then
    pvdisplay /dev/xvdb &>/dev/null || pvcreate /dev/xvdb
    vgdisplay retailedge-logs-vg &>/dev/null || vgcreate retailedge-logs-vg /dev/xvdb
    lvdisplay /dev/retailedge-logs-vg/logs &>/dev/null || lvcreate -L 4G -n logs retailedge-logs-vg

    if ! mountpoint -q /var/log/myapp; then
        mkfs.ext4 -F /dev/retailedge-logs-vg/logs > /dev/null 2>&1 || true
        mount /dev/retailedge-logs-vg/logs /var/log/myapp
        grep -q 'retailedge-logs-vg' /etc/fstab || \
            echo '/dev/retailedge-logs-vg/logs /var/log/myapp ext4 defaults 0 2' >> /etc/fstab
    fi
    tune2fs -m 1 /dev/retailedge-logs-vg/logs > /dev/null 2>&1 || true
    echo "[PHASE E] LVM /var/log/myapp mounted."
else
    echo "[PHASE E] /dev/xvdb not found — skipping LVM (attach volume if required)."
fi

# Logrotate for myapp
cat > /etc/logrotate.d/myapp << 'EOF'
/var/log/myapp/*.log {
    daily
    rotate 7
    compress
    maxsize 100M
    missingok
    notifempty
    postrotate
        systemctl kill --kill-who=main --signal=HUP myapp.service 2>/dev/null || true
    endscript
}
EOF

# disk-alert.sh (from Session 5)
cat > /usr/local/bin/disk-alert.sh << 'EOF'
#!/bin/bash
THRESHOLD=80
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
USAGE=$(df /var/log/myapp 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
[ -z "$USAGE" ] && exit 0
if [ "$USAGE" -ge "$THRESHOLD" ]; then
    [ -n "$SLACK_WEBHOOK" ] && \
        curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"DISK ALERT: /var/log/myapp at ${USAGE}%\"}" \
        "$SLACK_WEBHOOK"
fi
EOF
chmod +x /usr/local/bin/disk-alert.sh
(crontab -l 2>/dev/null | grep -v disk-alert || true; echo "*/5 * * * * /usr/local/bin/disk-alert.sh") | crontab -
echo "[PHASE E] Disk alert cron configured."

# ─────────────────────────────────────────────────────────────────────────────
# PHASE F: Session 7 scenario — introduce weak SSH configuration
# This is the BROKEN STATE the engineer will fix with Ansible.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[PHASE F] Introducing weak SSH configuration (Session 7 scenario)..."

# Back up the current sshd_config before weakening it
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig 2>/dev/null || true

# Write a deliberately insecure sshd_config
# DO NOT use this in production — this represents the 'before' state
cat > /etc/ssh/sshd_config << 'EOF'
# RetailEdge — INSECURE SSH CONFIG (Session 7 scenario — DO NOT LEAVE AS-IS)
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Weak: permits root login and password authentication
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes

# No idle timeout set
# No login grace time set
# No max auth tries set

PrintLastLog yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Restart sshd to apply weak config — we stay connected because our
# key-based session is already established.
sshd -t && systemctl restart sshd || true
echo "[PHASE F] Weak sshd_config applied. Root login and password auth are now ENABLED."

# Install python3-apt so Ansible's apt module works correctly
apt-get install -y python3-apt python3-pip > /dev/null 2>&1

# Install Ansible via pip (ensures a recent version)
pip3 install --quiet ansible 2>/dev/null || true

echo ""
echo "============================================================"
echo " Bootstrap Complete — Session 7 Scenario State"
echo "============================================================"
echo ""
echo "  Services running:"
echo "    node_exporter : $(systemctl is-active node_exporter)"
echo "    myapp         : $(systemctl is-active myapp)"
echo "    nginx         : $(systemctl is-active nginx)"
echo "    rsyslog       : $(systemctl is-active rsyslog)"
echo "    ufw           : $(ufw status | head -1)"
echo ""
echo "  SSH scenario state (INSECURE — your Ansible playbook will fix this):"
echo "    PermitRootLogin    : $(sshd -T | grep -i permitrootlogin)"
echo "    PasswordAuth       : $(sshd -T | grep -i passwordauthentication | head -1)"
echo ""
echo "  Your mission: write and run an Ansible playbook that replaces"
echo "  this insecure config with a CIS-hardened one — without breaking"
echo "  any existing services."
echo ""
echo "  Bootstrap finished: $(date)"
echo "============================================================"
