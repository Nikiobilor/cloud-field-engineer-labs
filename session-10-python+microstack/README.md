# CFE Training Series — Session 10
## Python Foundations + MicroStack Introduction + Written Interview Prep
### Junior Cloud Field Engineer Readiness | RetailEdge Ltd

---

> **Standalone session.** This session provisions only what it needs. It does not assume any running infrastructure from Sessions 1-9. If you have an existing EC2 instance from earlier sessions, you do not need it for this session ,feel free to leave it stopped or terminated. Everything below is self-contained.
>

## The Client Ticket

**Client:** RetailEdge Ltd
**Submitted by:** Infrastructure Manager
**Priority:** Medium
**Subject:** Server health visibility and Python automation baseline

> "We have a small Ubuntu server running our website. Our team is spending too much time manually SSHing in to check whether nginx is up and how much disk space is left. We need a lightweight script we can run that checks the server's health and reports it in one place. Separately, our CTO has asked us to evaluate whether a private cloud makes sense for our workload ,can you give us a first look at what that would involve?"

**What this session delivers:**
,A working Python health-check script running on a single EC2 instance
,Your first hands-on contact with OpenStack concepts via MicroStack
---

## Block 1 — Session Context (15 mins)

### Why this matters for the Junior CFE role

The Junior CFE role requires intermediate-to-advanced Python for developing Kubernetes operators and Linux infrastructure-as-code. You are starting from beginner level. The fastest path to intermediate is not working through Python tutorials ,it is writing real scripts that solve real infrastructure problems you already understand.

Today's script is small and completely achievable. It checks whether nginx is running and reports disk usage. By Session 16, that same pattern will extend into AWS API calls and a simple Kubernetes operator. You build it incrementally ,one session at a time.

**What you will provision this session:**
,One EC2 instance (Ubuntu 22.04, `t3.micro`) ,used only for this session
,Nothing else. No Docker containers, no extra services beyond what is listed below.

**What you will have by the end of this session:**
,A Python script saved at `~/cfe-labs/session-10/health_check.py`
,Your first MicroStack install attempt documented

**Session 10 GitHub commit message (use this exactly):**
```
Session 10: Python health check script + MicroStack intro
```

---

## Block 2 — Infrastructure Lab (60 mins)

### Objective: Provision a single server and build the monitoring baseline RetailEdge needs

### Part A — Provision the EC2 instance for this session

```bash
# Launch a fresh Ubuntu 22.04 EC2 instance (adjust AMI ID for your region)
aws ec2 run-instances \
  --image-id ami-0fc5d935ebf8bc3bc \
  --instance-type t3.micro \
  --key-name canonical_lab_key \
  --security-group-ids <your-sg-id> \
  --subnet-id <your-subnet-id> \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=session-10-retailedge},{Key=Session,Value=10}]' \
  --region eu-west-1

# Note the InstanceId from the output, then get its public IP once running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=session-10-retailedge" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region eu-west-1
```

```bash
# SSH into the new instance
ssh -i ~/.ssh/canonical_lab_key ubuntu@<new-instance-ip>

# Update and install nginx
sudo apt update
sudo apt install -y nginx
sudo systemctl start nginx
sudo systemctl enable nginx

# Confirm it is running
sudo systemctl status nginx | grep "Active:"
curl -s http://localhost | head -5
```

### Part B — Create a working directory for this session

```bash
mkdir -p ~/cfe-labs/session-10
cd ~/cfe-labs/session-10
```

### Part C — Generate realistic log activity for the script to read

```bash
# Generate some nginx access log entries
for i in {1..20}; do
  curl -s http://localhost > /dev/null
done

# Generate a 404 error
curl -s http://localhost/nonexistent > /dev/null

# Verify logs have entries
sudo tail -5 /var/log/nginx/access.log
sudo tail -5 /var/log/nginx/error.log
```

### Part D — Simulate a service outage so the script has something to detect

```bash
# Stop nginx temporarily to confirm the script correctly reports a DOWN state
sudo systemctl stop nginx

# You'll restart it in Block 3 once the script is ready to test both states
```

### Part E — Create a small amount of disk usage to monitor

```bash
# Create a 100MB test file
dd if=/dev/zero of=~/testfile.tmp bs=1M count=100
df -h /
# Note the used percentage ,your Python script will read this
```

**Checkpoint — before moving to Python, confirm:**
,[ ] EC2 instance provisioned and tagged `Session=10`
,[ ] nginx installed (currently stopped, intentionally, to test the DOWN case)
,[ ] nginx access log has entries
,[ ] `df -h /` shows some disk usage

---

## Block 3 — Python Component (60 mins)

### Objective: Write your first real infrastructure Python script

> **Python level this session: Absolute beginner → writes first real script**
> No prior Python scripting experience assumed. Every line is explained.
> You will write this script yourself ,do not copy-paste blindly. Type it out.

**Step 1 — Verify Python is available**

```bash
python3 --version
# Should show Python 3.10.x or higher on Ubuntu 22.04

cd ~/cfe-labs/session-10
touch health_check.py
```

**Step 2 — Build the script in four stages**

---

**Stage A — The simplest possible start: print something**

```python
#!/usr/bin/env python3
# health_check.py
# RetailEdge Ltd — Server Health Check Script
# CFE Training Series Session 10

print("RetailEdge Health Check")
print("=" * 40)
```

Run it:
```bash
python3 health_check.py
```

Expected output:
```
RetailEdge Health Check
========================================
```

What you just learned: `#!/usr/bin/env python3` tells the OS to run this file with Python 3. `print()` outputs to the terminal. `"=" * 40` repeats the `=` character 40 times ,multiplying a string in Python repeats it.

---

**Stage B — Add a function and check a service**

```python
#!/usr/bin/env python3
# health_check.py
# RetailEdge Ltd — Server Health Check Script

import subprocess  # lets Python run shell commands

def check_service(service_name):
    """Check if a systemd service is active. Returns True or False."""
    result = subprocess.run(
        ["systemctl", "is-active", service_name],
        capture_output=True,   # capture the output instead of printing it
        text=True              # return output as text, not bytes
    )
    return result.stdout.strip() == "active"

# --,Main script ---
print("RetailEdge Health Check")
print("=" * 40)

services = ["nginx"]

for service in services:
    status = check_service(service)
    if status:
        print(f"  {service}: OK")
    else:
        print(f"  {service}: DOWN <-,investigate")
```

Run it (nginx is currently stopped from Block 2 Part D):
```bash
python3 health_check.py
```

Expected output:
```
RetailEdge Health Check
========================================
  nginx: DOWN <-,investigate
```

Now restart nginx and run again:
```bash
sudo systemctl start nginx
python3 health_check.py
```

Expected output:
```
RetailEdge Health Check
========================================
  nginx: OK
```

What you just learned:
,`import subprocess` ,Python uses modules (libraries) for extra functionality
,`def check_service(service_name):` ,defines a function that takes one input
,`subprocess.run([...], capture_output=True, text=True)` ,runs a command and captures its output
,`for service in services:` ,a loop that processes each item in a list
,`f"  {service}: OK"` ,an f-string inserts a variable's value directly into text

---

**Stage C — Add disk space checking**

```python
#!/usr/bin/env python3
# health_check.py
# RetailEdge Ltd — Server Health Check Script

import subprocess
import shutil  # shutil has a disk_usage() function built in

def check_service(service_name):
    """Check if a systemd service is active. Returns True or False."""
    result = subprocess.run(
        ["systemctl", "is-active", service_name],
        capture_output=True,
        text=True
    )
    return result.stdout.strip() == "active"

def check_disk(path="/", warning_percent=80):
    """Check disk usage at a given path. Returns (used_percent, is_ok)."""
    usage = shutil.disk_usage(path)
    used_percent = (usage.used / usage.total) * 100
    is_ok = used_percent < warning_percent
    return round(used_percent, 1), is_ok

# --,Main script ---
print("RetailEdge Health Check")
print("=" * 40)

print("\n[Services]")
services = ["nginx"]

for service in services:
    status = check_service(service)
    if status:
        print(f"  {service}: OK")
    else:
        print(f"  {service}: DOWN <-,investigate")

print("\n[Disk Usage]")
used_percent, is_ok = check_disk("/")
if is_ok:
    print(f"  /: {used_percent}% used — OK")
else:
    print(f"  /: {used_percent}% used — WARNING: above 80%")
```

Run it:
```bash
python3 health_check.py
```

Expected output:
```
RetailEdge Health Check
========================================

[Services]
  nginx: OK

[Disk Usage]
  /: 12.3% used — OK
```

What you just learned:
,`import shutil` ,another standard library module, no install needed
,`shutil.disk_usage(path)` ,returns an object with `.used`, `.free`, and `.total` attributes
,`round(used_percent, 1)` ,rounds to 1 decimal place
,Returning two values at once: `return round(used_percent, 1), is_ok`

---

**Stage D — Add a timestamp and save output to a log file**

```python
#!/usr/bin/env python3
# health_check.py
# RetailEdge Ltd — Server Health Check Script
# Session 10 — Final version

import subprocess
import shutil
from datetime import datetime  # for timestamps

def check_service(service_name):
    """Check if a systemd service is active. Returns True or False."""
    result = subprocess.run(
        ["systemctl", "is-active", service_name],
        capture_output=True,
        text=True
    )
    return result.stdout.strip() == "active"

def check_disk(path="/", warning_percent=80):
    """Check disk usage at a given path. Returns (used_percent, is_ok)."""
    usage = shutil.disk_usage(path)
    used_percent = (usage.used / usage.total) * 100
    is_ok = used_percent < warning_percent
    return round(used_percent, 1), is_ok

def run_health_check():
    """Run the full health check and return a report as a string."""
    lines = []
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines.append(f"RetailEdge Health Check — {timestamp}")
    lines.append("=" * 50)

    lines.append("\n[Services]")
    services = ["nginx"]
    all_ok = True

    for service in services:
        status = check_service(service)
        if status:
            lines.append(f"  {service}: OK")
        else:
            lines.append(f"  {service}: DOWN <-,investigate")
            all_ok = False

    lines.append("\n[Disk Usage]")
    used_percent, disk_ok = check_disk("/")
    if disk_ok:
        lines.append(f"  /: {used_percent}% used — OK")
    else:
        lines.append(f"  /: {used_percent}% used — WARNING")
        all_ok = False

    lines.append("\n[Summary]")
    if all_ok:
        lines.append("  Status: ALL SYSTEMS HEALTHY")
    else:
        lines.append("  Status: ISSUES DETECTED — review above")

    return "\n".join(lines)

# --,Main ---
if __name__ == "__main__":
    report = run_health_check()

    print(report)

    log_path = "/var/log/retailedge-health.log"
    try:
        with open(log_path, "a") as f:   # "a" = append mode
            f.write(report + "\n\n")
        print(f"\nReport saved to {log_path}")
    except PermissionError:
        print(f"\nNote: could not write to {log_path} — run with sudo for log saving")
```

Run it:
```bash
python3 health_check.py
sudo python3 health_check.py
sudo cat /var/log/retailedge-health.log
```

What you just learned:
,`from datetime import datetime` ,imports just one thing from a module
,`datetime.now().strftime(...)` ,formats the current time as a readable string
,`lines = []` and `lines.append(...)` ,building a list of strings, then joining them
,`"\n".join(lines)` ,joins a list into one string with newlines between items
,`with open(log_path, "a") as f:` ,opens a file safely; `"a"` means append
,`if __name__ == "__main__":` ,this block only runs when the script is run directly

---

**Step 3 — Make the script executable and run it directly**

```bash
chmod +x health_check.py
./health_check.py
```

**Step 4 — Commit to GitHub**

```bash
cd ~/cfe-labs
git add session-10/health_check.py
git commit -m "Session 10: Python health check script for RetailEdge"
git push origin main
```

**Python checkpoint — you should now be able to:**
,[ ] Explain what `import` does and why it is needed
,[ ] Write a function that takes an input and returns a result
,[ ] Use `subprocess.run()` to run a shell command from Python
,[ ] Use a `for` loop to process a list
,[ ] Write output to a file using `open()`
,[ ] Explain what `if __name__ == "__main__":` means

---

## Block 4 — OpenStack Introduction (45 mins)

### Objective: Understand what OpenStack is and why RetailEdge might need it

> **OpenStack level this session: Conceptual foundation**
> No hands-on install yet ,that comes in Session 11 with MicroStack.
> This session gives you the mental model so the hands-on makes sense.

**Part 1 — The core concept**

OpenStack is a collection of open-source services that together do what AWS does ,but running on hardware RetailEdge owns. When RetailEdge uses AWS, they call an API and a VM appears. When they use OpenStack, they call an API and a VM appears ,but that VM runs on their own servers.

| OpenStack Service | What it does | AWS equivalent |
|---|---|---|
| **Nova** | Creates and manages VMs | EC2 |
| **Neutron** | Creates and manages networks | VPC |
| **Cinder** | Creates and manages block storage volumes | EBS |
| **Glance** | Stores VM images | AMI store |
| **Keystone** | Handles login, users, and permissions | IAM |
| **Horizon** | Web dashboard | AWS Console |

**Part 2 — The economic argument**

OpenStack makes financial sense when a customer runs large, predictable, always-on workloads. AWS is optimised for elasticity ,you pay a premium for the ability to scale instantly. If RetailEdge runs 50 servers 24/7/365, they pay that elasticity premium constantly even though they never use the elasticity.

The crossover point is roughly 500+ cores running at over 60% utilisation continuously. Below that, AWS wins on simplicity. Above that, OpenStack wins on cost.

**Part 3 — Check whether your current instance could support MicroStack**

This is a check only ,the actual MicroStack install happens in Session 11 on a resized instance.

```bash
# Check available disk space (MicroStack needs ~15GB free)
df -h /

# Check RAM (MicroStack needs at least 8GB)
free -h

# Check instance type
curl -s http://169.254.169.254/latest/meta-data/instance-type

# A t3.micro (1GB RAM) is not sufficient ,note this for Session 11 planning
```

**Part 4 — Write your own architecture notes**

```bash
cat > ~/cfe-labs/session-10/openstack-notes.md << 'EOF'
# OpenStack for RetailEdge — Architecture Notes
# Session 10

## What RetailEdge currently uses (AWS)
,EC2 for compute
,VPC for networking
,EBS for storage
,IAM for access control

## What the OpenStack equivalent would look like
,Nova → replaces EC2
,Neutron → replaces VPC
,Cinder (backed by Ceph) → replaces EBS
,Keystone → replaces IAM
,Runs on: physical servers in RetailEdge's data centre

## When would RetailEdge benefit from OpenStack?
,If they grow beyond 500 cores running continuously
,If they have data residency requirements (data must stay in Nigeria)
,If their AWS bill becomes the biggest infrastructure cost line

## Questions I still have about OpenStack:
(write your genuine questions here — review them in Session 11)
EOF
```

**OpenStack checkpoint:**
,[ ] You can name the 6 core OpenStack services and their AWS equivalents
,[ ] You understand the economic argument for when OpenStack beats AWS
,[ ] You have checked your current instance's RAM/disk against MicroStack requirements
,[ ] You have written your own architecture notes

---

## End of Session — Decommission

This instance is not needed after this session unless you plan to keep it running for cost reasons you've accepted. To avoid ongoing charges:

```bash
# From your local machine
aws ec2 terminate-instances \
  --instance-ids <session-10-instance-id> \
  --region eu-west-1
```

If you plan to reuse this exact instance for Session 11 (which resizes it for MicroStack), you can leave it stopped instead of terminating it — see Session 11 Block 2 for the resize procedure.

---

*CFE Training Series Session 10 | Junior Cloud Field Engineer Readiness | RetailEdge Ltd | Python + OpenStack + Written Interview Track | Standalone Session*

