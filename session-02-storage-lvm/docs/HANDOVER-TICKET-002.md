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
| lv-logs | /dev/lab-vg/lv-logs | 3.5GB | /var/log | All system and application logs |
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

# Option 2: If VG is full — add a new EBS volume
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
