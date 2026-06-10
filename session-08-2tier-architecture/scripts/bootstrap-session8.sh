#!/usr/bin/env bash
# bootstrap-session8.sh
# CFE Training Series — Session 8
# Cumulative rebuild: Sessions 1-7 OS state + Session 8 broken state simulation
# Broken state: network namespace with no default route (simulates private subnet
# with no NAT Gateway entry)
#
# Usage: scp this file to the instance, then run with sudo

set -euo pipefail

echo "=== Session 8 Bootstrap: Starting cumulative rebuild ==="

# ─── SYSTEM BASELINE ────────────────────────────────────────────────────────

apt-get update -yq

# curl: HTTP client used by health check scripts
# wget: general file downloader
# unzip: needed for some install packages
# python3: runtime for myapp simulation
# python3-pip: Python package installer
# jq: JSON processor used in diagnostic scripts
# net-tools: ifconfig, netstat for legacy tooling checks
# iproute2: ip command — route, namespace, link management
# tcpdump: packet capture, installed in Session 4
# ansible: configuration management, installed in Session 7
# auditd: Linux audit daemon, installed in Session 7
# fail2ban: intrusion prevention, installed in Session 7
apt-get install -yq \
    curl \
    wget \
    unzip \
    python3 \
    python3-pip \
    jq \
    net-tools \
    iproute2 \
    tcpdump \
    ansible \
    auditd \
    fail2ban

# ─── SESSION 1: KERNEL TUNING ────────────────────────────────────────────────

# /proc/sys/net/core/somaxconn controls the maximum listen() backlog
# net.ipv4.tcp_tw_reuse allows reuse of TIME_WAIT sockets under load
cat > /etc/sysctl.d/99-canonical-lab-tuning.conf << 'EOF'
net.core.somaxconn = 1024
net.ipv4.tcp_tw_reuse = 1
vm.swappiness = 10
EOF

sysctl --system > /dev/null

# ─── SESSION 1: NODE_EXPORTER ────────────────────────────────────────────────

NODE_EXPORTER_VERSION="1.7.0"
NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"

if [[ ! -f "$NODE_EXPORTER_BIN" ]]; then
    wget -q \
        "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
        -O /tmp/node_exporter.tar.gz
    tar -xzf /tmp/node_exporter.tar.gz -C /tmp
    cp "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" "$NODE_EXPORTER_BIN"
    chmod +x "$NODE_EXPORTER_BIN"
    rm -rf /tmp/node_exporter*
fi

if ! id -u node_exporter &>/dev/null; then
    useradd --no-create-home --shell /bin/false node_exporter
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
systemctl enable node_exporter
systemctl restart node_exporter

# ─── SESSION 3: MYAPP ────────────────────────────────────────────────────────

mkdir -p /opt/myapp /var/log/myapp

cat > /opt/myapp/app.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import datetime

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        ts = datetime.datetime.utcnow().isoformat()
        self.wfile.write(f"[{ts}] myapp OK\n".encode())
    def log_message(self, fmt, *args):
        with open("/var/log/myapp/app.log", "a") as f:
            f.write(f"{self.address_string()} - {fmt % args}\n")

with socketserver.TCPServer(("127.0.0.1", 8080), Handler) as httpd:
    httpd.serve_forever()
EOF

cat > /etc/systemd/system/myapp.service << 'EOF'
[Unit]
Description=RetailEdge myapp simulation
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/myapp/app.py
Restart=on-failure
User=www-data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable myapp
systemctl restart myapp

# ─── SESSION 3: JOURNALD PERSISTENT STORAGE ──────────────────────────────────

mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal || true

sed -i 's/^#Storage=.*/Storage=persistent/' /etc/systemd/journald.conf || true
sed -i 's/^Storage=.*/Storage=persistent/' /etc/systemd/journald.conf || true
grep -q '^Storage=' /etc/systemd/journald.conf || echo 'Storage=persistent' >> /etc/systemd/journald.conf

sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf || true
grep -q '^SystemMaxUse=' /etc/systemd/journald.conf || echo 'SystemMaxUse=500M' >> /etc/systemd/journald.conf

sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=1month/' /etc/systemd/journald.conf || true
grep -q '^MaxRetentionSec=' /etc/systemd/journald.conf || echo 'MaxRetentionSec=1month' >> /etc/systemd/journald.conf

systemctl restart systemd-journald

# ─── SESSION 3: LOGROTATE ────────────────────────────────────────────────────

cat > /etc/logrotate.d/myapp << 'EOF'
/var/log/myapp/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    maxsize 100M
    postrotate
        systemctl kill -s HUP myapp.service || true
    endscript
}
EOF

# ─── SESSION 3: RSYSLOG ──────────────────────────────────────────────────────

cat > /etc/rsyslog.d/49-myapp.conf << 'EOF'
if $programname == 'myapp' then /var/log/myapp/app.log
& stop
EOF

systemctl restart rsyslog || true

# ─── SESSION 3: HEALTH CHECK CRON ────────────────────────────────────────────

cat > /usr/local/bin/myapp-alert.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! systemctl is-active --quiet myapp; then
    echo "ALERT: myapp is not running on $(hostname) at $(date)" | \
        logger -t myapp-alert
fi
EOF
chmod +x /usr/local/bin/myapp-alert.sh

TMPFILE=$(mktemp)
crontab -l 2>/dev/null | grep -v "myapp-alert" > "$TMPFILE" || true
echo "*/5 * * * * /usr/local/bin/myapp-alert.sh" >> "$TMPFILE"
crontab "$TMPFILE"
rm -f "$TMPFILE"

# ─── SESSION 4: NGINX REVERSE PROXY ──────────────────────────────────────────

apt-get install -yq nginx

# ─── SESSION 6: SELF-SIGNED TLS CERTIFICATE ──────────────────────────────────

mkdir -p /etc/letsencrypt/live/retailedge-lab

if [[ ! -f /etc/letsencrypt/live/retailedge-lab/fullchain.pem ]]; then
    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout /etc/letsencrypt/live/retailedge-lab/privkey.pem \
        -out /etc/letsencrypt/live/retailedge-lab/fullchain.pem \
        -subj "/CN=retailedge-lab/O=RetailEdge/C=GB" \
        2>/dev/null
fi

if [[ ! -f /etc/ssl/certs/dhparam.pem ]]; then
    openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048 2>/dev/null
fi

# ─── SESSION 6: NGINX TLS HARDENING SNIPPET ──────────────────────────────────

mkdir -p /etc/nginx/snippets

cat > /etc/nginx/snippets/tls-hardening.conf << 'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_dhparam /etc/ssl/certs/dhparam.pem;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
add_header Strict-Transport-Security "max-age=63072000" always;
EOF

# ─── SESSION 6: NGINX SITE CONFIG ────────────────────────────────────────────

cat > /etc/nginx/sites-available/retailedge << 'EOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate /etc/letsencrypt/live/retailedge-lab/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/retailedge-lab/privkey.pem;

    include snippets/tls-hardening.conf;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/retailedge /etc/nginx/sites-enabled/retailedge
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx

# ─── SESSION 4: UFW FIREWALL ─────────────────────────────────────────────────

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
ufw allow from "${OPS_IP:-0.0.0.0/0}" to any port 9100 || true
ufw --force enable

# ─── SESSION 5: LVM ──────────────────────────────────────────────────────────

# LVM setup is idempotent-guarded: only run if VG does not already exist
if ! vgs retailedge-logs-vg &>/dev/null; then
    if lsblk | grep -q xvdb; then
        apt-get install -yq lvm2
        pvcreate /dev/xvdb
        vgcreate retailedge-logs-vg /dev/xvdb
        lvcreate -L 4G -n logs retailedge-logs-vg
        mkfs.ext4 /dev/retailedge-logs-vg/logs
        mkdir -p /var/log/myapp
        mount /dev/retailedge-logs-vg/logs /var/log/myapp
        LOGS_UUID=$(blkid -s UUID -o value /dev/retailedge-logs-vg/logs)
        grep -q "$LOGS_UUID" /etc/fstab || \
            echo "UUID=${LOGS_UUID} /var/log/myapp ext4 defaults 0 2" >> /etc/fstab
        tune2fs -m 1 /dev/retailedge-logs-vg/logs
    else
        echo "INFO: /dev/xvdb not present — skipping LVM setup (single-volume lab)"
    fi
fi

# ─── SESSION 7: ANSIBLE HARDENING PLAYBOOK ───────────────────────────────────

mkdir -p ~/retailedge-hardening/roles/{ssh_hardening,fail2ban,auditd}/{tasks,handlers,files}

# SSH hardening role
cat > ~/retailedge-hardening/roles/ssh_hardening/tasks/main.yml << 'EOF'
---
- name: Deploy hardened sshd_config
  copy:
    src: sshd_config
    dest: /etc/ssh/sshd_config
    owner: root
    group: root
    mode: '0600'
  notify: validate and restart sshd
EOF

cat > ~/retailedge-hardening/roles/ssh_hardening/handlers/main.yml << 'EOF'
---
- name: validate and restart sshd
  command: sshd -t
  notify: restart sshd

- name: restart sshd
  service:
    name: sshd
    state: restarted
EOF

cat > ~/retailedge-hardening/roles/ssh_hardening/files/sshd_config << 'EOF'
Port 22
Protocol 2
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ubuntu
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
EOF

# fail2ban role
cat > ~/retailedge-hardening/roles/fail2ban/tasks/main.yml << 'EOF'
---
- name: Deploy jail.local
  copy:
    src: jail.local
    dest: /etc/fail2ban/jail.local
    owner: root
    group: root
    mode: '0644'
  notify: restart fail2ban
EOF

cat > ~/retailedge-hardening/roles/fail2ban/handlers/main.yml << 'EOF'
---
- name: restart fail2ban
  service:
    name: fail2ban
    state: restarted
EOF

cat > ~/retailedge-hardening/roles/fail2ban/files/jail.local << 'EOF'
[DEFAULT]
backend = systemd
bantime = 3600
findtime = 600
maxretry = 5
banaction = ufw

[sshd]
enabled = true
EOF

# auditd role
cat > ~/retailedge-hardening/roles/auditd/tasks/main.yml << 'EOF'
---
- name: Deploy audit rules
  copy:
    src: 99-retailedge-hardening.rules
    dest: /etc/audit/rules.d/99-retailedge-hardening.rules
    owner: root
    group: root
    mode: '0640'
  notify: restart auditd
EOF

cat > ~/retailedge-hardening/roles/auditd/handlers/main.yml << 'EOF'
---
- name: restart auditd
  service:
    name: auditd
    state: restarted
EOF

cat > ~/retailedge-hardening/roles/auditd/files/99-retailedge-hardening.rules << 'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/sudoers -p wa -k sudoers
-a always,exit -F arch=b64 -S execve -F euid=0 -k privileged_exec
-e 2
EOF

cat > ~/retailedge-hardening/site.yml << 'EOF'
---
- hosts: localhost
  connection: local
  become: yes
  roles:
    - ssh_hardening
    - fail2ban
    - auditd
EOF

ansible-playbook ~/retailedge-hardening/site.yml || true

# ─── SESSION 8: BROKEN STATE SIMULATION ──────────────────────────────────────
# We simulate a private subnet host using a Linux network namespace.
# The namespace has an interface but no default route — identical to an EC2
# instance in a subnet whose route table has no 0.0.0.0/0 entry.

echo "=== Session 8: Creating private-subnet simulation namespace ==="

# Remove the namespace if it already exists (idempotent)
ip netns del private-sim 2>/dev/null || true

# Create the namespace
ip netns add private-sim

# Create a veth pair: veth0 (host side) and veth1 (namespace side)
ip link add veth0 type veth peer name veth1

# Move veth1 into the namespace
ip link set veth1 netns private-sim

# Assign addresses
ip addr add 10.99.0.1/30 dev veth0 2>/dev/null || true
ip link set veth0 up

ip netns exec private-sim ip addr add 10.99.0.2/30 dev veth1
ip netns exec private-sim ip link set veth1 up
ip netns exec private-sim ip link set lo up

# Intentionally do NOT add a default route inside the namespace.
# This is the broken state: the namespace can reach 10.99.0.1 (host side)
# but has no path to 0.0.0.0/0 — exactly what a private subnet EC2 instance
# sees when the route table has no NAT Gateway entry.

echo "=== Bootstrap complete. Broken namespace 'private-sim' is ready. ==="
echo "    Test with: sudo ip netns exec private-sim ping -c 3 8.8.8.8"
echo "    Expected:  connect: Network is unreachable"
