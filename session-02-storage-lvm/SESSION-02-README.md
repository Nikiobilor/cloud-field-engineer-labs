# TICKET-002: Storage Optimisation — LVM, EBS Volumes & Filesystem Monitoring
### Canonical Cloud Field Engineer Lab Series | Session 2 of 32

---

## 🎫 The Ticket

```
TICKET ID:    CFE-002
PRIORITY:     High
ASSIGNED TO:  Cloud Field Engineer (You)
CLIENT:       RetailEdge Ltd — E-commerce platform, Lagos & London
ENVIRONMENT:  Ubuntu 22.04 LTS on AWS EC2 (continuation from CFE-001)

SUBJECT: Application logs filling root disk. Storage architecture
         needs redesign before Black Friday traffic.

DESCRIPTION:
Since you tuned our server last week, performance is better but
our ops team just paged us at 2am — the root disk hit 95% and the
app started throwing write errors. All application logs, database
files, and uploads are sitting on the root volume.

We need proper storage separation. Logs should be on their own
volume. The database data directory needs dedicated storage that
can grow independently. We also need monitoring so we never get
blindsided by a full disk again.

We have budget to add two EBS volumes. The solution must survive
a server reboot without manual intervention.

ACCEPTANCE CRITERIA:
- [ ] Two additional EBS volumes provisioned via Terraform
- [ ] LVM configured: one volume group managing both disks
- [ ] /var/log mounted on its own logical volume
- [ ] /data mounted on a separate logical volume (for future DB)
- [ ] Both mounts persist across reboots (fstab)
- [ ] Disk usage alerts configured (>80% triggers warning)
- [ ] Monitoring script runs as a systemd timer (not cron)
- [ ] Handover document written for support team
```

---

## 🎯 Task Goal

By the end of this session you will have:
- Provisioned additional EBS volumes with Terraform
- Understood and configured LVM (Logical Volume Manager) from scratch
- Mounted filesystems persistently using `/etc/fstab` with UUID references
- Written a disk monitoring script in Bash
- Configured a **systemd timer** (the modern replacement for cron) to run it
- Understood why storage separation matters in production systems

**What you will learn that you may not already know:**
- How LVM works — physical volumes, volume groups, logical volumes
- Why you use UUIDs in fstab, not device names like `/dev/xvdb`
- What a systemd timer is and why it's better than cron for service-managed systems
- How EBS volumes behave differently from instance storage

---

## 🏗️ Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        AWS (Free Tier)                            │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                    VPC (10.0.0.0/16)                        │  │
│  │                                                            │  │
│  │  ┌───────────────────────────────────────────────────┐    │  │
│  │  │              EC2: Ubuntu 22.04 (t2.micro)          │    │  │
│  │  │                                                   │    │  │
│  │  │  STORAGE LAYOUT:                                  │    │  │
│  │  │                                                   │    │  │
│  │  │  /dev/xvda (8GB gp3) ──── root filesystem /      │    │  │
│  │  │                                                   │    │  │
│  │  │  /dev/xvdb (5GB gp3) ──┐                         │    │  │
│  │  │                        ├── LVM Volume Group       │    │  │
│  │  │  /dev/xvdc (5GB gp3) ──┘   "lab-vg"             │    │  │
│  │  │                            │                      │    │  │
│  │  │                            ├── lv-logs (2.5GB)      │    │  │
│  │  │                            │   mounted: /var/log  │    │  │
│  │  │                            │                      │    │  │
│  │  │                            └── lv-data (5GB)      │    │  │
│  │  │                                mounted: /data     │    │  │
│  │  │                                                   │    │  │
│  │  │  systemd timer (every 5min):                      │    │  │
│  │  │  disk-monitor.sh → logs to journald               │    │  │
│  │  │                                                   │    │  │
│  │  └───────────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘

Terraform manages: EC2 + 3 EBS volumes + VPC + Security Group
LVM manages: logical allocation of /dev/xvdb + /dev/xvdc
```

---

## 📋 Prerequisites

- Completed Session 1 (or comfortable with Terraform basics)
- AWS Free Tier account configured
- Terraform installed
- SSH key pair from Session 1 (`~/.ssh/canonical_lab_key`)

> 💡 **Free tier note:** Two additional 5GB EBS `gp3` volumes are well within the free tier allowance of 30GB total EBS storage. We will destroy everything at the end.

---

## 🧠 Concept: Understanding LVM Before You Touch It

Before running a single command, understand what LVM actually is. This section is not optional — LVM has its own vocabulary and if you skip this you will be confused by the commands later.

**The problem LVM solves:**

Without LVM, a filesystem lives directly on a disk partition. If `/var/log` fills up and lives on a 10GB partition, you cannot grow it without unmounting it, resizing the partition, and resizing the filesystem — a risky operation that often requires downtime.

With LVM, there is an abstraction layer between the filesystem and the physical disk:

```
Physical Disk(s)
      ↓
Physical Volume (PV)   ← LVM's view of a disk
      ↓
Volume Group (VG)      ← pool of storage combining one or more PVs
      ↓
Logical Volume (LV)    ← a flexible "virtual partition" you format and mount
      ↓
Filesystem (ext4/xfs)  ← what you actually use
```

The key insight: a Logical Volume can span multiple physical disks, can be resized online (usually without unmounting), and can have snapshots taken of it. When RetailEdge's `/var/log` partition fills up, you can add another EBS volume to the volume group and extend the logical volume in minutes — with no downtime.

**The three LVM layers in plain English:**

- **Physical Volume (PV):** You tell LVM "this disk is yours now." LVM writes metadata to it and divides it into 4MB chunks called Physical Extents (PEs). Command: `pvcreate`.

- **Volume Group (VG):** You combine one or more PVs into a pool. The VG is just a named pool of Physical Extents. You don't format or mount a VG. Command: `vgcreate`.

- **Logical Volume (LV):** You carve slices out of the VG pool and get something that behaves like a disk partition — you format it with ext4 or xfs and mount it. The LV is made of Logical Extents (LEs) which map to Physical Extents in the VG. Command: `lvcreate`.

---

## 🚀 Step-by-Step Lab Guide

### STEP 1: Update Your Terraform Configuration

**What we are doing:** We are adding two EBS volumes to our existing Terraform configuration and attaching them to the EC2 instance. This is how a field engineer provisions storage in a real engagement — as code, reviewable, repeatable.

#### 1a. Navigate to your project and add the new resources

```bash
mkdir -p cloud-field-engineer-labs/session-02-storage-lvm/
cd canonical-field-engineer-labs/session-02-storage-lvm/
## copy the terraform files from session 1 into this directory 
cp -r ../session-01-linux-tuning/terraform/ .
```

Update `main.tf`. The VPC, subnet, security group, and EC2 instance are identical to Session 1. We are adding three new resource blocks at the bottom.

**Add to `main.tf` — the two new EBS volumes:**

```hcl
# ─────────────────────────────────────────────
# EBS VOLUMES FOR LVM
# Two separate volumes that LVM will pool together
# ─────────────────────────────────────────────

# First additional volume — will be one of two PVs in our VG
resource "aws_ebs_volume" "lvm_disk1" {
  # Volume must be in the same AZ as the EC2 instance
  availability_zone = "${var.aws_region}a"
  size              = 5    # GB — within free tier (30GB total allowed)
  type              = "gp3" # gp3 is newer, faster, and cheaper than gp2

  tags = {
    Name    = "canonical-lab-lvm-disk1"
    Project = "canonical-cfe-labs"
    Session = "02"
  }
}

# Second additional volume
resource "aws_ebs_volume" "lvm_disk2" {
  availability_zone = "${var.aws_region}a"
  size              = 5
  type              = "gp3"

  tags = {
    Name    = "canonical-lab-lvm-disk2"
    Project = "canonical-cfe-labs"
    Session = "02"
  }
}

# ─────────────────────────────────────────────
# EBS VOLUME ATTACHMENTS
# These connect the volumes to the EC2 instance
# device_name is what Linux will see the disk as
# ─────────────────────────────────────────────

resource "aws_volume_attachment" "lvm_disk1_attach" {
  device_name = "/dev/xvdb"          # Linux device path
  volume_id   = aws_ebs_volume.lvm_disk1.id
  instance_id = aws_instance.lab_server.id

  # force_detach: if we destroy while the volume is mounted,
  # force the detach rather than erroring out
  # force_detach: LABS ONLY - allows terraform destroy to work cleanly
  # In production, set to false to prevent accidental data loss

  force_detach = true
}

resource "aws_volume_attachment" "lvm_disk2_attach" {
  device_name = "/dev/xvdc"
  volume_id   = aws_ebs_volume.lvm_disk2.id
  instance_id = aws_instance.lab_server.id

  force_detach = true
}
```

**Update `outputs.tf` to include storage info:**

```hcl
output "lvm_disk1_id" {
  description = "EBS volume ID for LVM disk 1"
  value       = aws_ebs_volume.lvm_disk1.id
}

output "lvm_disk2_id" {
  description = "EBS volume ID for LVM disk 2"
  value       = aws_ebs_volume.lvm_disk2.id
}
```

#### 1b. Deploy the updated infrastructure

```bash
terraform init   # needed if this is a new directory

# Review what will be created
terraform plan
# You should see: 2 EBS volumes + 2 volume attachments to be added

# Apply
terraform apply
# Type 'yes' when prompted

# Save the IP
export SERVER_IP=$(terraform output -raw instance_public_ip)
echo "Server: $SERVER_IP"
```

---

### STEP 2: Verify the Disks Are Visible on the Server

**What we are doing:** Before touching LVM, we confirm Linux can see the new disks. This is a discipline — always verify your physical layer before building logical layers on top of it.

```bash
ssh -i ~/.ssh/canonical_lab_key ubuntu@$SERVER_IP
```

Once connected:

```bash
# List all block devices in a tree format
lsblk
# Expected output:
# NAME    MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
# xvda    202:0    0   8G  0 disk
# └─xvda1 202:1    0   8G  0 part /
# xvdb    202:16   0   5G  0 disk        ← our first new disk
# xvdc    202:32   0   5G  0 disk        ← our second new disk

# Alternative: fdisk shows more detail about each disk
sudo fdisk -l /dev/xvdb
# Disk /dev/xvdb: 5 GiB, 5368709120 bytes, 10485760 sectors
# The disk has no partitions yet — that's correct, LVM works on raw disks

sudo fdisk -l /dev/xvdc
```

> 💡 **Why no partitions?** With traditional storage you would create a partition table and partitions first. With LVM, you hand the raw disk directly to LVM using `pvcreate`. LVM manages its own internal organisation. Creating partitions first is technically possible but adds a layer of complexity with no benefit when LVM is managing everything.

```bash
# Check current disk usage so we have a baseline
df -h
# Notice everything is on /dev/xvda1 (the root volume)
# This is the problem we are solving — no separation of concerns
```

---

### STEP 3: Install LVM and Configure Physical Volumes

**What we are doing:** We initialise each new disk as an LVM Physical Volume. This is the first layer of the LVM stack.

#### 3a. Install LVM tools

```bash
sudo apt-get update
sudo apt-get install -y lvm2

# Verify installation
sudo pvdisplay
# Output: "No physical volumes defined yet" — correct, we haven't created any
```

#### 3b. Create Physical Volumes

```bash
# Tell LVM that /dev/xvdb is now an LVM physical volume
sudo pvcreate /dev/xvdb

# Expected output:
# Physical volume "/dev/xvdb" successfully created.

# Repeat for the second disk
sudo pvcreate /dev/xvdc
# Physical volume "/dev/xvdc" successfully created.

# Verify both PVs are registered with LVM
sudo pvdisplay
# Shows both disks, each with 5GB of capacity
# Note "PV Size" and "Allocatable" fields

# Shorter summary view
sudo pvs
# PV         VG  Fmt  Attr PSize  PFree
# /dev/xvdb      lvm2 ---  <5.00g <5.00g
# /dev/xvdc      lvm2 ---  <5.00g <5.00g
# VG column is empty — they haven't been added to a group yet
```

> 💡 **What pvcreate actually does:** It writes LVM metadata (called a label) to the beginning of the disk. This metadata includes a UUID for the PV, its size in Physical Extents, and a pointer to the Volume Group it belongs to. You can read this with `sudo pvck /dev/xvdb`.

---

### STEP 4: Create the Volume Group

**What we are doing:** We combine both physical volumes into a single pool called a Volume Group. From LVM's perspective, `lab-vg` will appear as one 10GB storage pool.

```bash
# Create a volume group called "lab-vg" using both physical volumes
sudo vgcreate lab-vg /dev/xvdb /dev/xvdc

# Expected output:
# Volume group "lab-vg" successfully created

# Inspect the volume group
sudo vgdisplay lab-vg
# VG Name               lab-vg
# VG Size               <9.99 GiB    ← slightly under 10GB due to LVM metadata overhead
# PE Size               4.00 MiB     ← Physical Extent size (the allocation unit)
# Total PE              2558         ← total number of 4MB extents available
# Alloc PE / Size       0 / 0        ← nothing allocated yet
# Free  PE / Size       2558 / <9.99 GiB

# Short summary
sudo vgs
# VG     #PV #LV #SN Attr   VSize  VFree
# lab-vg   2   0   0 wz--n- <9.99g <9.99g
# 2 physical volumes, 0 logical volumes allocated yet
```

> 💡 **The PE Size matters:** Every allocation in LVM happens in units of Physical Extents (default 4MB). If you request a 3GB logical volume, LVM actually allocates 768 extents × 4MB = 3072MB. This is why LVM sizes are sometimes slightly different from what you requested.

---

### STEP 5: Create Logical Volumes

**What we are doing:** We carve the volume group pool into two logical volumes — one for logs, one for application data.

```bash
# Create the logs logical volume — 2.5GB
# -L 2.5G : size
# -n lv-logs : name
# lab-vg : which volume group to allocate from
sudo lvcreate -L 2.5G -n lv-logs lab-vg

# Expected:
# Logical volume "lv-logs" created.

# Create the data logical volume — use the remaining free space
# -l 100%FREE means "use all remaining free extents"
sudo lvcreate -l 100%FREE -n lv-data lab-vg

# Verify both logical volumes exist
sudo lvdisplay
# Shows lv-logs at 2.5GB and lv-data at ~6.99GB

# Short summary
sudo lvs
# LV      VG     Attr       LSize  Pool Origin Snap% Move Log Cpy%Sync Convert
# lv-data lab-vg -wi-a----- <6.99g
# lv-logs lab-vg -wi-a-----  3.00g

# The full device paths for these LVs are:
# /dev/lab-vg/lv-logs
# /dev/lab-vg/lv-data
# (also accessible as /dev/mapper/lab--vg-lv--logs etc.)
```

---

### STEP 6: Format the Logical Volumes with ext4

**What we are doing:** A logical volume is just raw block storage — it has no filesystem yet. We format both with ext4, which is the standard Linux filesystem for most workloads.

```bash
# Format lv-logs with ext4
# -L flag sets a filesystem label — useful for identification
sudo mkfs.ext4 -L "lab-logs" /dev/lab-vg/lv-logs

# You will see output like:
# mke2fs 1.46.5
# Creating filesystem with 786432 4k blocks and 196608 inodes
# Writing superblocks and filesystem accounting information: done

# Format lv-data
sudo mkfs.ext4 -L "lab-data" /dev/lab-vg/lv-data
```

> 💡 **Why ext4 and not xfs?** Both are excellent. ext4 is Ubuntu's default and well-understood. xfs is often preferred for large files and high-throughput workloads (databases, video). For a general-purpose log volume, ext4 is fine. 

---

### STEP 7: Mount the Filesystems Permanently

**What we are doing:** We create the mount points, mount the filesystems, and — critically — add them to `/etc/fstab` so they remount automatically on every reboot.

#### 7a. Migrate existing log files first

```bash
# IMPORTANT: /var/log already exists and has content.
# We must move that content BEFORE mounting over it.
# If we mount first, the existing logs become invisible
# (hidden under the new filesystem) but are not deleted —
# they still consume space on the root volume. Classic mistake.

# Create temporary holding area
sudo mkdir /var/log_backup

# Copy all existing logs preserving permissions
sudo cp -a /var/log/. /var/log_backup/

# Verify the copy
ls -la /var/log_backup/ | head -10
```

#### 7b. Mount the log volume

```bash
# The /var/log directory already exists — we just mount onto it
sudo mount /dev/lab-vg/lv-logs /var/log

# Restore the backed-up logs onto the new volume
sudo cp -a /var/log_backup/. /var/log/

# Verify it's mounted
df -h /var/log
# Filesystem               Size  Used Avail Use% Mounted on
# /dev/mapper/lab--vg-lv--logs  2.9G   xx   xx   x% /var/log
```

#### 7c. Mount the data volume

```bash
# Create the mount point
sudo mkdir -p /data

# Mount it
sudo mount /dev/lab-vg/lv-data /data

# Set ownership so applications can write to it
sudo chown ubuntu:ubuntu /data

# Verify
df -h /data
```

#### 7d. Make the mounts permanent with fstab

**This is the critical step.** Without fstab, your mounts disappear on reboot and the server boots with an empty `/var/log` — systemd services that write logs will either fail or write to the root volume again.

```bash
# First, get the UUIDs of the logical volumes
# We use UUIDs instead of device names because device names
# (/dev/xvdb, /dev/sdb) can change between reboots.
# UUIDs are stable identifiers assigned at filesystem creation.
sudo blkid /dev/lab-vg/lv-logs
# /dev/mapper/lab--vg-lv--logs: LABEL="lab-logs" UUID="xxxx-xxxx-xxxx" TYPE="ext4"

sudo blkid /dev/lab-vg/lv-data
# /dev/mapper/lab--vg-lv--data: LABEL="lab-data" UUID="yyyy-yyyy-yyyy" TYPE="ext4"

# Copy those UUIDs — you will need them below

# Backup fstab before editing (always do this)
sudo cp /etc/fstab /etc/fstab.backup

# Open fstab for editing
sudo nano /etc/fstab
```

**Add these two lines to the bottom of `/etc/fstab`:**

```
# Cloud Lab CFE-002 — LVM volumes
# Format: <device> <mountpoint> <fstype> <options> <dump> <pass>
UUID=b1f02827-5340-4c87-bf3a-079df20cd6c6  /var/log  ext4  defaults,nofail  0  2
UUID=393d48c1-2f7a-4082-aac2-dbd1601e67a3  /data     ext4  defaults,nofail  0  2
```

Replace `xxxx-xxxx-xxxx` and `yyyy-yyyy-yyyy` with your actual UUIDs.

> 💡 **Understanding fstab fields:**
> - `defaults` — standard mount options (rw, suid, dev, exec, auto, nouser, async)
> - `nofail` — **critical for cloud servers:** if the volume is missing at boot, continue booting anyway rather than dropping into emergency mode. Without this, if an EBS volume fails to attach, your server will be unbootable.
> - `0` (dump) — legacy backup field, always 0
> - `2` (pass) — filesystem check order: 1=root (checked first), 2=other (checked after root), 0=skip check

```bash
# Test your fstab without rebooting
# This unmounts and remounts everything in fstab
sudo umount /var/log /data
sudo mount -a

# If no errors, your fstab is correct
# Verify everything is mounted
df -h | grep -E "log|data"
```

#### 7e. Verify persistence across reboot

```bash
# The real test — reboot the server
sudo reboot

# Wait 60 seconds then reconnect
ssh -i ~/.ssh/canonical_lab_key ubuntu@$SERVER_IP

# Verify both mounts came back automatically
df -h
# Both /var/log and /data should be mounted on the LVM volumes

# Verify LVM is intact
sudo lvs
sudo vgs
```

---

### STEP 8: Write the Disk Monitoring Script

**What we are doing:** We write a Bash script that checks disk usage across all mounted filesystems and logs a warning if any volume exceeds a threshold. This script will be run by a systemd timer every 5 minutes.

```bash
# Create the scripts directory
sudo mkdir -p /usr/local/lib/canonical-monitoring

# Create the monitoring script
sudo tee /usr/local/lib/canonical-monitoring/disk-monitor.sh << 'SCRIPT'
#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# disk-monitor.sh
# Checks disk usage on all mounted filesystems.
# Logs warnings to systemd journal (stdout is captured by journald
# when run via a systemd service/timer).
# ─────────────────────────────────────────────────────────────────

# Threshold: warn if usage exceeds this percentage
WARN_THRESHOLD=80
CRIT_THRESHOLD=90

# Timestamp for log readability
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

# Track if we found any issues
ISSUES_FOUND=0

echo "[$TIMESTAMP] disk-monitor: starting check on $HOSTNAME"

# Read df output line by line
# -h flag omitted so we get integers, not "4.5G" strings
# Skip the header line with tail -n +2
# Skip tmpfs (memory filesystems) and devtmpfs (device filesystems)
while IFS= read -r line; do
    # Parse fields from df output
    # df columns: Filesystem  1K-blocks  Used  Available  Use%  Mounted-on
    filesystem=$(echo "$line" | awk '{print $1}')
    use_percent=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mountpoint=$(echo "$line" | awk '{print $6}')
    used_kb=$(echo "$line" | awk '{print $3}')
    avail_kb=$(echo "$line" | awk '{print $4}')

    # Convert to human-readable for the log message
    used_human=$(echo "$used_kb" | awk '{
        if ($1 > 1048576) printf "%.1fGB", $1/1048576
        else if ($1 > 1024) printf "%.1fMB", $1/1024
        else printf "%dKB", $1
    }')

    # Check against thresholds
    if [ "$use_percent" -ge "$CRIT_THRESHOLD" ] 2>/dev/null; then
        echo "[$TIMESTAMP] CRITICAL: $mountpoint ($filesystem) is ${use_percent}% full (used: $used_human)"
        ISSUES_FOUND=1
    elif [ "$use_percent" -ge "$WARN_THRESHOLD" ] 2>/dev/null; then
        echo "[$TIMESTAMP] WARNING: $mountpoint ($filesystem) is ${use_percent}% full (used: $used_human)"
        ISSUES_FOUND=1
    else
        echo "[$TIMESTAMP] OK: $mountpoint is ${use_percent}% full (used: $used_human)"
    fi

done < <(df -P | tail -n +2 | grep -v -E "^(tmpfs|devtmpfs|udev)")

# Log LVM volume group free space as additional context
if command -v vgs &> /dev/null; then
    VG_FREE=$(sudo vgs --noheadings --units g -o vg_free 2>/dev/null | tr -d ' ')
    if [ -n "$VG_FREE" ]; then
        echo "[$TIMESTAMP] INFO: LVM volume group lab-vg has ${VG_FREE} unallocated"
    fi
fi

if [ "$ISSUES_FOUND" -eq 0 ]; then
    echo "[$TIMESTAMP] disk-monitor: all filesystems healthy"
fi

echo "[$TIMESTAMP] disk-monitor: check complete"
SCRIPT

# Make it executable
sudo chmod +x /usr/local/lib/canonical-monitoring/disk-monitor.sh

# Test it manually before wiring it to systemd
sudo /usr/local/lib/canonical-monitoring/disk-monitor.sh
```

---

### STEP 9: Configure a systemd Timer

**What we are doing:** We create a systemd timer to run the monitoring script every 5 minutes. This is the modern alternative to cron on Ubuntu systems managed by systemd.

**Why systemd timer instead of cron?**

Cron is not integrated with systemd. If a cron job produces output, it either goes nowhere or gets emailed (which requires a mail server). If a cron job fails, there is no standard way to see why. A systemd timer runs a systemd service — meaning its output goes to journald, it integrates with `systemctl status`, and you can see its history with `journalctl`.

A systemd timer consists of two unit files: a `.service` file (what to run) and a `.timer` file (when to run it).

#### 9a. Create the service unit

```bash
sudo tee /etc/systemd/system/disk-monitor.service << 'EOF'
# disk-monitor.service
# This service runs the disk monitoring script once.
# It is NOT started directly — it is started BY the timer below.
# Think of it as the "what" — the timer is the "when".

[Unit]
Description=Disk usage monitor for Cloud-Field_Engineer Lab
Documentation=https://github.com/Nikiobilor/cloud-field-engineer-labs

[Service]
Type=oneshot
# oneshot: systemd considers the service "done" when the process exits
# This is correct for scripts that run and exit, not long-running daemons

ExecStart=/usr/local/lib/canonical-monitoring/disk-monitor.sh

# Run as root so we can read all filesystems and run vgs
User=root

# Log stdout and stderr to journald
StandardOutput=journal
StandardError=journal

# Add metadata tags to journal entries so we can filter them
SyslogIdentifier=disk-monitor
EOF
```

#### 9b. Create the timer unit

```bash
sudo tee /etc/systemd/system/disk-monitor.timer << 'EOF'
# disk-monitor.timer
# This timer triggers disk-monitor.service on a schedule.

[Unit]
Description=Run disk usage monitor every 5 minutes
# The timer requires its matching service to exist
Requires=disk-monitor.service

[Timer]
# OnBootSec: run this many seconds after boot
# (gives the system time to fully start before first check)
OnBootSec=120

# OnUnitActiveSec: run this often after the last run
OnUnitActiveSec=5min

# Accuracy: how precisely to honour the timer
# 1min means systemd has a 1-minute window to fire the timer
# This prevents "timer thundering herd" if many timers fire at once
AccuracySec=1min

# If the system was off when the timer should have fired,
# run it immediately on next boot (useful for monitoring)
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

#### 9c. Enable and start the timer

```bash
# Reload systemd to pick up both new unit files
sudo systemctl daemon-reload

# Enable and start the timer
sudo systemctl enable --now disk-monitor.timer

# Verify the timer is active
sudo systemctl status disk-monitor.timer
# Active: active (waiting)
# Trigger: Thu 2024-xx-xx 14:35:00 UTC; 4min 52s left

# List all active timers and when they last/next fired
sudo systemctl list-timers
# You should see disk-monitor.timer in the list

# Trigger it manually right now to test (don't wait 5 minutes)
sudo systemctl start disk-monitor.service

# View the output in the journal
sudo journalctl -u disk-monitor.service -n 30
# You should see the OK/WARNING/CRITICAL lines from the script
```

#### 9d. Follow the timer in real time

```bash
# Watch the journal for disk-monitor entries
sudo journalctl -f -t disk-monitor
# Leave this running — in 5 minutes you will see the timer fire automatically
# Press Ctrl+C to stop following
```

---

### STEP 10: Simulate a Disk Fill to Test Alerting

**What we are doing:** We deliberately fill the log volume to trigger the warning, verify the alert fires, then clean up. Never trust monitoring you have not tested.

```bash
# Check current usage
df -h /var/log

# Fill the log volume to ~85% using a test file
# dd creates a file of zeros: if=/dev/zero, of=output file, bs=block size
# We calculate 85% of 2.5GB = ~2.55GB, then subtract current usage
# This is approximate — adjust the count based on your df output

# First check how much free space exists
FREE_MB=$(df -m /var/log | awk 'NR==2{print $4}')
echo "Free space on /var/log: ${FREE_MB}MB"

# Fill to leave only ~400MB free
FILL_MB=$((FREE_MB - 400))
echo "Will write ${FILL_MB}MB test file"

sudo dd if=/dev/zero of=/var/log/test-fill.bin bs=1M count=$FILL_MB status=progress

# Trigger the monitor manually
sudo systemctl start disk-monitor.service

# View the warning
sudo journalctl -u disk-monitor.service -n 20
# You should see: WARNING: /var/log is XX% full

# Clean up the test file
sudo rm /var/log/test-fill.bin

# Confirm back to normal
sudo systemctl start disk-monitor.service
sudo journalctl -u disk-monitor.service -n 10
# Should show OK again
```

---

### STEP 11: Demonstrate LVM Flexibility — Extend a Volume Online

**What we are doing:** This is the whole point of LVM. We demonstrate that we can resize a logical volume without unmounting it, a capability that is impossible with traditional partitions.

```bash
# Check current state
df -h /var/log
sudo lvs

# Extend lv-logs by 500MB (taken from free space in the VG)
sudo lvextend -L +500M /dev/lab-vg/lv-logs

# The logical volume is now larger but the filesystem doesn't know yet
# We must tell ext4 to use the new space
sudo resize2fs /dev/lab-vg/lv-logs

# Verify — /var/log is now larger
df -h /var/log
# No unmount. No downtime. No reboot.
# This is the conversation you have with a client at 2am
# when their log volume is filling up.

sudo lvs
# lv-logs now shows 3GB (2.5GB + 500MB)
```

> 💡 **This is production gold.** A client's database volume is filling up at 3am. With traditional partitions, you face downtime. With LVM + EBS, you add a volume to the VG and extend the LV online. Most managed services like RDS do this for you invisibly, LVM is how bare-metal and self-managed Linux servers do the same thing.

---

### STEP 12: Write the Handover Document

```bash
cat > docs/HANDOVER-TICKET-002.md << 'EOF'
# HANDOVER DOCUMENT
## TICKET-002: Storage Architecture & Disk Monitoring
**Client:** RetailEdge Ltd
**Engineer:** Nkiruka Obilor
**Date:** 5/7/2026
**Status:** Resolved

---

## Problem Summary
Root volume was handling all filesystem I/O: application logs, data,
and OS activity competing on a single 8GB disk. A log spike at 2am
filled the disk to 95% causing application write errors.

## Solution Implemented

### Storage Layout
| Volume | Device | Size | Mount | Purpose |
|---|---|---|---|---|
| Root | /dev/xvda | 8GB | / | OS and application binaries |
| lv-logs | /dev/lab-vg/lv-logs | 2.5GB | /var/log | All system and application logs |
| lv-data | /dev/lab-vg/lv-data | ~6.5GB | /data | Application data directory |

### LVM Configuration
- Volume Group: `lab-vg` (spans /dev/xvdb + /dev/xvdc)
- Both volumes persistent in /etc/fstab using UUIDs with `nofail`
- LVM allows online expansion — add EBS volume to VG and extend LV without downtime

### Monitoring
- Script: `/usr/local/lib/canonical-monitoring/disk-monitor.sh`
- Runs every 5 minutes via systemd timer: `disk-monitor.timer`
- Logs to journald — view with: `journalctl -t disk-monitor`
- Warning threshold: 80% | Critical threshold: 90%

## Operational Runbook

### If /var/log fills up again
```bash
# Option 1: If VG has free space (check with: sudo vgs)
sudo lvextend -L +2G /dev/lab-vg/lv-logs
sudo resize2fs /dev/lab-vg/lv-logs

# Option 2: If VG is full, add a new EBS volume
# 1. Attach new EBS volume in AWS console or via Terraform
# 2. sudo pvcreate /dev/xvdd
# 3. sudo vgextend lab-vg /dev/xvdd
# 4. sudo lvextend -L +5G /dev/lab-vg/lv-logs
# 5. sudo resize2fs /dev/lab-vg/lv-logs
```

### View disk monitoring logs
```bash
journalctl -t disk-monitor --since "1 hour ago"
journalctl -t disk-monitor -f   # follow in real time
```

### Check LVM status
```bash
sudo pvs    # physical volumes
sudo vgs    # volume groups
sudo lvs    # logical volumes
```
EOF
```

---

### STEP 13: Commit and Clean Up

```bash
# Commit your work
cd /path/to/canonical-field-engineer-labs/
git add .
git commit -m "session-02: LVM storage setup, fstab persistence, systemd disk monitoring"
git push origin main

# Destroy AWS resources to avoid charges
cd session-02-storage-lvm/terraform/
terraform destroy
# Type 'yes'
