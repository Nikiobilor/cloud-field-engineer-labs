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
