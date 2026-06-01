# HANDOVER DOCUMENT
## TICKET-005: Storage Under Pressure — Full-Disk Recovery & LVM Configuration

**Client:** RetailEdge Ltd
**Engineer:** [Your Name]
**Date:** [Date]
**Status:** Resolved — 48-hour observation period recommended

---

## Executive Summary

The 8GB root EBS volume reached 100% capacity, causing application write
failures and database halts. Three contributing factors combined: unrotated
myapp logs (logrotate had no maxsize limit), journal files that had grown
beyond the configured limit, and uncleared application temp files. The root
volume was expanded to 20GB online without downtime. The myapp log directory
was isolated onto a dedicated 4GB LVM volume so log growth can never fill the
root filesystem again. Disk alerting now fires to Slack at 80% threshold.

---

## Root Cause Analysis

1. logrotate had no maxsize directive — a single verbose log file grew to 3.2GB
   between daily rotation cycles without triggering rotation.
2. journald vacuum had not been enforced since the 500MB limit was configured
   in Session 3 — the journal had grown to 1.8GB.
3. No disk usage alerting existed — the disk reached 100% with no notification.

---

## Changes Made

| Component | Before | After |
|---|---|---|
| EBS root volume | 8GB | 20GB (expanded online, no reboot) |
| Root filesystem | 8GB ext4 on /dev/xvda1 | 20GB ext4, grown with growpart + resize2fs |
| /var/log/myapp | On root filesystem | Isolated 4GB LVM logical volume |
| LVM | Not configured | VG: retailedge-logs-vg, LV: logs (4GB on /dev/xvdb) |
| logrotate maxsize | Not set | 100MB per file |
| logrotate retention | 14 days | 7 days |
| Disk alerting | None | Slack alert at 80% threshold, every 5 minutes |
| ext4 reserved blocks | 5% (~400MB) | 1% (~200MB, freed 320MB) |

---

## Current Storage Layout

| Filesystem | Size | Mount Point | Purpose |
|---|---|---|---|
| /dev/xvda1 | 20GB | / | Root: OS, application, database |
| /dev/retailedge-logs-vg/logs | 4GB | /var/log/myapp | Isolated application logs |

---

## Files Created or Modified

| File | Change |
|---|---|
| /etc/fstab | Added LVM log volume mount (UUID-based) |
| /etc/fstab.backup.session5 | Backup of original fstab |
| /etc/logrotate.d/myapp | Added maxsize 100M, reduced rotation to 7 days |
| /usr/local/bin/disk-alert.sh | New disk usage monitoring script |
| Root crontab | Added disk-alert.sh at */5 * * * * |

---

## How to Expand Storage in Future

Log volume (/var/log/myapp) needs more space:
    sudo lvextend -L +2G /dev/retailedge-logs-vg/logs
    sudo resize2fs /dev/retailedge-logs-vg/logs
    df -h /var/log/myapp

Root filesystem (/) needs more space:
1. Expand EBS volume via AWS CLI: aws ec2 modify-volume --volume-id VOL_ID --size NEW_SIZE
2. Wait for completion: aws ec2 describe-volumes-modifications --volume-ids VOL_ID
3. Grow partition: sudo growpart /dev/xvda 1
4. Grow filesystem: sudo resize2fs /dev/xvda1

---

## Monitoring

Disk checked every 5 minutes via cron.
Alert fires to Slack when any real filesystem exceeds 80%.
Local alert log: /var/log/disk-alert.log

If an alert fires:
  1. df -h — identify which filesystem
  2. sudo du -h --max-depth=2 /var/log | sort -rh | head -20
  3. Logs: sudo logrotate --force /etc/logrotate.conf
  4. Journal: sudo journalctl --vacuum-size=200M
  5. Still full: expand the relevant volume using the runbook above

---

## Rollback Instructions

To remove LVM and return /var/log/myapp to the root filesystem:
    sudo rsync -av /var/log/myapp/ /var/log/myapp-from-lvm/
    sudo umount /var/log/myapp
    sudo sed -i '/retailedge-logs-vg/d' /etc/fstab
    sudo mv /var/log/myapp-from-lvm/* /var/log/myapp/
    # To destroy the LVM stack entirely (data loss — run above rsync first):
    # sudo lvremove /dev/retailedge-logs-vg/logs
    # sudo vgremove retailedge-logs-vg
    # sudo pvremove /dev/xvdb
