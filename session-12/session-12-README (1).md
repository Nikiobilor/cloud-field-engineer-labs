# CFE Training Series-Session 12
## Client Ticket: RetailEdge Ltd-Alerting Upgrade + Persistent Storage

**Estimated time:** ~3 hours
**Prerequisites:** Session 11 completed (MicroStack basics, paramiko SSH health checks)

---

## Block 1-Session Context (15 mins)

**The situation:** RetailEdge Ltd's infrastructure team reviewed the health-check script you built in Session 11 and raised three requests:

1. "Logging to a file is fine, but nobody's watching that file at 2am. We need Slack alerts when something goes down-and when it recovers."
2. "We're about to deploy a database on our OpenStack VM. It needs storage that survives if the VM restarts."
3. "We've heard Ceph is what real OpenStack deployments use under the hood for storage. Can you show us a basic version running?"

**What you're building today:**
- An upgraded monitoring script that sends real Slack messages instead of just logging
- A Cinder volume (OpenStack's version of an EBS volume) attached to a VM
- A single-node Ceph cluster with a block device you can actually mount and use

**AWS-equivalent framing for this ticket:** think of this as the OpenStack version of setting up CloudWatch Alarms with SNS notifications (Slack alerting), plus attaching an EBS volume to an EC2 instance (Cinder), plus a small taste of what's running underneath many storage services at scale (Ceph).

---

## Block 2-Infrastructure Lab (60 mins)

### Step 2.1-Launch the EC2 instance

Launch a fresh `t3.large` instance:
- AMI: Ubuntu 22.04
- EBS volume: **50GB minimum** (you're running MicroStack and MicroCeph side by side today-this needs real headroom)
- Region: `eu-west-1`
- Tag: `Session=12`

**Why 50GB and not less:** MicroStack alone can be tight on a smaller disk, and adding MicroCeph on top of it means you need enough free space for both the Cinder backend storage and a Ceph OSD file. Running out of space is one of the most common failure points in this session, so we're front-loading capacity.

Once you're SSH'd in, confirm the full disk is actually usable:
```bash
df -h /
```
You should see something close to 48G available. If it looks much smaller than what you attached, the partition wasn't extended to use the full EBS volume-go back to your Session 11 notes and run `growpart` + `resize2fs` before continuing.

**One more disk check that matters a lot today:**
```bash
df -h /tmp
```
**Plain-English explanation:** in this environment, `/tmp` is often mounted as `tmpfs`, which means it lives in your instance's RAM, not on the actual disk. It has its own much smaller size limit, separate from your 48GB of real disk space. If `/tmp` shows only a few GB, remember this for later-you'll be told exactly where to write large files instead, and it will matter for the Ceph step.

### Step 2.2-Set up a Slack webhook

Go to `slack.com` → sign into (or create) a free workspace → `api.slack.com/apps` → **Create New App** → **From scratch** → give it any name → under **Incoming Webhooks**, toggle it on → **Add New Webhook to Workspace** → pick a channel → copy the webhook URL.

**Plain-English explanation of what this actually is:** a webhook URL is a special, secret link that lets any program send a message into a specific Slack channel, without needing a full bot login or API key. Anyone who has this URL can post to your channel-treat it like a password, never commit it to Git.

Store it as an **environment variable** (never hardcode it in a Python file):
```bash
export RETAILEDGE_SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

**Plain-English explanation of `export` and why it matters:** without `export`, a variable only exists inside your current shell session. When you run `python3 monitor.py`, Python starts as a brand new, separate process-and separate processes don't automatically see variables from the shell that launched them unless those variables were `export`ed first. This is exactly like an EC2 instance not picking up an IAM role-the code isn't broken, the environment around it just doesn't have what it expects.

**Important:** environment variables do not survive closing your SSH session. If you reconnect tomorrow and alerts stop working, this is the first thing to check:
```bash
echo $RETAILEDGE_SLACK_WEBHOOK
```
If it prints nothing, `export` it again-or make it permanent by adding it to your shell's startup file:
```bash
echo 'export RETAILEDGE_SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"' >> ~/.bashrc
source ~/.bashrc
```

### Step 2.3-Build the three Docker containers

These simulate RetailEdge's remote servers, same pattern as Session 11: nginx + mysql + SSH, root/ubuntu password `password123`.

Reuse your Session 11 Dockerfile. The one thing changing today is `start.sh`-and how you create it matters more than it sounds.

**Create `start.sh` by pasting this entire block directly into your terminal** (not into a text editor, not copy-pasted through a tool that might alter it):

```bash
cat > start.sh << 'EOF'
#!/bin/bash
service ssh start
service nginx start
mysqld_safe --user=mysql &
sleep 3
tail -f /dev/null
EOF
```

**Plain-English explanation of each line:**
- `#!/bin/bash`-tells Linux "run this file using the bash shell." This must be the very first line of the file, with nothing above it.
- `service ssh start` / `service nginx start`-starts those two services the same way you did in Session 11.
- `mysqld_safe --user=mysql &`-this is the important change from Session 11's pattern. Ubuntu's normal `service mysql start` command assumes a full init system (systemd) is managing it-inside a bare Docker container, that assumption breaks. What actually happens is MySQL initializes itself once, then shuts itself down, expecting systemd to restart it-which never happens in a container. Calling `mysqld_safe` directly starts the real, persistent MySQL process ourselves, bypassing that broken assumption. The `&` runs it in the background so the script can continue to the next line instead of waiting forever.
- `sleep 3`-pauses 3 seconds, giving MySQL time to finish starting up before the next line runs.
- `tail -f /dev/null`-this is what keeps the container alive. Docker containers exit as soon as their main process finishes; this command never finishes on its own, so it keeps the container running indefinitely.

**Verify the file is clean before building-this step catches two real, easy-to-hit mistakes:**
```bash
cat -A start.sh
```
You should see exactly this, with every line ending in a plain `$`:
```
#!/bin/bash$
service ssh start$
service nginx start$
mysqld_safe --user=mysql &$
sleep 3$
tail -f /dev/null$
```
If you instead see `^M$` at the end of lines, the file has hidden Windows-style line endings (CRLF), which causes a confusing `exec format error` when Docker tries to run it-because Linux tries to find an interpreter literally named `/bin/bash` followed by an invisible extra character, which doesn't exist. Fix it with:
```bash
sed -i 's/\r$//' start.sh
```
If you instead see a line like `cat > start.sh << 'EOF'` sitting inside the file itself, the heredoc command got saved as content rather than executed as a command-delete the file and recreate it using the exact block above, run directly in your terminal.

Make it executable:
```bash
chmod +x start.sh
```

Build the image and run the three containers:
```bash
docker build -t retailedge-server .
docker run -d --name server-01 retailedge-server
docker run -d --name server-02 retailedge-server
docker run -d --name server-03 retailedge-server
docker ps
```
**Plain-English explanation:** `docker build` reads your Dockerfile and any files it copies in (like `start.sh`) and bakes them into a reusable image. `docker run` starts an actual container from that image. This distinction matters a lot going forward-**any time you edit a file that gets copied into the image, you must run `docker build` again before your change takes effect.** Running the container again without rebuilding just launches the same old code.

Check `docker ps` (not `docker ps -a`)-all three containers should show `Up`. If any show `Exited`, check its logs:
```bash
docker logs server-01
```

Get each container's IP address, since you'll need these for the Python script next:
```bash
docker inspect server-01 --format '{{.NetworkSettings.IPAddress}}'
docker inspect server-02 --format '{{.NetworkSettings.IPAddress}}'
docker inspect server-03 --format '{{.NetworkSettings.IPAddress}}'
```

Confirm MySQL actually stayed running (not just started and silently died):
```bash
docker exec server-01 service mysql status
```
You should see `* MySQL running`. If it says stopped, wait a few more seconds and check again-first-time initialization can take a moment.

Now simulate the fault the ticket describes-stop nginx on server-02:
```bash
docker exec server-02 service nginx stop
```

---

## Block 3-Python Component (60 mins)

### New Python concepts, explained before you use them

- **`import requests`**-`requests` is a third-party library (not built into core Python) used for making HTTP calls. Install it first:
  ```bash
  pip3 install requests
  ```
- **HTTP POST, and `requests.post(url, json=payload)`**-HTTP is the protocol web services use to talk to each other. **POST** means "here's data, do something with it" (as opposed to **GET**, which means "give me data back"). You're sending data *to* Slack, so this is a POST. `json=payload` takes a Python dictionary and automatically converts it into JSON text (a standard text format for structured data) and tells Slack "this is JSON I'm sending you."
- **`os.environ.get("VAR_NAME")`**-reads an environment variable safely. Unlike accessing a missing dictionary key, this returns `None` instead of crashing if the variable isn't set-which lets your code check for that and print a helpful warning instead of failing unexpectedly.
- **`try/except` with named exception types**-instead of one generic `except:` that catches everything, naming specific exceptions (`Timeout`, `ConnectionError`) tells you *why* something failed, not just *that* it failed. A bare `except: return False` silently hides the real cause-worth avoiding everywhere, including here.
- **Splitting code into modules**-`slack_alerts.py` holds reusable alert-sending logic; `monitor.py` holds the orchestration logic (checking servers, tracking state). `monitor.py` will `import` from `slack_alerts.py`, the same way you `import paramiko`-except this time it's your own file.

### Step 3.1-Create `slack_alerts.py`

```bash
mkdir -p ~/cfe-labs/session-12
cd ~/cfe-labs/session-12
```

```python
cat > slack_alerts.py << 'EOF'
#!/usr/bin/env python3
# slack_alerts.py
# RetailEdge Ltd-reusable Slack alerting module

import os
import requests


def send_alert(message, webhook_url=None):
    """Send a plain message to Slack. Reads the webhook URL from an
    environment variable if one isn't passed in directly."""
    if webhook_url is None:
        webhook_url = os.environ.get("RETAILEDGE_SLACK_WEBHOOK")

    if not webhook_url:
        print("WARNING: No Slack webhook URL configured. Alert not sent.")
        return False

    payload = {"text": message}

    try:
        response = requests.post(webhook_url, json=payload, timeout=5)
        if response.status_code == 200:
            return True
        else:
            print(f"Slack returned status {response.status_code}")
            return False
    except requests.exceptions.Timeout:
        print("Slack webhook timed out.")
        return False
    except requests.exceptions.ConnectionError:
        print("Could not connect to Slack.")
        return False


def send_server_down_alert(server_name, service_name, host):
    """Send a formatted 'service is down' alert."""
    message = f":red_circle: *{server_name}*-`{service_name}` is DOWN (host: {host})"
    return send_alert(message)


def send_recovery_alert(server_name, service_name, host):
    """Send a formatted 'service recovered' alert."""
    message = f":large_green_circle: *{server_name}*-`{service_name}` has RECOVERED (host: {host})"
    return send_alert(message)
EOF
```

**Quick test before moving on**-confirm your webhook actually works end to end:
```bash
python3 -c "
import slack_alerts
slack_alerts.send_server_down_alert('server-02', 'nginx', '172.17.0.3')
"
```
Check your Slack channel for the message. If you see `WARNING: No Slack webhook URL configured`, go back to Step 2.2-your environment variable isn't set in this shell session.

### Step 3.2-Create `monitor.py`

**First, find your containers' actual IP addresses** from Step 2.3 and use them below-they won't necessarily be `172.17.0.2/3/4`, though that's the common default.

```python
cat > monitor.py << 'EOF'
#!/usr/bin/env python3
# monitor.py
# RetailEdge Ltd-Integrated Health Monitor with Slack Alerting
# CFE Training Series Session 12

import paramiko
import os
from datetime import datetime
from slack_alerts import send_server_down_alert, send_recovery_alert

SERVERS = [
    {"name": "server-01", "host": "172.17.0.2", "user": "root", "password": "password123"},
    {"name": "server-02", "host": "172.17.0.3", "user": "root", "password": "password123"},
    {"name": "server-03", "host": "172.17.0.4", "user": "root", "password": "password123"},
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
        pwd = server["password"]

        for service in SERVICES_TO_CHECK:
            # Check the SERVICE (nginx/mysql), not the server name.
            output = ssh_run_command(host, user, pwd,
                                      f"service {service} status")
            # Ubuntu's `service` command prints "is running", not
            # the word "active" (that's systemctl's vocabulary instead).
            is_down = "is running" not in output

            state_key = f"{name}:{service}:DOWN"

            if is_down:
                current_state.add(state_key)
                if state_key not in previous_state:
                    print(f"  NEW ISSUE: {name}-{service} is DOWN")
                    new_issues.append((name, service, host))
                else:
                    print(f"  ONGOING: {name}-{service} still DOWN")
            else:
                print(f"  OK: {name}-{service}")
                if state_key in previous_state:
                    print(f"  RECOVERED: {name}-{service} is back UP")
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
EOF
```

**Before running it, update the `host` values** in the `SERVERS` list to match the real IPs from Step 2.3, and confirm the `user` matches what your Dockerfile actually creates-check with:
```bash
docker exec server-01 cat /etc/passwd | grep -E "ubuntu|root"
```
Both `root` and `ubuntu` usually exist; use whichever one your Dockerfile sets a password for.

### Step 3.3-The three-run test

**Run 1**-should show a NEW ISSUE alert for server-02 (nginx), and a Slack message should arrive:
```bash
python3 monitor.py
```

**Run 2**-should show ONGOING (no duplicate alert):
```bash
python3 monitor.py
```

Bring nginx back up on server-02:
```bash
docker exec server-02 service nginx start
```

**Run 3**-should show RECOVERED, and a green recovery message should arrive in Slack:
```bash
python3 monitor.py
```

**If every service shows as DOWN across every server, on every run**-this is the single most common issue in this whole session. It almost never means every service actually failed; it means the *check itself* is broken. Add this line temporarily just above `is_down = ...`:
```python
print(f"    DEBUG: {name}/{service} → {repr(output)}")
```
Run it again and read the raw output. It will directly show you whether it's a real service status, an SSH authentication failure, or a connection error-instead of guessing.

---

## Block 4-OpenStack Cinder + MicroCeph (45 mins)

### Step 4.1-Install MicroStack and launch the VM

Since each session is standalone (fresh infrastructure, terminated at the end), install MicroStack fresh on this instance even if you did this in Session 11-it doesn't carry over.

```bash
ssh -i ~/.ssh/<keypair_name> ubuntu@<public_ip>
sudo snap install microstack --devmode --beta
sudo microstack init --auto --control
```
**Plain-English explanation:** `--devmode` relaxes some snap security confinement that MicroStack needs to function properly on a single node. `microstack init --auto --control` sets up all the core OpenStack services (Keystone for identity, Nova for compute, Neutron for networking, Glance for images, Cinder for storage) with sensible defaults, instead of you configuring each one by hand. This step takes several minutes-it's genuinely doing a lot of work, not stuck.

**Before launching any VM, fix outbound networking-this must happen first, every session:**

```bash
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
```
**Plain-English explanation:** this is the exact bug from Session 11-without IP forwarding enabled, VMs launched inside MicroStack have no outbound internet access at all, even though everything else looks correctly configured. Setting this before you launch anything avoids re-diagnosing it. The second line makes the setting survive a reboot.

**Create a custom flavor** (a flavor is OpenStack's version of an EC2 instance type-it defines vCPU, RAM, and disk size for VMs you launch):
```bash
sudo microstack.openstack flavor create --ram 2048 --disk 10 --vcpus 1 m1.custom
```
**Why not use the default `m1.tiny` flavor:** its disk size is too small and will cause a "No valid host found" error when you try to launch a VM. `m1.custom` (2GB RAM, 10GB disk, 1 vCPU) gives enough room for the OS plus the volumes you'll attach later.

— Upload an image to Glance**

Before Nova can create a VM, it needs an actual operating system to install onto it, Glance is where that operating system file lives. This step downloads a real Ubuntu 22.04 disk image directly from Canonical, then uploads it into Glance so OpenStack has something to install when you launch a VM in Step 4.

```bash
wget https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img

sudo microstack.openstack image create \
  --file ubuntu-22.04-minimal-cloudimg-amd64.img \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  "Ubuntu-22.04-Minimal"
```

- `--disk-format qcow2` — tells Glance what file format the image is in (qcow2 is a common virtual disk format)
- `--container-format bare` — tells Glance this is just a plain disk image, with no extra packaging around it
- `--public` — makes the image available to any project in this OpenStack environment, not just you

```bash
sudo microstack.openstack image list
```
This just confirms the image is now stored in Glance and ready to use, the same idea as checking `aws ec2 describe-images` to confirm an AMI exists before launching from it.

**Step 4 — Launch your first VM inside OpenStack**

First, create a keypair
```bash
ssh-keygen -t ed25519 -f ~/.ssh/retailedge_key
sudo microstack.openstack keypair create --public-key ~/.ssh/retailedge_key.pub retailedge-key

```

Now create the actual VM. This is the OpenStack equivalent of `aws ec2 run-instances`, you're telling Nova what size (`flavor`), what operating system (`image`, from Glance), and which SSH key to trust:

Run this command to find the network-name 
NB: DO not use the external network
```bash
sudo microstack.openstack network list
```
**Launch the VM:**
```bash
sudo microstack.openstack server create --flavor m1.custom --image "Ubuntu-22.04-Minimal" --key-name retailedge-key --network test --config-drive True retailedge-web-01

sudo microstack.openstack server list
# Status goes BUILD → ACTIVE. Wait until ACTIVE.
 ```
**Plain-English explanation of `--config-drive True`:** normally, a VM fetches its SSH key and setup instructions from a metadata service it reaches over the network. On MicroStack's single-node setup, that metadata service is often unreachable from inside the VM, which means your SSH key silently never arrives and you can't log in. `--config-drive True` instead attaches the same information as a small virtual disk directly to the VM, bypassing the network path entirely.

Check available images and networks first if you don't already have the exact names:
```bash
sudo microstack.openstack image list
sudo microstack.openstack network list
```

**Confirm the VM actually launched successfully:**
```bash
sudo microstack.openstack server list
```
Status should show `ACTIVE`. If it shows `ERROR`, the most common cause at this point is the flavor's disk being too small (double check you used `m1.custom`, not a default flavor) or the root partition running out of space-re-check `df -h /` from Step 2.1.

**Assign a floating IP so you can SSH into it:**
```bash
sudo microstack.openstack floating ip create <external-network-name>
sudo microstack.openstack server add floating ip retailedge-web-01 <floating-ip-address>
```

Confirm you can reach it before moving on:
```bash
ssh -i ~/.ssh/retailedge_key ubuntu@<floating-ip-address>
```
If the key never arrived and you're prompted for a password you don't have, double-check `--config-drive True` was actually included in the `server create` command-this is the single most common reason SSH access fails at this step.

### Step 4.2-Cinder volume (OpenStack's version of an EBS volume)

**Before creating any volume, set up the storage backend it needs.** MicroStack does not create this automatically-skipping this step means `volume create` appears to succeed but the volume silently ends up in `error` status.

Check whether the backend volume group already exists:
```bash
sudo vgs
sudo vgdisplay cinder-volumes 2>&1
```

If `cinder-volumes` doesn't exist, create it. This uses a **loop device**-a plain file made to behave like a physical disk, the same trick you'll use again for Ceph below:
```bash
sudo mkdir -p /var/snap/microstack/common/cinder
sudo truncate -s 20G /var/snap/microstack/common/cinder/cinder.img
sudo losetup -fP /var/snap/microstack/common/cinder/cinder.img
losetup -a
```
**Note which `/dev/loopX` was assigned** (X being cinder) in the output-use that exact device name below (don't guess or reuse an old one):
```bash
sudo pvcreate /dev/loopX
sudo vgcreate cinder-volumes /dev/loopX
sudo snap start microstack.cinder-volume
```

**Before attaching a volume to a VM, confirm iSCSI is running.** Cinder's default backend exposes volumes to VMs over iSCSI-volume creation can succeed even if this is off, but *attaching* the volume will fail until it's running:
```bash
sudo systemctl status iscsid
sudo systemctl enable --now iscsid
```
**Plain-English explanation of iSCSI:** it's a protocol that lets a VM connect to a block storage device over the network as if it were a local disk. This is the mechanism Cinder uses under the hood to make the volume appear inside your VM.

Now create and attach the volume:
```bash
sudo microstack.openstack volume create --size 5 retailedge-data-vol
sudo microstack.openstack volume list
```
Confirm `Status` shows `available`, not `error`, before continuing.

```bash
sudo microstack.openstack server add volume retailedge-web-01 retailedge-data-vol
sudo microstack.openstack volume show retailedge-data-vol
```

SSH into the VM and set up the volume:
```bash
ssh -i ~/.ssh/retailedge_key ubuntu@<VM_FLOATING_IP>
lsblk
```
**Plain-English explanation:** `lsblk` lists block devices attached to the VM. Your new volume will show up as something like `/dev/vdb`-find it by comparing to what was there before you attached it.

```bash
sudo mkfs.ext4 /dev/vdb
sudo mkdir -p /data
sudo mount /dev/vdb /data
echo "test file" | sudo tee /data/test.txt
```
**Plain-English explanation:** `mkfs.ext4` formats the raw block device with a filesystem so it can actually store files. `mount` makes it accessible at a folder path. This is the OpenStack equivalent of attaching an EBS volume to an EC2 instance and then formatting/mounting it before use.

### Step 4.3-MicroCeph (single-node Ceph)

```bash
sudo snap install microceph
sudo microceph cluster bootstrap
sudo microceph status
```
You should see `mds`, `mgr`, `mon` services running, and `Disks: 0`-expected at this point, since you haven't added a disk yet.

**Create the OSD backing file-write it to real disk, not `/tmp`.** Remember the `/tmp` check from Step 2.1: if `/tmp` is a small `tmpfs` (RAM-backed) mount, writing a large file there will fail with "No space left on device" even though your actual disk has plenty of room:
```bash
sudo dd if=/dev/zero of=/var/snap/microceph/common/ceph-osd-1.img bs=1M count=10240
```
**Plain-English explanation:** this creates a 10GB file made entirely of zeroes, which will act as the raw storage for your Ceph disk-same loop-device trick as the Cinder step above.

```bash
sudo losetup -f /var/snap/microceph/common/ceph-osd-1.img
losetup -a
```
**Note the exact `/dev/loopX` this was assigned**-use that real device name in the next command, not a placeholder:
```bash
sudo microceph disk add /dev/loopX --wipe
sudo microceph status
```
You should now see `Disks: 1`.

**Create the RBD pool and image.** RBD is Ceph's block device-the same role as an EBS volume or a Cinder volume, just backed by Ceph:
```bash
sudo microceph.ceph osd pool create retailedge-rbd 32
sudo microceph.rbd pool init retailedge-rbd
sudo microceph.rbd create --size 2048 retailedge-rbd/web-disk-01
```

**Map it to a real device on this host, then format and mount it:**
```bash
sudo microceph.rbd map retailedge-rbd/web-disk-01
rbd showmapped
```
This shows you the device it mapped to, e.g. `/dev/rbd0`.
```bash
sudo mkfs.ext4 /dev/rbd0
sudo mkdir -p /mnt/ceph-test
sudo mount /dev/rbd0 /mnt/ceph-test
echo "ceph test file" | sudo tee /mnt/ceph-test/test.txt
```

**Why this matters for RetailEdge in the real world:** in production OpenStack deployments, Cinder often uses Ceph RBD as its actual storage backend, instead of the simple LVM setup used in Step 4.1. This lab builds both separately so each concept is clear on its own, but they frequently combine in real infrastructure.

---

## Block 5-Written Interview Capture (20 mins)

Add to `~/cfe-labs/canonical-written-interview-draft.md`, in your own words based on what you actually did today:

**Q7-Describe your approach to writing maintainable code.**
Reference: splitting `slack_alerts.py` from `monitor.py`, using environment variables instead of hardcoded secrets, and state-file tracking to avoid duplicate alerts.

**Q8-What is your experience with storage systems?**
Reference: setting up a Cinder volume backend (LVM group + iSCSI) and a MicroCeph OSD/RBD image, including real debugging-a missing volume group, a missing iSCSI service, and a `tmpfs`-vs-real-disk mixup that looked like a storage problem but was actually a RAM limit.

**Q9-How do you handle errors and unexpected failures?**
Reference: named exception types (`Timeout`, `ConnectionError`) in `slack_alerts.py`, and the `monitor.py` debugging story-two separate bugs (wrong variable in an SSH command, wrong string comparison) that produced the exact same misleading symptom, resolved by adding a temporary debug print to see the raw output instead of guessing at the cause.

---

## Completion Checklist
- [ ] Slack alerts fire correctly for new issues and new recoveries only (verified across all 3 monitor.py test runs)
- [ ] Cinder volume created, attached, formatted, and mounted with a test file inside the VM
- [ ] MicroCeph cluster bootstrapped, disk added, RBD pool/image created, mapped and mounted with a test file
- [ ] Written interview draft updated with Q7, Q8, Q9
- [ ] Code committed with message: `Session 12: Slack alerting + OpenStack Cinder volume + MicroCeph RBD`

## Decommission
```bash
aws ec2 terminate-instances --instance-ids <id> --region eu-west-1
```

## LinkedIn Post Prompt
Don't summarize the session-pull one sharp moment of realisation. Strong options from today: the two-bugs-one-symptom story in `monitor.py`, or the `tmpfs`-vs-real-disk mixup that looked like running out of storage but was actually a RAM ceiling.

## Preview-Session 13
Terraform-based provisioning begins: module-based infrastructure, first hands-on OpenStack lab covering Keystone, Nova, Neutron, Glance, and Cinder in plain English, a four-stage `boto3` Python component, and written interview questions.
