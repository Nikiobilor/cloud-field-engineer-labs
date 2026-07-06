# CFE Training Series — Session 12
## Python API Calls + OpenStack Storage + MicroCeph + Written Interview Prep
### Junior Cloud Field Engineer Readiness | RetailEdge Ltd

---

> **Standalone session.** This session provisions everything it needs from scratch by default. If you deliberately left a Session 11 instance running with MicroStack already installed, an optional shortcut is marked below, but the default path assumes nothing is inherited.
>
> **Time split suggestion:**
> **Day 1:** Blocks 1, 2, and 3 — Infrastructure + Python Slack alerting (~2 hours)
> **Day 2:** Blocks 4 and 5 — OpenStack Cinder + MicroCeph + Written interview (~1 hour)

---

## The Client Ticket

**Client:** RetailEdge Ltd
**Submitted by:** Infrastructure Manager + Storage Lead
**Priority:** High
**Subject:** Alerting for downed services + persistent storage evaluation

> "Our health check script logs to a file but nobody actually looks at it. We need it to send a Slack message immediately when a service goes down. Separately, our storage lead wants to evaluate Ceph before we commit to a storage decision, can you deploy a single-node Ceph cluster and demonstrate persistent block storage? We'd also like to see a persistent volume attached to a VM in our OpenStack PoC, since right now if the VM is deleted, the data is gone."

**What this session delivers:**
- A health-check script that sends real Slack alerts when a service is DOWN
- A Cinder volume attached to a freshly launched MicroStack VM (persistent storage in OpenStack)
- A running MicroCeph instance with an RBD block device
- Three more written interview answers

---

## Block 1 — Session Context (15 mins)

### What this session builds toward

In the previous session you wrote a remote health-check script using paramiko. It detects problems correctly but only writes to a log file, silent failures nobody sees. Today you add real Slack alerting using the `requests` library.

This introduces a critical concept: **calling external APIs from Python**. The Slack webhook is just an HTTP POST request with JSON data. The same pattern, `requests.post(url, json=data)` — is how you will call the AWS API, the OpenStack API, the Kubernetes API, and every other cloud service API you will encounter as a Junior CFE. Learning it through Slack is the easiest possible entry point.

**New Python concepts this session:**
- `requests` library for HTTP API calls
- JSON data structures (Python dictionaries sent as JSON)
- Environment variables for secrets (never hardcode API keys in scripts)
- Basic error handling with `try/except`

**What you will provision this session:**
- One fresh EC2 instance (`t3.large`, Ubuntu 22.04) — used for MicroStack + MicroCeph
- Three Docker containers simulating remote servers (same pattern as before, rebuilt fresh)
- Nothing else carries over from any earlier session

**Session 12 GitHub commit message:**
```
Session 12: Slack alerting + OpenStack Cinder volume + MicroCeph RBD
```

---

## Block 2 — Infrastructure Lab (60 mins)

### Part A — Provision the EC2 instance for this session

```bash
aws ec2 run-instances \
  --image-id ami-0fc5d935ebf8bc3bc \
  --instance-type t3.large \
  --key-name canonical_lab_key \
  --security-group-ids <your-sg-id> \
  --subnet-id <your-subnet-id> \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=session-12-retailedge},{Key=Session,Value=12}]' \
  --region eu-west-1

aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=session-12-retailedge" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region eu-west-1
```

> **Optional shortcut:** if you deliberately kept a Session 11 instance running with MicroStack already installed, you may SSH into that instance instead and skip straight to Block 4 Part A, where the existing MicroStack VM (`retailedge-web-01`) can be reused. Everything else in this README assumes a fresh instance.

```bash
ssh -i ~/.ssh/canonical_lab_key ubuntu@<new-instance-ip>
free -h
df -h /
```

### Part B — Set up a Slack webhook for RetailEdge alerts

You need a Slack workspace to send alerts to. If you do not have one, create a free one at slack.com — it takes 3 minutes.

```
1. Go to https://api.slack.com/apps
2. Click "Create New App" → "From scratch"
3. Name it "RetailEdge Monitoring" → select your workspace
4. Under "Add features and functionality" → click "Incoming Webhooks"
5. Toggle "Activate Incoming Webhooks" to ON
6. Click "Add New Webhook to Workspace"
7. Select a channel (create #retailedge-alerts if it doesn't exist)
8. Click "Allow"
9. Copy the Webhook URL — it looks like:
   https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

 Session 11: Python SSH health monitor + MicroStack PoC for RetailEdge

**Test the webhook manually from your EC2 instance:**

```bash
WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

curl -X POST \
  -H 'Content-type: application/json' \
  --data '{"text": "RetailEdge monitoring test — if you see this, the webhook works."}' \
  "$WEBHOOK_URL"

# You should see "ok" returned and a message appear in Slack
```

### Part C — Store the webhook URL as an environment variable

Never hardcode secrets (API keys, passwords, webhook URLs) in scripts. Store them as environment variables instead.

```bash
echo 'export RETAILEDGE_SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"' \
  >> ~/.bashrc

source ~/.bashrc
echo $RETAILEDGE_SLACK_WEBHOOK
```

### Part D — Provision the simulated remote servers

```bash
sudo apt update
sudo apt install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ubuntu
exit
ssh -i ~/.ssh/canonical_lab_key ubuntu@<new-instance-ip>

mkdir -p ~/cfe-labs/session-12/docker
cd ~/cfe-labs/session-12/docker

cat > Dockerfile << 'EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server \
    nginx \
    mysql-server \
    sudo \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash ubuntu && \
    echo 'ubuntu:password123' | chpasswd && \
    usermod -aG sudo ubuntu

RUN mkdir /var/run/sshd
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
RUN sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config

COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]
EOF

cat > start.sh << 'EOF'
#!/bin/bash
service ssh start
service nginx start
service mysql start
tail -f /dev/null
EOF

docker build -t retailedge-server .

docker run -d --name server-01 retailedge-server
docker run -d --name server-02 retailedge-server
docker run -d --name server-03 retailedge-server

# Stop nginx on server-02 to simulate a problem
docker exec server-02 service nginx stop

docker inspect server-01 | grep '"IPAddress"' | tail -1
docker inspect server-02 | grep '"IPAddress"' | tail -1
docker inspect server-03 | grep '"IPAddress"' | tail -1
# Note these IPs down for the Python script
```

**Infrastructure checkpoint:**
- [ ] Fresh t3.large instance provisioned and tagged `Session=12`
- [ ] Slack webhook created and tested (message appeared in Slack)
- [ ] `RETAILEDGE_SLACK_WEBHOOK` environment variable set
- [ ] Three Docker containers running, server-02 nginx down

---

## Block 3 — Python Component (60 mins)

### Objective: Add Slack alerting to the health check script

> **Python level this session: Beginner → calls external HTTP APIs**

**Step 1 — Install requests**

```bash
pip3 install requests
mkdir -p ~/cfe-labs/session-12
cd ~/cfe-labs/session-12
```

**Step 2 — Write the Slack alerting module**

Create `slack_alerts.py`:

```python
#!/usr/bin/env python3
# slack_alerts.py
# RetailEdge Monitoring — Slack notification module
# CFE Training Series Session 12

import requests
import os

def send_alert(message, webhook_url=None):
    """
    Send a message to Slack via webhook.

    Args:
        message (str): The message text to send
        webhook_url (str): Optional. If not provided, reads from
                          RETAILEDGE_SLACK_WEBHOOK environment variable.

    Returns:
        bool: True if message sent successfully, False otherwise
    """
    if webhook_url is None:
        webhook_url = os.environ.get("RETAILEDGE_SLACK_WEBHOOK")

    if not webhook_url:
        print("WARNING: No Slack webhook URL configured. Alert not sent.")
        return False

    payload = {"text": message}

    try:
        response = requests.post(
            url=webhook_url,
            json=payload,
            timeout=10
        )
        if response.status_code == 200:
            return True
        else:
            print(f"Slack returned status {response.status_code}: {response.text}")
            return False

    except requests.exceptions.Timeout:
        print("Slack alert timed out — Slack may be unreachable")
        return False

    except requests.exceptions.ConnectionError:
        print("Could not connect to Slack — check network connectivity")
        return False


def send_server_down_alert(server_name, service_name, host):
    """Send a formatted alert for a downed service."""
    message = (
        f":red_circle: *RetailEdge Alert*\n"
        f"*Server:* {server_name} ({host})\n"
        f"*Service DOWN:* `{service_name}`\n"
        f"*Action required:* SSH to {host} and investigate"
    )
    return send_alert(message)


def send_recovery_alert(server_name, service_name, host):
    """Send a formatted alert for a recovered service."""
    message = (
        f":large_green_circle: *RetailEdge Recovery*\n"
        f"*Server:* {server_name} ({host})\n"
        f"*Service RECOVERED:* `{service_name}`"
    )
    return send_alert(message)
```

**Step 3 — Test the Slack module independently**

```bash
python3 -c "
import slack_alerts
slack_alerts.send_server_down_alert('server-02', 'nginx', '172.17.0.3')
"
# Check your Slack channel — a formatted alert should appear
```

**Step 4 — Create the integrated monitoring script**

Create `monitor.py`:

```python
#!/usr/bin/env python3
# monitor.py
# RetailEdge Ltd — Integrated Health Monitor with Slack Alerting
# CFE Training Series Session 12

import paramiko
import os
from datetime import datetime
from slack_alerts import send_server_down_alert, send_recovery_alert

SERVERS = [
    {"name": "server-01", "host": "172.17.0.2", "user": "ubuntu", "password": "password123"},
    {"name": "server-02", "host": "172.17.0.3", "user": "ubuntu", "password": "password123"},
    {"name": "server-03", "host": "172.17.0.4", "user": "ubuntu", "password": "password123"},
]

SERVICES_TO_CHECK = ["nginx", "mysql"]
STATE_FILE = "/tmp/retailedge-monitor-state.txt"


def load_previous_state():
    """Load the previous check state from a file. Returns a set of strings."""
    if not os.path.exists(STATE_FILE):
        return set()
    with open(STATE_FILE, "r") as f:
        return set(line.strip() for line in f if line.strip())


def save_current_state(state_set):
    """Save the current state to file."""
    with open(STATE_FILE, "w") as f:
        for item in state_set:
            f.write(item + "\n")


def ssh_run_command(host, username, password, command):
    """Run a command on a remote server via SSH."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(hostname=host, username=username,
                      password=password, timeout=5)
        stdin, stdout, stderr = client.exec_command(command)
        return stdout.read().decode().strip()
    except Exception as e:
        return f"ERROR: {str(e)}"
    finally:
        client.close()


def run_monitor():
    """Run a full monitoring cycle with Slack alerting."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"\n[{timestamp}] Running RetailEdge health check...")

    previous_state = load_previous_state()
    current_state = set()

    new_issues = []
    new_recoveries = []

    for server in SERVERS:
        name = server["name"]
        host = server["host"]
        user = server["user"]
        pwd  = server["password"]

        for service in SERVICES_TO_CHECK:
            output = ssh_run_command(host, user, pwd,
                                     f"systemctl is-active {service}")
            is_down = (output != "active")

            state_key = f"{name}:{service}:DOWN"

            if is_down:
                current_state.add(state_key)
                if state_key not in previous_state:
                    print(f"  NEW ISSUE: {name} — {service} is DOWN")
                    new_issues.append((name, service, host))
                else:
                    print(f"  ONGOING: {name} — {service} still DOWN")
            else:
                print(f"  OK: {name} — {service}")
                if state_key in previous_state:
                    print(f"  RECOVERED: {name} — {service} is back UP")
                    new_recoveries.append((name, service, host))

    for (server_name, service_name, host) in new_issues:
        send_server_down_alert(server_name, service_name, host)

    for (server_name, service_name, host) in new_recoveries:
        send_recovery_alert(server_name, service_name, host)

    save_current_state(current_state)

    if not new_issues and not new_recoveries:
        print("  No state changes detected.")

    print(f"[{timestamp}] Check complete.\n")


if __name__ == "__main__":
    run_monitor()
```

**Step 5 — Run the monitor and verify Slack alerts**

```bash
# First run — detects server-02 nginx as DOWN (new issue → sends alert)
python3 monitor.py
# Check Slack — you should see a red circle alert for server-02:nginx

# Second run — server-02 nginx still down (not new → no duplicate alert)
python3 monitor.py

# Simulate recovery
docker exec server-02 service nginx start

# Third run — detects recovery → sends green circle recovery alert
python3 monitor.py
```

**Step 6 — Commit to GitHub**

```bash
git add session-12/
git commit -m "Session 12: Slack alerting with state tracking for RetailEdge monitor"
git push origin main
```

**Python checkpoint — new concepts learned this session:**
- [ ] `import requests` and `requests.post(url, json=payload)` for API calls
- [ ] `os.environ.get("VAR_NAME")` for reading environment variables
- [ ] `try/except` with specific exception types (Timeout, ConnectionError)
- [ ] Splitting code into modules: `slack_alerts.py` imported into `monitor.py`
- [ ] State tracking between script runs using a file

---

## Block 4 — OpenStack Cinder + MicroCeph (45 mins)

### Part A — Install MicroStack and launch a VM (fresh by default)

> If you used the optional shortcut in Block 2 and already have a Session 11 MicroStack VM, skip to Part B and use that existing VM. Otherwise, install fresh here:

```bash
sudo snap install microstack --beta --devmode
sudo microstack init --auto --control
sudo snap logs microstack -f
# Ctrl+C once you see "microstack is initialised"

wget https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img

sudo microstack.openstack image create \
  --file ubuntu-22.04-minimal-cloudimg-amd64.img \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  "Ubuntu 22.04 Minimal"

sudo microstack.openstack keypair create \
  --public-key ~/.ssh/canonical_lab_key.pub \
  retailedge-key

sudo microstack.openstack server create \
  --flavor m1.tiny \
  --image "Ubuntu 22.04 Minimal" \
  --key-name retailedge-key \
  retailedge-web-01

sudo microstack.openstack server list
# Wait for ACTIVE status

sudo microstack.openstack floating ip create external
sudo microstack.openstack server add floating ip retailedge-web-01 <floating-ip>
```

### Part B — Attach a persistent Cinder volume

```bash
# Create a 5GB Cinder volume
sudo microstack.openstack volume create \
  --size 5 \
  retailedge-data-vol

sudo microstack.openstack volume list
# Status should show "available"

# Attach the volume to the running VM
sudo microstack.openstack server add volume \
  retailedge-web-01 \
  retailedge-data-vol

sudo microstack.openstack volume list
# Status should now show "in-use"

# SSH into the MicroStack VM
ssh -i ~/.ssh/canonical_lab_key ubuntu@<floating-ip>

lsblk
# You should see a new disk (likely /dev/vdb) — this is the Cinder volume

sudo mkfs.ext4 /dev/vdb
sudo mkdir /data
sudo mount /dev/vdb /data

echo "RetailEdge persistent data — Session 12" | sudo tee /data/test.txt
cat /data/test.txt

exit
```

**What you just demonstrated:** A Cinder volume is the OpenStack equivalent of an EBS volume. The data on it persists even if the VM is deleted and recreated.

### Part C — Install MicroCeph

```bash
sudo snap install microceph

sudo microceph cluster bootstrap

sudo microceph status
# Shows: cluster is up but no OSDs yet

# Add a simulated disk using a loop device
sudo dd if=/dev/zero of=/tmp/ceph-osd-1.img bs=1M count=10240
sudo losetup /dev/loop10 /tmp/ceph-osd-1.img

sudo microceph disk add /dev/loop10 --wipe

sudo microceph status
# Should now show 1 OSD active

sudo microceph.ceph health
sudo microceph.ceph osd tree
```

**Create an RBD (block device) pool and volume:**

```bash
sudo microceph.ceph osd pool create retailedge-rbd 32
sudo microceph.rbd pool init retailedge-rbd

sudo microceph.rbd create \
  --size 2048 \
  retailedge-rbd/web-disk-01

sudo microceph.rbd ls retailedge-rbd

sudo microceph.rbd map retailedge-rbd/web-disk-01

sudo rbd showmapped
# Will show something like: /dev/rbd0

sudo mkfs.ext4 /dev/rbd0
sudo mkdir /mnt/ceph-test
sudo mount /dev/rbd0 /mnt/ceph-test

echo "RetailEdge Ceph storage test — Session 12" | sudo tee /mnt/ceph-test/test.txt
df -h /mnt/ceph-test
cat /mnt/ceph-test/test.txt
```

**Document your observations:**

```bash
cat > ~/cfe-labs/session-12/ceph-notes.md << 'EOF'
# MicroCeph Observations — Session 12

## What I deployed
- Single-node Ceph cluster using MicroCeph snap
- 1 OSD backed by a loop device (10GB file)
- RBD pool: retailedge-rbd
- RBD image: web-disk-01 (2GB)
- Mapped as /dev/rbd0 and mounted at /mnt/ceph-test

## How RBD relates to what I already know
- An RBD image is Ceph's equivalent of an EBS volume or a Cinder volume
- It presents as a regular block device (/dev/rbd0) to the OS
- The data is stored as objects inside the Ceph RADOS cluster
- In production, Cinder uses RBD as its backend — so the Cinder volume
  I created earlier in this session is actually backed by Ceph in a real deployment

## What a production Ceph cluster would look like differently
- Multiple nodes (minimum 3) for true redundancy
- Real NVMe or SSD disks, not loop devices
- Replication factor of 3 (3 copies of every object)
- Separate public and cluster networks

## Questions I still have
(write your genuine questions here)
EOF
```

**OpenStack + Ceph checkpoint:**
- [ ] Cinder volume created, attached, formatted, and mounted in MicroStack VM
- [ ] Data written to Cinder volume and verified
- [ ] MicroCeph installed and running
- [ ] 1 OSD added via loop device
- [ ] RBD image created, mapped, formatted, and mounted
- [ ] `ceph-notes.md` written with own observations

---

## Block 5 — Written Interview Capture (20 mins)

Open `~/cfe-labs/canonical-written-interview-draft.md` and add:

**Question 7 — "Describe your approach to writing maintainable code."**

Use today's work as your example: splitting the Slack module into a separate file so it can be reused independently, using environment variables instead of hardcoded secrets, and the state tracking pattern that prevents duplicate alerts.

**Question 8 — "What is your experience with storage systems?"**

Add today's Ceph work:
```
- Deployed a single-node Ceph cluster using MicroCeph, added an OSD via a loop
  device, created an RBD pool and image, and mounted it as a block device.
  Also attached a Cinder persistent volume to an OpenStack VM and observed
  that Cinder uses Ceph RBD as its backend in production deployments —
  confirming the integration between the two systems I had previously only
  understood conceptually.
```

**Question 9 — "How do you handle errors and unexpected failures in your work?"**

Use the `try/except` pattern from today's Slack module as your technical example — specifically catching `Timeout` and `ConnectionError` separately because they require different responses.

---

## Session 12 Completion Checklist

**Infrastructure (Block 2)**
- [ ] Fresh t3.large instance provisioned and tagged `Session=12` (or shortcut used deliberately)
- [ ] Slack webhook working — test message delivered
- [ ] `RETAILEDGE_SLACK_WEBHOOK` env variable set
- [ ] Docker servers running, server-02 nginx issue simulated

**Python (Block 3)**
- [ ] `slack_alerts.py` module sends real Slack messages
- [ ] `monitor.py` sends alert on first detection, no duplicate on second run
- [ ] Recovery alert sent when nginx restored on server-02
- [ ] Both files committed to GitHub

**OpenStack + Ceph (Block 4)**
- [ ] Cinder volume attached and data written inside MicroStack VM
- [ ] MicroCeph running with 1 OSD
- [ ] RBD image mapped, formatted, and data written

**Written Interview (Block 5)**
- [ ] Three new questions answered with specific evidence from today

---

## End of Session — Decommission

```bash
# From your local machine
aws ec2 terminate-instances \
  --instance-ids <session-12-instance-id> \
  --region eu-west-1
```

---

## LinkedIn Post Prompt

Today's angle: *"Most monitoring scripts I see do one thing wrong — they alert every single time they run. If a server is down for 6 hours and the script runs every 5 minutes, you get 72 identical alerts. The fix is state tracking: the script remembers what was already known, and only fires when something changes. That's the difference between a noise machine and a useful alert system. I built it in Python today. Here's the pattern."*

---

## What's Coming in Session 13

- **Python:** Replace the hardcoded server list with dynamic AWS EC2 discovery using `boto3` — your script will automatically find all EC2 instances tagged `Environment=RetailEdge` instead of needing a manual list
- **OpenStack:** Create an internal network and connect two VMs — first Neutron networking hands-on
- **Ceph:** Add a second OSD and observe replication behaviour
- **Written interview:** Add answers on distributed systems and your Canonical-specific motivation

Session 13 provisions its own infrastructure independently.

---

*CFE Training Series Session 12 | Junior Cloud Field Engineer Readiness | RetailEdge Ltd | Python + OpenStack + Ceph + Written Interview Track | Standalone Session*
