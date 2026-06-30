# CFE Training Series — Session 11
## Python SSH Automation + MicroStack Hands-On + Written Interview Prep
### Junior Cloud Field Engineer Readiness | RetailEdge Ltd

---

> **Standalone session.** This session provisions everything it needs from scratch. It does not require anything left running from Session 10 or earlier. If you still have a Session 10 instance running, you may terminate it - it is not used here.
>
> **Time split suggestion:**
> **Day 1:** Blocks 1, 2, and 3 — Infrastructure + Python SSH script (~2 hours)
> **Day 2:** Blocks 4 and 5 — MicroStack install + Written interview capture (~1 hour)

---

## The Client Ticket

**Client:** RetailEdge Ltd
**Submitted by:** Infrastructure Manager
**Priority:** High
**Subject:** Multi-server health monitoring + Private cloud PoC request

> "We need a script that can check the health of several application servers remotely from one place, rather than logging into each one manually. Separately, our CTO has approved a proof-of-concept for private cloud. Can you set up a single-node OpenStack environment so the team can see what it looks like before we commit to a full deployment?"

**What this session delivers:**
- A Python script that checks services on remote servers over SSH
- A running MicroStack instance with a VM launched inside it
- Three more written interview answers in your draft document

---

## Block 1 — Session Context (15 mins)

### What this session builds toward

Today you write a health-check script that checks remote servers over SSH - which is what a real monitoring tool does. This introduces `paramiko`, Python's SSH library.

You also provision a single `t3.large` EC2 instance for the MicroStack lab. This instance is used for this session only and is decommissioned at the end.

**New Python concept this session: external libraries and SSH**
Until now you have only used Python's standard library (modules that come built in). Today you install your first external library - `paramiko` - using `pip`. This is how most real Python development works: standard library for basic tasks, specialised libraries for specific needs.

**Session 11 GitHub commit message:**
```
Session 11: Python SSH health monitor + MicroStack PoC for RetailEdge
```

---

## Block 2 — Infrastructure Lab (60 mins)

### Part A — Provision a fresh EC2 instance sized for MicroStack

MicroStack requires at least 8GB RAM and 50GB disk. This session provisions a `t3.large` (8 vCPU, 8GB RAM) directly - there is no resize step, no dependency on a prior session's instance.

```bash
# Launch a fresh Ubuntu 22.04 t3.large instance
aws ec2 run-instances \
  --image-id ami-0fc5d935ebf8bc3bc \
  --instance-type t3.large \
  --key-name canonical_lab_key \
  --security-group-ids <your-sg-id> \
  --subnet-id <your-subnet-id> \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=session-11-retailedge},{Key=Session,Value=11}]' \
  --region eu-west-1

# Get the public IP once running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=session-11-retailedge" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region eu-west-1
```

> **Cost note:** t3.large costs ~$0.083/hour. You will use it for 2-3 hours this session then terminate it. Total cost: under $0.30.

```bash
# SSH into the new instance
ssh -i ~/.ssh/canonical_lab_key ubuntu@<new-instance-ip>

# Verify RAM and disk
free -h
df -h /
```

### Part B — Set up simulated remote servers using Docker

Rather than provisioning three real EC2 instances (cost), you simulate three remote servers using Docker containers on this single instance. This is a legitimate and widely-used technique for testing automation.

```bash
# Install Docker
sudo apt update
sudo apt install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ubuntu
exit
# SSH back in for the group change to take effect
ssh -i ~/.ssh/canonical_lab_key ubuntu@<new-instance-ip>

docker --version
docker ps

mkdir -p ~/cfe-labs/session-11/docker
cd ~/cfe-labs/session-11/docker

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
# Note these IPs down - you will use them in the Python script
```

**Test SSH manually first:**
```bash
ssh ubuntu@<server-01-ip>
# Password: password123
service nginx status
exit
```

**Infrastructure checkpoint:**
- [ ] Fresh t3.large instance provisioned and tagged `Session=11`
- [ ] Three Docker containers running
- [ ] server-02 has nginx stopped (intentional fault)
- [ ] You can SSH manually into each container
- [ ] You have noted down all three container IPs

---

## Block 3 — Python Component (60 mins)

### Objective: Write a script that checks remote servers over SSH

> **Python level this session: Beginner → uses first external library (paramiko)**

**Step 1 — Install paramiko**

```bash
cd ~/cfe-labs/session-11
pip3 install paramiko
```

`pip3` is Python's package manager - it downloads and installs libraries from the internet. `paramiko` implements SSH, letting your script connect to remote servers and run commands exactly like you do manually.

**Step 2 — Write the remote health check script**

Create `remote_health_check.py`:

```python
#!/usr/bin/env python3
# remote_health_check.py
# RetailEdge Ltd — Remote Multi-Server Health Check
# CFE Training Series Session 11

import paramiko
import shutil
from datetime import datetime

SERVERS = [
    {"name": "server-01", "host": "172.17.0.2", "user": "ubuntu", "password": "password123"},
    {"name": "server-02", "host": "172.17.0.3", "user": "ubuntu", "password": "password123"},
    {"name": "server-03", "host": "172.17.0.4", "user": "ubuntu", "password": "password123"},
]

SERVICES_TO_CHECK = ["nginx", "mysql"]


def ssh_run_command(host, username, password, command):
    """
    Connect to a remote server via SSH and run a single command.
    Returns the output as a string, or an error message if connection fails.
    """
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(
            hostname=host,
            username=username,
            password=password,
            timeout=5
        )
        stdin, stdout, stderr = client.exec_command(command)
        output = stdout.read().decode().strip()
        return output

    except Exception as e:
        return f"CONNECTION_ERROR: {str(e)}"

    finally:
        client.close()


def check_remote_service(host, username, password, service_name):
    """Check if a service is active on a remote server."""
    output = ssh_run_command(
        host, username, password,
        f"systemctl is-active {service_name}"
    )
    return output == "active"


def check_remote_disk(host, username, password, path="/"):
    """Check disk usage on a remote server. Returns used percentage."""
    output = ssh_run_command(
        host, username, password,
        f"df --output=pcent {path} | tail -1"
    )
    if "CONNECTION_ERROR" in output:
        return None
    try:
        return float(output.strip().replace("%", ""))
    except ValueError:
        return None


def check_server(server):
    """Run all checks on one server. Returns a dict of results."""
    results = {
        "name": server["name"],
        "host": server["host"],
        "services": {},
        "disk_percent": None,
    }

    for service in SERVICES_TO_CHECK:
        is_active = check_remote_service(
            server["host"], server["user"], server["password"], service
        )
        results["services"][service] = is_active

    results["disk_percent"] = check_remote_disk(
        server["host"], server["user"], server["password"]
    )

    return results


def generate_report(all_results):
    """Format the results into a readable report."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = []

    lines.append(f"RetailEdge Multi-Server Health Report — {timestamp}")
    lines.append("=" * 55)

    issues_found = []

    for result in all_results:
        lines.append(f"\n[{result['name']} — {result['host']}]")

        for service, is_active in result["services"].items():
            if is_active:
                lines.append(f"  {service}: OK")
            else:
                lines.append(f"  {service}: DOWN <-- investigate")
                issues_found.append(f"{result['name']}: {service} is DOWN")

        if result["disk_percent"] is not None:
            if result["disk_percent"] < 80:
                lines.append(f"  disk (/): {result['disk_percent']}% — OK")
            else:
                lines.append(f"  disk (/): {result['disk_percent']}% — WARNING")
                issues_found.append(f"{result['name']}: disk at {result['disk_percent']}%")
        else:
            lines.append("  disk: could not retrieve")

    lines.append("\n" + "=" * 55)
    lines.append("[Summary]")
    if not issues_found:
        lines.append("  ALL SERVERS HEALTHY")
    else:
        lines.append(f"  {len(issues_found)} issue(s) detected:")
        for issue in issues_found:
            lines.append(f"    - {issue}")

    return "\n".join(lines)


if __name__ == "__main__":
    print("Running RetailEdge health checks...\n")

    # List comprehension: "for each server in SERVERS, call check_server(server)"
    all_results = [check_server(server) for server in SERVERS]

    report = generate_report(all_results)
    print(report)

    log_path = "/tmp/retailedge-remote-health.log"
    with open(log_path, "a") as f:
        f.write(report + "\n\n")
    print(f"\nReport saved to {log_path}")
```

**Step 3 — Update the server IPs and run**

```bash
docker inspect server-01 | grep '"IPAddress"' | tail -1
docker inspect server-02 | grep '"IPAddress"' | tail -1
docker inspect server-03 | grep '"IPAddress"' | tail -1

nano remote_health_check.py
# Update the SERVERS list with the real IPs you noted in Block 2

python3 remote_health_check.py
```

Expected output:
```
Running RetailEdge health checks...

RetailEdge Multi-Server Health Report — 2025-06-12 14:30:00
=======================================================

[server-01 — 172.17.0.2]
  nginx: OK
  mysql: OK
  disk (/): 12.4% — OK

[server-02 — 172.17.0.3]
  nginx: DOWN <-- investigate
  mysql: OK
  disk (/): 12.4% — OK

[server-03 — 172.17.0.4]
  nginx: OK
  mysql: OK
  disk (/): 12.4% — OK

=======================================================
[Summary]
  1 issue(s) detected:
    - server-02: nginx is DOWN
```

**Step 4 — Commit to GitHub**

```bash
git add session-11/
git commit -m "Session 11: Remote SSH health monitor with paramiko"
git push origin main
```

**Python checkpoint — new concepts learned this session:**
- [ ] `pip3 install` - installing external libraries
- [ ] `paramiko.SSHClient()` - creating an SSH client object
- [ ] `client.exec_command()` - running a command on a remote server
- [ ] `try / except / finally` - handling errors gracefully
- [ ] List comprehension: `[check_server(s) for s in SERVERS]`
- [ ] Dictionaries: `results = {"name": ..., "services": {}, ...}`

---

## Block 4 — OpenStack Hands-On: MicroStack Install (45 mins)

### Objective: Install MicroStack and launch your first VM inside OpenStack

> **This is your first real OpenStack hands-on.** Before any commands, here is what you're actually working with.

**What is OpenStack, in one sentence?**
OpenStack is a collection of separate services that, together, let you do what AWS does — create VMs, give them networking, attach storage — except running on infrastructure you control instead of Amazon's. Each "service" below has one specific job, the same way EC2, VPC, and IAM are each separate AWS services that work together.

**What is MicroStack?**
A normal OpenStack deployment spreads these services across many physical or virtual machines. MicroStack is Canonical's version that squeezes the entire thing onto a **single machine** — built specifically so you can learn and test real OpenStack without needing a whole data centre. This runs on the same t3.large instance you provisioned in Block 2.

**The OpenStack services you will meet in this block, explained before you use them:**

| Service | What it actually does | The AWS equivalent you already know |
|---|---|---|
| **Nova** | Creates and manages VMs — the actual "computer" that runs | EC2 |
| **Glance** | Stores operating system images, so Nova has something to install onto a new VM | AMI (Amazon Machine Image) |
| **Neutron** | Handles networking — IP addresses, routing, floating IPs | VPC + Elastic IP |
| **Keystone** | Handles login and permissions — confirms who you are before letting you do anything | IAM |
| **Horizon** | A web dashboard for clicking through all of the above instead of using the command line | AWS Console |

You will use Nova, Glance, and Neutron directly in the steps below. Keystone works silently in the background every time you run an `openstack` command — it's what checks you're allowed to do that action.

**Two more terms you'll see in the commands:**
- **Flavor** — OpenStack's name for an instance size (CPU/RAM combination). `m1.tiny` is the smallest available flavor — directly equivalent to AWS's `t3.micro`.
- **Floating IP** — a public IP address that can be attached to a VM so it's reachable from outside OpenStack. Equivalent to an AWS Elastic IP.

**Step 1 — Install MicroStack**

```bash
sudo snap install microstack --beta --devmode

sudo microstack init --auto --control

sudo snap logs microstack -f
# Press Ctrl+C when you see "microstack is initialised"
```

**Step 2 — Enable IP forwarding on the host (required for VM internet access)**

> **Why this step exists:** by default, this host's Linux kernel is configured to never forward network packets between interfaces — a setting called `ip_forward`. OpenStack's router, subnets, and security groups can all be configured perfectly, but without this kernel-level setting enabled, any VM you launch later will have working SSH access (inbound) but **no outbound internet access at all** — `apt update`, DNS lookups, and any external connection will hang or time out. This is easy to miss because every OpenStack-level check (router config, security group rules, subnet config) will look completely correct. Doing this now, before launching any VM, avoids a confusing debugging session later.

```bash
# Enable it immediately for the current session
sudo sysctl -w net.ipv4.ip_forward=1

# Make it persist across reboots
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Verify it took effect
sysctl net.ipv4.ip_forward
# Should show: net.ipv4.ip_forward = 1
```

**Step 3 — Verify all OpenStack services are running**

This command asks Keystone (the identity service) to list every service it knows about and confirm they're all registered and reachable — a quick sanity check before you try to use any of them.

```bash
sudo microstack.openstack service list
```

**Step 4 — Upload an image to Glance**

Before Nova can create a VM, it needs an actual operating system to install onto it — Glance is where that operating system file lives. This step downloads a real Ubuntu 22.04 disk image directly from Canonical, then uploads it into Glance so OpenStack has something to install when you launch a VM in Step 5.

```bash
wget https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img

sudo microstack.openstack image create \
  --file ubuntu-22.04-minimal-cloudimg-amd64.img \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  "Ubuntu 22.04 Minimal"
```

- `--disk-format qcow2` — tells Glance what file format the image is in (qcow2 is a common virtual disk format)
- `--container-format bare` — tells Glance this is just a plain disk image, with no extra packaging around it
- `--public` — makes the image available to any project in this OpenStack environment, not just you

```bash
sudo microstack.openstack image list
```
This just confirms the image is now stored in Glance and ready to use — the same idea as checking `aws ec2 describe-images` to confirm an AMI exists before launching from it.

**Step 5 — Launch your first VM inside OpenStack**

First, OpenStack needs a copy of your public SSH key so the new VM will trust it — same purpose as the EC2 key pair you already use, just registered inside OpenStack's own system this time:

```bash
sudo microstack.openstack keypair create \
  --public-key ~/.ssh/canonical_lab_key.pub \
  retailedge-key
```

Now create the actual VM. This is the OpenStack equivalent of `aws ec2 run-instances` — you're telling Nova what size (`flavor`), what operating system (`image`, from Glance), and which SSH key to trust:

```bash
sudo microstack.openstack server create \
  --flavor m1.tiny \
  --image "Ubuntu 22.04 Minimal" \
  --key-name retailedge-key \
  retailedge-web-01

sudo microstack.openstack server list
# Status goes BUILD → ACTIVE. Wait until ACTIVE.
```

**Step 6 — Assign a floating IP and connect**

Right now your VM exists, but only with an internal IP address that's only reachable from inside OpenStack's own network — not from your laptop or the internet. A floating IP is a public-facing address you attach on top, the same role an AWS Elastic IP plays for an EC2 instance.

```bash
sudo microstack.openstack floating ip create external
```
This asks Neutron (the networking service) to allocate a new floating IP from the "external" pool. Note the IP address it gives you back.

```bash
sudo microstack.openstack server add floating ip \
  retailedge-web-01 \
  <floating-ip>
```
This attaches that floating IP to your VM, making it reachable from outside.

```bash
sudo microstack.openstack server show retailedge-web-01
```
This shows full details of the VM, including confirming the floating IP is now attached.

```bash
ssh -i ~/.ssh/canonical_lab_key ubuntu@<floating-ip>

# Once inside the OpenStack VM:
hostname
uname -a
exit
```
You're now SSHing into a virtual machine that exists entirely inside MicroStack — not your EC2 instance itself, but a VM running inside it.

**Step 7 — Document what you observed**

```bash
cat > ~/cfe-labs/session-11/microstack-notes.md << 'EOF'
# MicroStack PoC — Session 11 Observations

## What I did
- Installed MicroStack on a t3.large EC2 instance
- Uploaded an Ubuntu 22.04 image to Glance
- Launched a VM (retailedge-web-01) using Nova
- Assigned a floating IP and SSHed into the VM

## What I noticed
- The VM has its own hostname and IP - it is genuinely isolated
- Nova, Glance, and Neutron worked together automatically
- The whole process felt like using AWS EC2 but on my own server

## OpenStack services I interacted with
- Nova: created and managed the VM
- Glance: stored and served the VM image
- Neutron: provided the floating IP and networking
- Keystone: handled authentication (the openstack CLI logged me in)

## How this maps to RetailEdge's use case
(write your own thoughts here)

## Questions for next time
(write what you still don't understand)
EOF
```

**OpenStack checkpoint:**
- [ ] MicroStack installed and all services running
- [ ] Ubuntu 22.04 image uploaded to Glance
- [ ] VM launched and reached ACTIVE state
- [ ] VM accessible via SSH through floating IP
- [ ] `microstack-notes.md` written with your own observations

---

## Block 5 — Written Interview Capture (20 mins)

Open `~/cfe-labs/canonical-written-interview-draft.md` and add these entries:

**Question 4 — "Describe a time you had to learn something new quickly to solve a problem."**

Write about installing and using paramiko today. Specifically: what you did not know before (SSH from Python), how you approached learning it, and what the result was.

**Question 5 — "What is your experience with cloud infrastructure and private cloud?"**

Add a bullet point about today's MicroStack experience:
```
- Deployed a single-node OpenStack environment using Canonical's MicroStack snap,
  uploaded a VM image to Glance, launched a VM via Nova, and accessed it via
  a floating IP assigned through Neutron. First hands-on experience confirming
  that OpenStack's API model is functionally equivalent to AWS EC2 — same
  concepts, different substrate.
```

**Question 6 — "How do you approach automation?"**

Use today's progression - from a single-server Python check to a multi-server SSH-based check - as a concrete example of how you think about automation incrementally.

---

## Session 11 Completion Checklist

**Infrastructure (Block 2)**
- [ ] Fresh t3.large instance provisioned and tagged `Session=11`
- [ ] Three Docker containers running and SSHable

**Python (Block 3)**
- [ ] `remote_health_check.py` correctly identifies server-02 nginx as DOWN
- [ ] Script runs without errors against all three containers
- [ ] Committed and pushed to GitHub

**OpenStack (Block 4)**
- [ ] MicroStack installed and services running
- [ ] VM launched and accessible via SSH
- [ ] `microstack-notes.md` written

**Written Interview (Block 5)**
- [ ] Three new questions answered
- [ ] Answers reference specific work done today

---

## End of Session — Decommission

```bash
# From your local machine
aws ec2 terminate-instances \
  --instance-ids <session-11-instance-id> \
  --region eu-west-1
```

If you want to continue directly into Session 12 (which also uses MicroStack and adds MicroCeph), you may leave this instance running instead of terminating it — Session 12 will note this option explicitly. Otherwise, terminate to avoid ongoing charges.

---

## LinkedIn Post Prompt

Today's angle: *"I SSHed into a VM running inside OpenStack, running inside an EC2 instance, on AWS. Three layers of compute. What struck me: the OpenStack VM had no idea it was running on AWS. That is exactly the point — OpenStack is not a worse AWS. It is the same abstraction, on hardware you control. Here is how I'm working through that question for my fictional client RetailEdge."*

---

## What's Coming in Session 12

- **Python:** Add Slack alerting — when a server is DOWN, the script sends a real Slack notification. Introduces `requests` and working with APIs from Python.
- **OpenStack:** Create a Cinder volume and attach it to a VM. First hands-on with persistent storage in OpenStack.
- **Ceph:** MicroCeph install — your first real Ceph cluster (single-node). Create an RBD pool and map it as a block device.
- **Written interview:** Add answers on technical problem-solving and open source philosophy.

Session 12 provisions its own instance independently by default, with an optional path to reuse this session's instance if you chose to leave it running.

---

*CFE Training Series Session 11 | Junior Cloud Field Engineer Readiness | RetailEdge Ltd | Python + OpenStack + Written Interview Track | Standalone Session*
