# HANDOVER DOCUMENT
## TICKET-003: App Crash Recovery, systemd Resilience & Alerting

**Client:** RetailEdge Ltd
**Engineer:** [Your Name]
**Date:** $(date +"%Y-%m-%d")
**Status:** Resolved — Monitoring period in progress

---

## Executive Summary

The application process had no crash recovery mechanism. When it exited
unexpectedly, it stayed down until manually restarted. There was no alerting,
no log retention across reboots, and no mechanism to prevent disk exhaustion
from log accumulation. All four gaps have been addressed in this engagement.

---

## Root Cause

The application was started by a manual script with no supervision. There was
no process manager watching it. When it exited (cause still under investigation
— see Findings below), no one was notified and no recovery attempt was made.

---

## Changes Made

| Component | Before | After |
|---|---|---|
| Process management | Manual start, no recovery | systemd service with Restart=on-failure |
| Restart rate limiting | None | Max 5 restarts per 300 seconds, then fails loudly |
| Log persistence | Lost on reboot | journald persistent, 500MB cap, 1 month retention |
| Log rotation | None | logrotate daily, 14 days history, compressed |
| Log forwarding | None | rsyslog forwarding to logs.example.com:514 (TCP) |
| Alerting | None | Slack notification within 5 minutes of service failure |
| Deployment | Manual SSH | GitHub Actions workflow on push to main |

---

## Files Created or Modified

| File | Purpose |
|---|---|
| `/etc/systemd/system/myapp.service` | Service definition and restart policy |
| `/etc/systemd/journald.conf` | Journal persistence and size limits |
| `/etc/logrotate.d/myapp` | Application log file rotation |
| `/etc/rsyslog.d/49-myapp.conf` | Log forwarding to central syslog |
| `/usr/local/bin/myapp-alert.sh` | Slack alerting script |
| Root crontab | Schedule for alerting script (every 5 minutes) |

---

## How to Roll Back All Changes

```bash
# Stop and disable the service
sudo systemctl stop myapp.service
sudo systemctl disable myapp.service
sudo rm /etc/systemd/system/myapp.service
sudo systemctl daemon-reload

# Restore default journald configuration
sudo sed -i 's/Storage=persistent/Storage=auto/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald

# Remove logrotate config
sudo rm /etc/logrotate.d/myapp

# Remove rsyslog forwarding
sudo rm /etc/rsyslog.d/49-myapp.conf
sudo systemctl restart rsyslog

# Remove alert script and cron entry
sudo rm /usr/local/bin/myapp-alert.sh
sudo crontab -l | grep -v 'myapp-alert' | sudo crontab -
```

---

## How to Check Service Health

```bash
# Current service status
sudo systemctl status myapp.service

# Live log stream
sudo journalctl -u myapp.service -f

# Logs from the previous boot (for crash investigation)
sudo journalctl -u myapp.service -b -1

# Check if any alerts have fired
sudo cat /var/log/myapp-alert.log
```

---

## Next Steps for the Support Team

1. Monitor Slack for alerts over the next 48 hours
2. If an alert fires, SSH in and run: `journalctl -u myapp.service -b -1 -p err`
   to see error-level logs from the crash
3. If the service hits the restart limit (5 restarts in 300s), run:
   `sudo systemctl reset-failed myapp.service && sudo systemctl start myapp.service`
4. Investigate the root cause of the nightly crash using the journal logs now
   being retained
5. Consider connecting the central syslog server to a log analysis platform
   (e.g. Grafana Loki, Datadog, or Papertrail) for searchable dashboards
