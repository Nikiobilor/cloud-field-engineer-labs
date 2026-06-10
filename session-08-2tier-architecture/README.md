# CFE Training Series — Session 8
## TICKET-008: Two-Tier VPC Architecture — Subnet Isolation, Route Tables, and Security Group Chaining

---

```
TICKET ID:       TICKET-008
Priority:        High
Client:          RetailEdge Ltd
Environment:     AWS EC2 — Ubuntu 22.04 LTS, eu-west-1
Subject:         Backend service unreachable, private subnet routing failure and
                 imprecise security group scoping
Description:     The platform team attempted to extend myapp into a two-tier
                 architecture. The web tier (nginx + myapp) should remain publicly
                 reachable. A new backend service was placed in a private subnet but
                 has no outbound connectivity, and cross-subnet traffic from the web
                 tier also fails. Root causes identified: the private subnet has no
                 route table with a NAT Gateway entry, the public subnet was never
                 explicitly associated with the IGW route table, and the backend
                 security group was scoped to a CIDR block instead of the web tier
                 security group ID, making it brittle as the fleet scales.
Acceptance       - Terraform VPC module under terraform/modules/vpc/ with
Criteria:          variables.tf and outputs.tf
                 - Public subnet explicitly associated with a route table containing
                   an IGW default route
                 - Private subnet has its own route table (no default route, NAT
                   Gateway pattern fully written, commented out, with cost note)
                 - App-tier security group sources port 8080 from the web-sg ID,
                   not a CIDR
                 - Network namespace demo reproduces the private subnet experience
                   on the existing EC2 instance
                 - Handover document includes a routing decision log
                 - All existing Session 1-7 services remain operational
```

---

## Session Goals

By the end of this session you will be able to:

1. Explain the difference between a public subnet and a private subnet in AWS, not just the definition, but what specifically makes each one function
2. Build a reusable Terraform VPC module with correct route table associations for both tiers
3. Articulate why an internet gateway alone is insufficient for private subnet outbound traffic, and what a NAT Gateway actually does
4. Configure security groups where the source is a security group ID rather than a CIDR, and explain when each approach is appropriate
5. Reproduce the private subnet routing failure locally using a Linux network namespace
6. Produce a client-facing handover document with a routing decision log

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Session Bootstrap](#session-bootstrap)
   - [Phase 1 — Terraform Changes](#phase-1--terraform-changes)
   - [Phase 2 — bootstrap-session8.sh](#phase-2--bootstrap-session8sh)
   - [Phase 3 — Running the Script](#phase-3--running-the-script)
   - [Phase 4 — Update GitHub Secrets](#phase-4--update-github-secrets)
3. [Prerequisites](#prerequisites)
4. [Step 1 — Understanding What Makes a Subnet Public or Private](#step-1--understanding-what-makes-a-subnet-public-or-private)
5. [Step 2 — CIDR Sizing: Choosing the Right Block](#step-2--cidr-sizing-choosing-the-right-block)
6. [Step 3 — Terraform Module Structure](#step-3--terraform-module-structure)
7. [Step 4 — Reproducing the Broken State with a Network Namespace](#step-4--reproducing-the-broken-state-with-a-network-namespace)
8. [Step 5 — Writing the VPC Module: Resources and Route Tables](#step-5--writing-the-vpc-module-resources-and-route-tables)
9. [Step 6 — Security Groups: SG ID Source vs CIDR Source](#step-6--security-groups-sg-id-source-vs-cidr-source)
10. [Step 7 — Wiring the Module into Root Configuration](#step-7--wiring-the-module-into-root-configuration)
11. [Step 8 — Applying and Verifying](#step-8--applying-and-verifying)
12. [Step 9 — NAT Gateway: Full Pattern (Cost-Gated)](#step-9--nat-gateway-full-pattern-cost-gated)
13. [Step 10 — Handover Document](#step-10--handover-document)
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
                    ┌───────▼───────┐
                    │ Internet      │
                    │ Gateway (IGW) │
                    └───────┬───────┘
                            │
               ┌────────────▼────────────┐
               │   VPC: 10.0.0.0/16      │
               │                         │
               │  ┌──────────────────┐   │
               │  │  Public Subnet   │   │
               │  │  10.0.1.0/24     │   │
               │  │                  │   │
               │  │  ┌────────────┐  │   │
               │  │  │  EC2 Web   │  │   │
               │  │  │  nginx 443 │  │   │
               │  │  │  myapp 80  │  │   │
               │  │  │  web-sg    │  │   │
               │  │  └─────┬──────┘  │   │
               │  │        │ :8080   │   │
               │  └────────┼─────────┘   │
               │           │             │
               │  ┌────────▼─────────┐   │
               │  │  Private Subnet  │   │
               │  │  10.0.2.0/24     │   │
               │  │                  │   │
               │  │  ┌────────────┐  │   │
               │  │  │  EC2 App   │  │   │
               │  │  │  backend   │  │   │
               │  │  │  :8080     │  │   │
               │  │  │  app-sg    │  │   │
               │  │  └────────────┘  │   │
               │  │  (no IGW route)  │   │
               │  └──────────────────┘   │
               │                         │
               │  [NAT GW — commented    │
               │   out, ~$1/day]         │
               └─────────────────────────┘

Route Table — Public Subnet:
  0.0.0.0/0  →  IGW

Route Table — Private Subnet:
  10.0.0.0/16 →  local  (VPC-internal only)
  0.0.0.0/0  →  [NAT GW — disabled]

Security Group — app-sg:
  Inbound port 8080  source: web-sg (ID reference, not CIDR)
```

**Why this architecture matters for a CFE:**

The single-subnet pattern from Sessions 1-7 was sufficient while myapp served traffic directly. Once a backend service is introduced, placing it on the same subnet as the public-facing tier means a compromised nginx process can reach the backend with the same network path as a legitimate internal call. Subnet separation is the network-layer enforcement of the principle of least privilege. The route table is the mechanism that implements it: remove the default route from the private subnet's route table and the subnet becomes unreachable from the internet by definition, regardless of what happens at the security group layer. This session teaches you to build the foundation that every multi-tier architecture in AWS sits on.

---

## Session Bootstrap

### Phase 1 — Terraform Changes

This session adds a new module invocation and rewrites the VPC-related resources from previous sessions into the new module structure. Add the following to `main.tf`, and create `terraform/modules/vpc/` as shown in Step 3.

> **Why Terraform and not the AWS console?**
> The AWS console would let you create the subnet, route table, and associations manually in minutes. But the next engineer on this account has no record of those decisions, no ability to reproduce them, and no way to review them in a pull request. Terraform makes your architectural intent an auditable text file. When RetailEdge scales from one region to three, you run `terraform apply` with a different region variable, you do not click through the console six times.

Changes to `main.tf` in Phase 1 are shown fully in Step 7. Phase 1 is complete once the module directory structure is in place and variables are defined.

---
mkdir -p session-08-2tier-architecture/scripts
vi session-08-2tier-architecture/scripts 
### Phase 2 — bootstrap-session8.sh

```bash
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
```

---

### Phase 3 — Running the Script

```bash
# Copy the bootstrap script to the new EC2 instance
# Replace <NEW_IP> with the public IP from Terraform output
scp \
    -i ~/.ssh/session8-key.pem \
    bootstrap-session8.sh \
    ubuntu@<NEW_IP>:~/bootstrap-session8.sh

# SSH into the instance
ssh -i ~/.ssh/session8-key.pem ubuntu@<NEW_IP>

# Run the bootstrap with sudo
# The script will take 3-5 minutes on a t2.micro
sudo bash ~/bootstrap-session8.sh
```

**Expected completion output:**

```
=== Bootstrap complete. Broken namespace 'private-sim' is ready. ===
    Test with: sudo ip netns exec private-sim ping -c 3 8.8.8.8
    Expected:  connect: Network is unreachable
```

All previous session services should be active. Confirm:

```bash
systemctl is-active myapp nginx node_exporter auditd fail2ban
```

---

### Phase 4 — Update GitHub Secrets

In your repository under `pawsible-cloud/online-boutique-platform`, update all four secrets:

| Secret | Value |
|---|---|
| `EC2_HOST` | New public IP from Terraform output |
| `EC2_USER` | `ubuntu` |
| `EC2_SSH_KEY` | Contents of new `session8-key.pem` |
| `OPS_IP` | Your current workstation public IP |

---

## Prerequisites

- ✅ EC2 t2.micro running Ubuntu 22.04 — provisioned by Terraform
- ✅ myapp running on 127.0.0.1:8080 — installed by bootstrap
- ✅ nginx reverse proxy with TLS — installed by bootstrap
- ✅ node_exporter on port 9100 — installed by bootstrap
- ✅ UFW firewall configured — installed by bootstrap
- ✅ LVM on /dev/xvdb (if available) — installed by bootstrap
- ✅ Ansible hardening playbook applied — installed by bootstrap
- ✅ auditd and fail2ban active — installed by bootstrap
- ✅ Broken network namespace `private-sim` exists — created by bootstrap
- ✅ Terraform installed on your workstation (≥1.10)
- ✅ AWS CLI configured with `--profile voh-admin`

---

## Step 1 — Understanding What Makes a Subnet Public or Private

**What we are doing and why:**

Before writing a single line of Terraform, you need to be able to answer a question that trips up a surprising number of engineers in interviews and on client calls: *what actually makes a subnet public or private in AWS?*

The answer is not a setting on the subnet itself. It is not a checkbox that says "public" or "private." The answer is the route table associated with the subnet, and specifically whether that route table contains a default route (0.0.0.0/0) pointing to an internet gateway.

That's it. A subnet is public because its route table says: for all traffic not matching a more specific prefix, send it to the IGW. A subnet is private because its route table has no such entry, so any packet destined for the internet has nowhere to go and is dropped.

This matters because it means two subnets in the same VPC can be on the same security group, the same CIDR range family, and the same availability zone, and one will be publicly reachable while the other is not. The distinction lives entirely in the route table.

| Property | Public Subnet | Private Subnet |
|---|---|---|
| Route table default route | 0.0.0.0/0 → IGW | None (or 0.0.0.0/0 → NAT GW) |
| Inbound internet traffic | Possible (if SG allows) | Not possible |
| Outbound internet traffic | Direct via IGW | Via NAT Gateway only |
| Typical workloads | Load balancers, bastion hosts, NAT GW | App servers, databases, internal APIs |
| Public IP assignment | Optional, often enabled | Never (NAT GW handles translation) |

**The IGW alone is not enough for private subnets:**

An internet gateway is bidirectional, it handles both inbound and outbound internet traffic. But for a private subnet, you do not want inbound internet traffic to be possible at all. So you do not point the private subnet's route table at the IGW. Instead, you use a NAT Gateway, which is a managed AWS service sitting in a *public* subnet. Outbound traffic from your private subnet goes to the NAT GW, which forwards it to the IGW on the instance's behalf. The internet sees the NAT GW's public IP, not the private instance's IP, and responses are routed back through the same path. No inbound connection can be initiated from the internet to the private instance because there is no route table entry that would deliver the initial packet.

> **Career note:** When a client says "my EC2 instance can't reach the internet," your first question is: what does the route table look like? Not the security group. Not the NACL. The route table. That is the layer that determines whether a path exists at all. Security groups operate at the packet-acceptance layer, they cannot manufacture a route that does not exist.

---

## Step 2 — CIDR Sizing: Choosing the Right Block

**What we are doing and why:**

Every subnet requires a CIDR block. Choosing the wrong size is a common mistake that locks teams into re-architecturing months later, you cannot resize a subnet in AWS without destroying and recreating it. Understanding the sizing table and the AWS 5-address reservation is a fundamental VPC skill.

**The AWS 5-address reservation:**

For any subnet you create, AWS reserves 5 addresses from your block. For `10.0.1.0/24`:

| Address | Purpose |
|---|---|
| 10.0.1.0 | Network address |
| 10.0.1.1 | VPC router (default gateway) |
| 10.0.1.2 | AWS DNS |
| 10.0.1.3 | Reserved for future use |
| 10.0.1.255 | Broadcast (not used in VPC, but reserved) |

This means a `/24` gives you 256 − 5 = **251 usable addresses**, not 256.

**CIDR sizing table:**

| Block | Total IPs | Usable IPs | Use case |
|---|---|---|---|
| /16 | 65,536 | 65,531 | Entire VPC address space |
| /24 | 256 | 251 | Standard subnet — most common choice |
| /27 | 32 | 27 | Small subnet for NAT Gateways, bastion hosts |
| /28 | 16 | 11 | Minimal subnet, tight environments, transit subnets |
| /32 | 1 | 0 usable | Single host reference in security group rules; cannot be used as a subnet |

**For this session:**

| Subnet | Block | Rationale |
|---|---|---|
| VPC | 10.0.0.0/16 | Gives 65,536 addresses — room to add AZs and tiers later |
| Public subnet | 10.0.1.0/24 | 251 addresses — sufficient for web tier, NAT GW, bastion |
| Private subnet | 10.0.2.0/24 | 251 addresses — matches public subnet sizing for parity |

> **Career note:** Choose your VPC CIDR before you deploy anything else. If you later want to peer two VPCs, their CIDR blocks must not overlap. A `/16` per environment (dev, staging, prod) with `/24` subnets per tier and AZ is the most common pattern you will see in the field. Document your CIDR allocation the same day you create the VPC, recovering that context six months later from the console is painful.

---

## Step 3 — Terraform Module Structure

**What we are doing and why:**

Everything you have built in Terraform so far has lived in a flat `main.tf` at the root. That works for a single resource. Once you have a VPC, subnets, route tables, associations, an internet gateway, a NAT gateway, and security groups, all logically belonging to the same concern, a flat file becomes unreadable and unreusable.

A Terraform module is a directory containing at minimum one `.tf` file. The convention is `variables.tf` for inputs, `outputs.tf` for outputs, and `main.tf` for resources. When you call the module from your root configuration, you pass values to its variables and reference its outputs. This means you can instantiate the same VPC module in dev and prod with different CIDR blocks, different names, and zero code duplication.

Create the directory structure:

```bash
mkdir -p terraform/modules/vpc
```

Your layout will be:

```
terraform/
├── main.tf                  ← root: calls the module
├── variables.tf             ← root: declares input variables
├── outputs.tf               ← root: exposes module outputs
└── modules/
    └── vpc/
        ├── main.tf          ← module: all VPC resources
        ├── variables.tf     ← module: declares what the caller must pass
        └── outputs.tf       ← module: exposes resource IDs to the caller
```

> **Why not just use a single flat main.tf?**
> You could. It would work. But the moment a second environment (staging, prod) needs the same network shape, you would copy-paste the entire VPC block and then maintain two copies. A module means you maintain one definition. The caller provides the parameters. This is the same reason you write functions instead of duplicating code, and it is exactly the argument you will make to a client who is managing infrastructure by clicking through the console.

---

## Step 4 — Reproducing the Broken Ste with a Network Namespace

**What we are doing and why:**

Before fixing the routing problem in Terraform, you need to see it. The bootstrap created a Linux network namespace called `private-sim` that has an interface with an IP address but no default route. This is a precise simulation of an EC2 instance sitting in a subnet whose route table has no 0.0.0.0/0 entry, which is exactly the situation the RetailEdge backend service was in.

A network namespace is a Linux kernel feature that creates an isolated copy of the network stack: its own interfaces, routing table, firewall rules, and socket table. Processes can be run inside it. This is the same mechanism Docker uses to isolate container networking.

**Step 4.1 — Observe the namespace routing table:**

```bash
# List all network namespaces on the system
sudo ip netns list
```

Expected output: `private-sim`

```bash
# Show the routing table inside the namespace
# ip netns exec runs a command inside the named namespace
sudo ip netns exec private-sim ip rte show
```

Expected output:

```
10.99.0.0/30 dev veth1 proto kernel scope link src 10.99.0.2
```

There is exactly one route: the connected route for the veth link. There is no `default via` entry. This means any destination outside `10.99.0.0/30` has no route.

**Step 4.2 — Attempt outbound connectivity:**

```bash
# Try to reach the internet from inside the namespace
sudo ip netns exec private-sim ping -c 3 8.8.8.8
```

Expected output:

```
ping: connect: Network is unreachable
```

This is the errothe RetailEdge team was seeing. The kernel checked the routing table, found no matching entry for 8.8.8.8, and rejected the packet locally, it never even left the host.

**Step 4.3 — Show what the fix looks like (without NAT Gateway cost):**

```bash
# Enable IP forwarding on the host so it can act as a router
sudo sysctl -w net.ipv4.ip_forward=1

# Add a default route inside the namespace pointing at the host-side veth IP
# This simulates adding a NAT Gateway route to the route table
sudo ip netns exec pvate-sim ip route add default via 10.99.0.1

# Add NAT on the host side so outbound traffic from the namespace is translated
sudo iptables -t nat -A POSTROUTING -s 10.99.0.0/30 -j MASQUERADE
```

```bash
# Now test connectivity from the namespace
sudo ip netns exec private-sim ping -c 3 8.8.8.8
```

This will now succeed, the namespace has a route to follow, and the host is performing NAT on its behalf. This is exactly what a NAT Gateway does for a private subnet, except AWS manages the NAT Gateway as a highly available, fully managed service so you do not have to run iptables rules on an EC2 instance.

```bash
# Clean up the iptables rule after the demo
sudo iptables -t nat -D POSTROUTING -s 10.99.0.0/30 -j MASQUERADE

# Remove the default route from the namespace to restore the broken state
sudo ip netns exec private-sim ip route del default
```

> **Career note:** Network namespaces are not just a lab tool. They are the foundation of Kubernetes pod networking, Docker container networking, and tools like `netns`-based VPN clients. If you can reason about namespaces, you can reason about why two pods in the same cluster can or cannot talk to each other, and that is a question that comes up in every Kubernetes production incident.

---

## Step 5 — Writing the VPC Module: Resources and Route Tables

**What we are doing and why:**

Now you build the actual Terraform module. Every resource here corresponds directly to something visible in the AWS console. Understanding what each resource does, and crucially whawould break if you removed it, is what separates an engineer who can build infrastructure from one who can explain it to a client.

**Step 5.1 — Module variables file:**
Go to your local terraform folder on session 8 to create this
Create `terraform/modules/vpc/variables.tf`:

```hcl
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
}

variable "private_subnet_ci" {
  description = "CIDR block for the private subnet"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for both subnets"
  type        = string
}

variable "environment" {
  description = "Environment label applied to all resource Name tags"
  type        = string
}
```

**Step 5.2 — Module main.tf:**

Create `terraform/modules/vpc/main.tf`:

```hcl
# ─── VPC ────────────────────────────────â───────────────────────────

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # required for EC2 instances to resolve AWS service endpoints by hostname
  enable_dns_support = true

  # required for instances to receive a DNS hostname from AWS
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── INTERNET GATEWAY ─────â────────────────────────────────────────
# The IGW is the VPC's connection to the internet.
# It performs one-to-one NAT for instances that have a public IP address.
# Without this resource, no traffic can leave or enter the VPC from the internet —
# even if you add 0.0.0.0/0 to a route table, the route has nowhere to point.

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "r.environment}-igw"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC SUBNET ───────────────────────────────────────────────────────────
# This subnet is "public" because we will associate it with a route table
# that has a default route pointing to the IGW.
# map_public_ip_on_launch means instances in this subnet automatically receive
# a public IP âthe web tier to be reachable from the internet.

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-public-subnet"
    Environment = var.environment
    Tier        = "public"
    ManagedBy   = "Terraform"
  }
}

# ─── PRIVATE SUBNET ────────────────────â──────────────────────
# This subnet is "private" because we will associate it with a route table
# that has NO default route to the internet.
# map_public_ip_on_launch is explicitly false — instances here should never
# receive a public IP. Outbound internet access (if needed) must go via NAT GW.

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.environment}-private-subnet"
    Environment = var.environment
    Tier        = "private"
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC ROUTE TABLE ───────────────────────────────────────────────────────
# A route table is a set of rules that tells the VPC router where to send packets.
# The VPC routerays exists — you cannot remove it. You configure it by
# defining route tables and associating them with subnets.
#
# This route table has two routes:
#   - 10.0.0.0/16 local (automatically added by AWS for all VPC-internal traffic)
#   - 0.0.0.0/0 → IGW  (added explicitly below — this is what makes the subnet public)

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    # all traffic not matched by a more specific prefix goes to the IGW
    cidr_block = "0.0.0.0/0"
    gate = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-public-rt"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── PUBLIC ROUTE TABLE ASSOCIATION ──────────────────────────────────────────
# A route table must be explicitly associated with a subnet.
# Without this association, the subnet uses the VPC's default route table,
# which has no default route — effecg it private by accident.
# This was one of the root causes of the RetailEdge ticket: the public subnet
# was never explicitly associated with the IGW route table.

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── PRIVATE ROUTE TABLE ─────────────────────────────────────────────────────
# The private route table intentionally has no default route.
# This ensures no traffic from a private subnet instance can reach the internet
# directly. The only route is the implicit local route (VPC CIDR → local),
# which allows intra-VPC traffic between the web tier and the app tier.
#
# When NAT Gateway is enabled (see Step 9), a 0.0.0.0/0 → NAT GW route is added.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-private-rt"
    Environment = var.ennment
    ManagedBy   = "Terraform"
  }
}

# ─── PRIVATE ROUTE TABLE ASSOCIATION ─────────────────────────────────────────

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
```

**Step 5.3 — Module outputs file:**

Create `terraform/modules/vpc/outputs.tf`:

```hcl
output "vpc_id" {
  description = "ID of the created VPC"
  valuews_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet"
  value       = aws_subnet.private.id
}

output "public_route_table_id" {
  description = "ID of the public route table"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID of the private route table"
  value       = aws_route_table.private.id
}
```

> **Why outputs matter:** The module produces these IDs and nothing else. The root configuration uses them to place the EC2 instance in the correct subnet, to attach security groups to the right VPC, and to reference the VPC ID in future sessions when you add VPC Flow Logs, peering connections, or additional modules. Outputs are the module's public API. If a resource ID is not in `outputs.tf`, no caller can use it.

---

## Step 6 — Security Groups: SG ID Source vs CIDR Source

**What we are doing and why:**

The seconroot cause in the RetailEdge ticket was that the app-tier security group used a CIDR block as the source rule for port 8080. This section explains exactly why that is a problem, when you would use each approach, and how to write the correct configuration.

**The broken pattern (CIDR source):**

```hcl
ingress {
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  # allows any host in the public subnet CIDR — not just the web tier
  cidr_blocks = ["10.0.1.0/24"]
}
```

This says: allow port 80 from any IP address in `10.0.1.0/24`. On day one, when there is one EC2 instance in that subnet, this works. But:

- A developer spins up a bastion host in the public subnet for a debugging session. That bastion is now in `10.0.1.0/24`. It can reach the backend on port 8080, even though it is not the web tier.
- A second web server is added in a different subnet (`10.0.3.0/24`). The rule does not cover it. The backend is unreachable from the new server. You have to update the security group and remember why you chose `/24`.
- Six months later, a security audit asks: which resources can reach the backend on port 8080? The auditor cannot answer from the CIDR alone, they have to cross-reference which instances are in `10.0.1.0/24` at that moment in time.

**The correct pattern (SG ID source):**

```hcl
ingress {
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  # source is the web-sg ID: only instances in web-sg can reach this port
  security_groups          = [aws_security_group.web.id]
}
```

This says: allow port 8080 from any instance that has `web-sg` attached. The security group is the identity. It does not matter what subnet the instance is in, what IP it has, or how many web servers are in the fleet. Every instance with `web-sg` can reach the backend. Every instance without it cannot. The access control follows the role, not the address.

| Dimension | CIDR source | SG ID source |
|---|---|---|
| Precision | Any IP in the subnet | Any instance with the named SG |
| Scales with fleet growth | Breaks (new subnets, new instances) | Works automatically |
| Readable in audit | Requires IP-to-instance lookup | Self-documenting |
| Cross-VPC use | Works (with peering) | Works only within same VPC or peered VPC |
| When to use | Internet-facing rules (0.0.0.0/0), trusted CIDR ranges (office VPN) | Internal service-to-service rules |

**When to use a CIDR source:**

Use CIDR when the source is external and has no security group, the internet (`0.0.0.0/0` for HTTP/HTTPS), a specific office IP, or a peered VPC CIDR where you do not own the SGs. Use SG ID for all internal service-to-service rules where both sides are AWS resources you control.

**Create the security groups module resource in `terraform/modules/vpc/main.tf`:**

Add the following to the bottom of the module's `main.tf`:

```hcl
# ─── WEB TIER SECURITY GROUP ───────────────────────────────────────────────resource "aws_security_group" "web" {
  name        = "${var.environment}-web-sg"
  description = "Web tier: allows HTTPS from internet, SSH from ops"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from internet — redirected to HTTPS by nginx"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0/0"]
  }

  ingress {
    description = "SSH — scoped to ops IP in calling module"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip_cidr]
  }

  ingress {
    description = "node_exporter — scoped to ops IP"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip_cidr]
  }

  egress {
    description = "all outbound traffic allowed"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks"0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-web-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── APP TIER SECURITY GROUP ──────────────────────────────────────────────────
# The source for port 8080 is the web-sg ID — not a CIDR.
# This means exactly: allow port 8080 from any instance that is a member of
# web-sg. No other resource in the VPC can ort, regardless of subnet.

resource "aws_security_group" "app" {
  name        = "${var.environment}-app-sg"
  description = "App tier: allows port 8080 from web-sg only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "backend port — web-sg members only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    description = "all outbound traffic allowed"
    from_port   = 0
    to_port     =
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-app-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
```

Add `ops_ip_cidr` to `terraform/modules/vpc/variables.tf`:

```hcl
variable "ops_ip_cidr" {
  description = "CIDR for the ops workstation IP (e.g. 203.0.113.10/32)"
  type        = string
}
```

Add security group outputs to `terraform/modules/vpc/outputs.tf`:

```hcl
output "web_sg_id" {
  description = "ID of the web-tier security group"
  value       = aws_security_group.web.id
}

output "app_sg_id" {
  description = "ID of the app-tier security group"
  value       = aws_security_group.app.id
}
```

---

## Step 7 — Wiring the Module into Root Configuration

**What we are doing and why:**

The module is now a self-contained component. The root configuration calls it, passing values for every variable the module declared. The root configuration also maintains the EC2 instance resource from previous sessions, it noweferences the module's outputs for subnet placement and security group attachment.

**Root `terraform/variables.tf`:** add or ensure these variables exist:

```hcl
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment label"
  type        = string
  default     = "retailedge-lab"
}

variable "ops_ip" {
  description = "Ops workstation public IP (without /32 suffix)"
  type        = string
}

variable "availability_zone" {
  description = "AZ for subnets and EC2 instance"
  type        = string
  default     = "eu-west-1a"
}
```

**Root `terraform/main.tf`:** replace or extend with:

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "retailedge-tfstate"
    key     = "session8/terraform.tfstate"
    region  = "eu-west-1"
    # native Terraform 1.10 lock file — no DynamoDB table required
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "voh-admin"
}

# ─── VPC MODULE ───────────────────────────────────────────────────────────────
# This call instantiates the VPC module with RetailEdge lab parameters.
# All network resources (VPC, subnets, route tables, SGs) are created inside
# the module.oot module references outputs to place the EC2 instance.

module "vpc" {
  source = "./modules/vpc"

  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24"
  private_subnet_cidr = "10.0.2.0/24"
  availability_zone   = var.availability_zone
  environment         = var.environment
  ops_ip_cidr         = "${var.ops_ip}/32"
}

# ─── KEY PAIR ───────────────────────────────────────────────────────────

resource "aws_key_pair" "session8" {
  key_name   = "session8-key"
  public_key = file("~/.ssh/session8-key.pub")
}

# ─── EC2 INSTANCE — WEB TIER ─────────────────────────────────────────────────
# Placed in the public subnet so nginx is reachable from the internet.
# Security group is web-sg from the module output.

resource "aws_instance" "web" {
  ami           = "ami-0a897eded6e6b6048"
  instance_type = "t2.micro"

  subnet_id                   = module.vpc.public_subnet_id
  vpc_security_group_ids      = [module.vpc.web_sg_id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.session8.key_name

  root_block_device {
    # 20GB root volume — expanded from 8GB in Session 5
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name        = "${var.environment}-web"
    Environment = var.environment
    ManagedBy   = "Terrafm"
    Session     = "8"
  }
}
```

**Root `terraform/outputs.tf`:**

```hcl
output "web_instance_public_ip" {
  description = "Public IP of the web tier EC2 instance"
  value       = aws_instance.web.public_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = module.vpc.public_subnet_id
}

output "private_subnet_id" {
  description = "Private subnet ID"
  value       = module.vpc.private_subnet_id
}

output "web_sg_id" {
  description = "Web-tier security group ID"
  value       = module.vpc.web_sg_id
}

output "app_sg_id" {
  description = "App-tier security group ID"
  value       = module.vpc.app_sg_id
}
```

---

## Step 8 — Applying and Verifying

**What we are doing and why:**

With the module written and wired, you run the standard Terraform workflow: init to download providers and initialise the backend, plan to preview the change set, apply to execute it.

**Step 8.1 — Initialise:**

`sh
cd terraform

# -upgrade: re-downloads provider plugins; useful after adding a new module
terraform init -upgrade
```

**Step 8.2 — Plan:**

```bash
# -var: pass the ops_ip variable on the command line
# replace <YOUR_IP> with your workstation's current public IP
terraform plan \
    -var="ops_ip=<YOUR_IP>"
```

Review the plan output. You should see resources being created, not destroyed — unless you are migrating from a flat configuration. Look specifically for:

- `aws_vpc.main` — the VPC itselfs_internet_gateway.main` — the IGW
- `aws_subnet.public` and `aws_subnet.private`
- `aws_route_table.public` with a `0.0.0.0/0` route
- `aws_route_table.private` with no default route
- `aws_route_table_association.public` and `.private`
- `aws_security_group.web` and `aws_security_group.app`
- The `app` SG's ingress rule sourcing from `aws_security_group.web.id`

**Step 8.3 — Apply:**

```bash
# -auto-approve: skip the interactive yes/no prompt
terraform apply \
    -auto-approve \
    -var="ops_ip=<YOP>"
```

**Step 8.4 — Verify outputs:**

```bash
# Show all root outputs with current values
terraform output
```

Expected output:

```
app_sg_id              = "sg-0abc123..."
private_subnet_id      = "subnet-0def456..."
public_subnet_id       = "subnet-0ghi789..."
vpc_id                 = "vpc-0jkl012..."
web_instance_public_ip = "54.x.x.x"
web_sg_id              = "sg-0mno345..."
```

**Step 8.5 — Verify route tables in AWS console or CLI:**

```bash
# Describe route tables tagged for this environmews ec2 describe-route-tables \
    --profile voh-admin \
    --filters "Name=tag:Environment,Values=retailedge-lab" \
    --query "RouteTables[*].{Name:Tags[?Key=='Name']|[0].Value,Routes:Routes}"
```

Confirm: the public route table has a route with `GatewayId` starting with `igw-`. The private route table has only the `local` route.

**Step 8.6 — Verify security group source:**

```bash
# Show the app-sg ingress rules and confirm the source is an SG ID, not a CIDR
aws ec2 describe-security-groups \
    profile voh-admin \
    --filters "Name=tag:Name,Values=retailedge-lab-app-sg" \
    --query "SecurityGroups[*].IpPermissions"
```

Confirm: `UserIdGroupPairs` is populated and `IpRanges` is empty for port 8080.

---

## Step 9 — NAT Gateway: Full Pattern (Cost-Gated)

**What we are doing and why:**

The private subnet currently has no outbound internet route. For this session's learning objective, demonstrating subnet isolation, that is intentional. But in a real environment, the backend service needs toull package updates, reach AWS services (S3, Secrets Manager), and send logs to an external sink. That requires a NAT Gateway.

A NAT Gateway lives in a public subnet and has an Elastic IP. Instances in the private subnet send their outbound traffic to the NAT GW's private IP (via the route table). The NAT GW translates the source IP to its Elastic IP, forwards the packet to the IGW, and routes the response back to the originating instance. No inbound connection from the internet can reach the private instance because the NAT GW only performs outbound translation, it does not have a mechanism to initiate or deliver unsolicited inbound connections.

**Cost note:** A NAT Gateway in eu-west-1 costs approximately $0.048 per hour plus $0.048 per GB processed, approximately **$34/month or $1/day** at idle. This is the reason it is not deployed in this session. For a lab environment running sporadically, that cost is unjustified. Uncomment the blocks below when cost is not a constraint.

Add the following to `terraform/modules/vpc/main.tf`:

```hcl
# ─── NAT GATEWAY (COST-GATED: uncomment when ~$1/day is acceptable) ──────────
#
# A NAT Gateway requires an Elastic IP and must be placed in a PUBLIC subnet.
# It is not the same as a NAT instance — it is a managed, highly available
# AWS service with no OS to patch, no instance type to size, and automatic
# scaling. A NAT instance (an EC2 instance with IP forwarding enabled) is
# cheaper but operationally complex and single-point-of-failure.

aws_eip" "nat" {
#   domain = "vpc"
#
#   tags = {
#     Name        = "${var.environment}-nat-eip"
#     Environment = var.environment
#     ManagedBy   = "Terraform"
#   }
# }

# resource "aws_nat_gateway" "main" {
#   allocation_id = aws_eip.nat.id
#
#   # NAT Gateway must sit in the PUBLIC subnet, it needs an IGW route
#   # to forward outbound traffic from private instances to the internet
#   subnet_id = aws_subnet.public.id
#
#   tags = {
#     Name        = "${var.environment}-nat-gw"
#     Environment = var.environment
#     ManagedBy   = "Terraform"
#   }
#
#   # the IGW must exist before the NAT GW can be created
#   depends_on = [aws_internet_gateway.main]
# }

# ─── PRIVATE ROUTE TABLE DEFAULT ROUTE VIA NAT GW ────────────────────────────
# Uncomment this block together with the NAT Gateway resources above.
# This adds a 0.0.0.0/0 → NAT GW route to the private route table,
# giving private subnet instances outbound internet access.
# Without this, the NAT GW exists but private instances have no route to it.

# resource "aws_route" "private_nat" {
#   route_table_id         = aws_route_table.private.id
#   destination_cidr_block = "0.0.0.0/0"
#   nat_gateway_id         = aws_nat_gateway.main.id
# }
```

> **Cost optimisation — VPC Endpoints:** For traffic to AWS services (S3, ECR, Secrets Manager, SSM), a VPC Endpoint eliminates the need for a NAT Gateway entirely for those specific destinations. A Gateway Endpoint for S3 is free. An terface Endpoint (PrivateLink) for other services costs ~$7/month per AZ, significantly less than a NAT Gateway for workloads that primarily need to reach AWS services. This is a common cost optimisation question in architecture reviews.

---

## Step 10 — Handover Document

**What we are doing and why:**

Every piece of infrastructure you build for a client must be documented in terms they can act on, not just a list of what was created, but why each decision was made. A routing decision log is the archictural equivalent of a commit message: it records the reasoning so the next engineer does not have to reverse-engineer it from the resource configuration.

---

```
═══════════════════════════════════════════════════════════════════════════════
RETAILEDGE LTD — INFRASTRUCTURE HANDOVER DOCUMENT
Session 8: Two-Tier VPC Architecture
Prepared by:  [Your Name], Cloud Field Engineer
Date:         [Date]
Environment:  retailedge-lab — AWS eu-west-1
Ticket:       TICKET-008
═══════════════════════════════════════════════════════════════════════════════

1. CHANGE SUMMARY

This session restructured the RetailEdge network from a single flat subnet into
a two-tier VPC architecture. The web tier (nginx + myapp) remains in a public
subnet with a direct internet route. A private subnet was added for the backend
service, isolated from the internet at the routing layer. Two security groups
were created with a source reference from app-sg to web-sg using the web-sg
security group ID, not a CIDR block.

2. RESOURCES CREATED

Resource                            ID                      Notes
──────────────────────────────────────────â─────────────────────────────
VPC                                 vpc-0xxx...             10.0.0.0/16
Internet Gateway                    igw-0xxx...             attached to VPC
Public Subnet                       subnet-0xxx...          10.0.1.0/24, eu-west-1a
Private Subnet                      subnet-0xxx...          10.0.2.0/24, eu-west-1a
Route Table (public)                rtb-0xxx...             0.0.0.0/0 → IGW
Route Table (private)      xxx...             local route only
RT Association (public)             [implicit]
RT Association (private)            [implicit]
Security Group (web-sg)             sg-0xxx...              443, 80, 22, 9100
Security Group (app-sg)             sg-0xxx...              8080 source: web-sg ID
EC2 Instance (web)                  i-0xxx...               t2.micro, public subnet

3. ROUTING DECISION LOG

Decision: Why create an explicit public route table instead of using the default?

  The default VPC route table in AWS has no default route to an internet gateway
  when you create a custom VPC (non-default VPC). The previous session's
  environment used a default VPC, which auto-configures the default route table
  with an IGW entry. In a custom VPC, if you do not create and associate an
  explicit route table, your subnets inherit the default route table, which
  has only a local route. The public subnet was unreachable from the internet
  precisely because no explicit association existed. Creating a named route table
  and associating it makes the architectural intent visible and auditable.

Decision: Why does the private route table have no default route?

  Subnet isolation is enforced at the routing layer, not the security group layer.
  A security group can block inbound connections, but it cannot prevent the
  routing infrastructure from accepting and routing packets. By removing the
  default route from the private subnet's route table, we ensure that no packet
  from the internet can ever be delivered to a private subnet instance, the
  routing infrastructure discards it before any security group evaluation occurs.
  This is defence in depth: two independent layers must both be misconfigured
  before the private subnet becomes reachable.

Decision: Why use a NAT Gateway instead of a NAT instance?

  A NAT instance is an EC2 instance with IP forwarding enabled, running iptables
  MASQUERADE rules. It is cheaper but introduces operational complexity: it must
  be patched, sized correctly, monitored for failures, and placed behind a
  redundancy mechanism if high availability is required. A NAT Gateway is a
  managed AWS service: highly available within an AZ, auto-scaling, no OS to
  patch. For a production workload, the operational savings justify the ~$34/month
  cost. For this lab environment, the NAT Gateway is documented but not deployed
  due to cost constraints. The private subnet currently has no outbound internet
  access; this is acceptable while the backend service does not require external
  connectivity.

Decision: Why use a security group ID as the source for app-sg port 8080?

  Using a CIDR block (10.0.1.0/24) as the source couples the access rule to a
  network address range rather than an identity. As the web tier fleet grows,
  adding instances in new subnets, new AZs, or new regions, the CIDR-based rule
  must be updated each time. An incorrect or stale CIDR can either block legitimate
  traffic or allow unintended access from any host in the subnet range. Using the
  web-sg security group ID as the source means the rule follows the role: any
  instance that is a member of web-sg can reach the backend on port 8080,
  regardless of its IP address or subnet. The access policy is defined once and
  scales automatically.

Decision: Why use a /16 VPC with /24 subnets?

  A /16 provides 65,536 IP addresses, giving room to add availability zones,
  environment tiers, and additional services without re-addressing. The /24
  subnets (251 usable addresses each) are the standard choice for workload
  subnets: large enough that you are unlikely to exhaust addresses in a single
  tier, small enough that the CIDR is meaningful to a human reading it. The
  first octet of the subnet second octet encodes the tier (1 = public, 2 =
  private), making the addressing scheme self-documenting in logs and
  security group rules.

4. SERVICES UNCHANGED FROM PREVIOUS SESSIONS

All Session 1-7 services remain operational:
  - myapp.service (port 8080, loopback only)
  - nginx (ports 80 and 443, TLS with self-signed certificate)
  - node_exporter (port 9100, ops IP only)
  - ufw firewall (rules applied by configure-firewall.sh)
  - auditd with CIS Section 4 ruleset
  - fail2ban with SSH jail
  - SSH hardening via Ansible playbook
  - Kernel tuning via /etc/sysctl.d/99-canonical-lab-tuning.conf

5. WHAT IS NOT YET DEPLOYED

  - NAT Gateway: Terraform resources are written and commented out.
    Uncomment aws_eip.nat, aws_nat_gateway.main, and aws_route.private_nat
    in terraform/modules/vpc/main.tf to deploy. Estimated cost: ~$1/day.
  - Backend EC2 instance in private subnet: subnet and security group exist;
    instance resource to be added in a future session.
  - Multi-AZ extension: current subnets are in a single AZ (eu-west-1a).
    To add AZ resilience, duplicate the public/private subnet pair for eu-west-1b,
    add a second NAT Gateway in the second public subnet, and update the route
    table associations accordingly.

6. HOW TO VERIFY

  terraform output                          → confirm all resource IDs
  aws ec2 scribe-route-tables ...         → confirm IGW route on public RT
  aws ec2 describe-security-groups ...      → confirm app-sg source is SG ID
  curl -k https://<web_ip>                  → confirm nginx/TLS still operational
  systemctl is-active myapp nginx auditd    → confirm OS services unchanged

7. TERRAFORM STATE

  Backend: S3 — s3://retailedge-tfstate/session8/terraform.tfstate
  Locking:  native Terraform 1.10 use_lockfile = true (no DynamoDB required)
  Profile:  voh-admin

════â══════════════════════════════════════════════════════════════════════
```

---

## Step 11 — Commit Your Work

```bash
cd ~/retailedge-lab

git add terraform/modules/vpc/main.tf \
        terraform/modules/vpc/variables.tf \
        terraform/modules/vpc/outputs.tf \
        terraform/main.tf \
        terraform/variables.tf \
        terraform/outputs.tf \
        bootstrap-session8.sh \
        handover-session8.md

git commit -m "feat(session8): two-tier VPC module with subnet isolation and SG chaining

- Added terraform/modules/vpc/ with main.tf, variables.tf, outputs.tf
- Public subnet (10.0.1.0/24) explicitly associated with IGW route table
- Private subnet (10.0.2.0/24) isolated — no default route, no internet path
- web-sg: allows 443/80 from internet, 22/9100 from ops IP
- app-sg: allows 8080 from web-sg ID only (not CIDR — scales with fleet)
- NAT Gatepattern written out in commented Terraform — uncomment to deploy
- Root main.tf updated to call module; EC2 instance placed in public subnet
- bootstrap-session8.sh: cumulative Sessions 1-7 rebuild + network namespace
  broken state simulation (private-sim: no default route)
- Handover document includes routing decision log for all architectural choices

Session 8 of Canonical CFE Training Series — RetailEdge Ltd
Ticket: TICKET-008"
```

---

## Verification Checklist

```bash
# 1. VPC exists with correIDR
aws ec2 describe-vpcs \
    --profile voh-admin \
    --filters "Name=tag:Environment,Values=retailedge-lab" \
    --query "Vpcs[*].CidrBlock"
# Expected: ["10.0.0.0/16"]

# 2. Public subnet has map_public_ip_on_launch = true
aws ec2 describe-subnets \
    --profile voh-admin \
    --filters "Name=tag:Tier,Values=public" \
    --query "Subnets[*].MapPublicIpOnLaunch"
# Expected: [true]

# 3. Public route table has IGW default route
aws ec2 describe-route-tables \
    --profile voh-admin \
    --filters "Name=tag:Name,Values=retailedge-lab-public-rt" \
    --query "RouteTables[*].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId"
# Expected: [["igw-0xxx..."]]

# 4. Private route table has NO default route
aws ec2 describe-route-tables \
    --profile voh-admin \
    --filters "Name=tag:Name,Values=retailedge-lab-private-rt" \
    --query "RouteTables[*].Routes[?DestinationCidrBlock=='0.0.0.0/0']"
# Expected: [[]]

# 5. app-sg port 8080 source is a SG ID, not a CIDR
aws ec2 describe-security-groups \
    --profile voh-admin \
    --filters "Name=tag:Name,Values=retailedge-lab-app-sg" \
    --query "SecurityGroups[*].IpPermissions[?FromPort==\`8080\`].UserIdGroupPairs[*].GroupId"
# Expected: [["sg-0xxx..."]]  (IpRanges should be empty)

# 6. Broken namespace confirms no route
sudo ip netns exec private-sim ip route show
# Expected: 10.99.0.0/30 dev veth1 proto kernel scope link src 10.99.0.2
# (no default route line)

# 7. Broken namespace cannot reach internet
sudo ip netns exec private-sim ping -c 1 8.8.8.8
# Expected: connect: Network is unreachable

# 8. All Session 1-7 services still active
systemctl is-active myapp nginx node_exporter auditd fail2ban
# Expected: active active active active active

# 9. nginx TLS still serving
curl -sk https://localhost | head -1
# Expected: [<timestamp>] myapp OK

# 10. Terraform state is clean
terraform plan -var="ops_ip=<YOUR_IP>" 2>&1 | tail -3
# Expected: No changes. Your infrastructure matches the configuration.
```

---

## Troubleshooting Reference

| Symptom | Diagnostic command | Fix |
|---|---|---|
| `terraform init` fails with backend error | `cat terraform/.terraform/terraform.tfstate` | Confirm S3 bucket exists and voh-admin has `s3:GetObject`, `s3:PutObject` permissions |
| `Error: Invalid provider configuration` on apply | `terraform providers` | Run `terraform init -upgrade` to re-download providers |
| EC2 instance has no public IP after apply | `terraform output web_instance_public_ip` | Confirm `associate_public_ip_address = true` and subnet has `map_public_ip_on_launch = true` |
| `aws_security_group.app` creation fails: `DependencyViolation` | `terraform graph | grep sg` | `aws_security_group.app` must be created after `aws_security_group.web`; Terraform handles this via the `security_groups` reference — confirm you are not hardcoding the SG ID |
| Private namespace can reach internet unexpectedly | `sudo ip netns exec private-sim ip route show` | A default route was added during the fix demo; remove with `sudo ip netns exec private-sim ip route del dault` |
| nginx returns 502 after rebuild | `systemctl status myapp` | myapp may not have started in time; `sudo systemctl restart myapp && sudo systemctl restart nginx` |
| `Error: creating Route Table Association: InvalidSubnetID` | `terraform state list` | Subnet may have been recreated; run `terraform apply` again to reconcile |
| Session 7 Ansible playbook fails during bootstrap | `ansible-playbook --syntax-check ~/retailedge-hardening/site.yml` | YAML indentation error in generated role files; re-run bootstrap or fix the specific role task file |
| `sshd -t` fails after bootstrap | `sudo sshd -T 2>&1 | head -20` | AllowUsers directive may conflict with current user; confirm `ubuntu` is in the `AllowUsers` line |
| `crontab -l` shows duplicate entries | `crontab -l | grep myapp-alert` | Bootstrap uses `grep -v` to deduplicate before adding; if duplicates exist, clear with `crontab -r && sudo bash ~/bootstrap-session8.sh` |

---

## What You Learned This Session

| Skill | Career asset |
|---|---|
| VPC architecture: what makes a subnet public or private | Every client architecture conversation starts here. You can now draw the diagram on a whiteboard and explain every line — not just point at it. |
| Route tables and explicit subnet associations | Route table misconfiguration is one of the most common causes of "my instance can't reach X." You now know how to read the routing table and trace a packet's path before it leaves the VPC. |
| Internet Gateway vs NAT Gateway — when and why | Clients routinelyflate these. Being able to explain the difference, the cost model, and the security implication of each places you above most engineers who just follow a tutorial. |
| Terraform module structure with variables.tf and outputs.tf | Reusable modules are the difference between a Terraform file you can share and one that only works in your account. This is the skill that gets you hired for large infrastructure migrations. |
| Security group source: SG ID vs CIDR | You can now articulate exactly why the CIDR pattern breaks at scale and write the correct SG reference. This comes up in every security review. |
| Linux network namespaces | You reproduced an AWS routing failure locally without any AWS cost. This debugging tool is reusable for Kubernetes, Docker, and any Linux networking problem. |
| Routing decision log in handover documents | Documentation is not a box to tick — it is the artefact that lets the next engineer make correct decisions without calling you. Clients notice when you deliver this. |

---

##o Deeper

**1. Multi-AZ extension:**
The current design places both subnets in a single availability zone (`eu-west-1a`). If that AZ has an outage, the entire stack goes down. How would you extend the Terraform module to support two AZs? What resources need to be duplicated, and what changes in the module's variable signature? Consider: if you add a second NAT Gateway in the second AZ (best practice), what does the cost model look like, and when is a single NAT Gateway in one AZ an acceptable trade-off?

**2. VPC Flow Logs:**
VPC Flow Logs capture metadata about every accepted and rejected packet at the ENI level. They do not capture packet contents, but they record source IP, destination IP, port, protocol, bytes, and accept/reject status. How would you enable Flow Logs for this VPC using Terraform, writing logs to CloudWatch Logs? What IAM role does the Flow Log resource require, and how would you write a query in CloudWatch Insights to identify all rejected connections to the app-sg on port 8080 in the last 24 hours? How does Flow Logs compare to packet capture tools like tcpdump — what does each see, and what does each miss?

**3. NAT cost optimisation with VPC Endpoints:**
A NAT Gateway charges per GB processed in addition to the hourly fee. For a workload that primarily communicates with S3, SSM, ECR, and Secrets Manager, all outbound traffic to those services travels through the NAT Gateway and incurs data transfer charges. A Gateway Endpoint for S3 is free and routes S3 traffic inside the VPC, bypassi the NAT Gateway entirely. Interface Endpoints (PrivateLink) for other AWS services cost ~$7/month per AZ per endpoint. At what data volume does replacing a NAT Gateway with VPC Endpoints break even? When would you recommend keeping the NAT Gateway regardless?

**4. CloudTrail vs VPC Flow Logs — business context:**
A client's security team asks: "We need an audit trail that shows who made infrastructure changes and a separate log showing what network traffic occurred." Which tool answers the first questioand which answers the second? CloudTrail records API calls to the AWS control plane — who called `RunInstances`, who modified a security group, who deleted a route. VPC Flow Logs records data plane traffic — which IP connected to which port, and whether it was accepted or rejected. Can either tool replace the other? In a compliance conversation (PCI-DSS, ISO 27001), which would you enable first, and why? How does this distinction map to the difference between auditd (which you configured in Session 7) aginx access logs — which layer does each operate at?

**Recommended reading:**
- AWS VPC documentation — "Route tables" and "Internet gateways" sections
- Terraform documentation — "Module composition" and "Module sources"
- AWS re:Post — "Choosing between NAT Gateways and NAT instances"
- Ned Bellavance, *Terraform: Up and Running* (O'Reilly) — Chapter 4 on reusable modules

---

## Next Session


