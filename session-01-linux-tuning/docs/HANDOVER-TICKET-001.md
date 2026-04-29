# HANDOVER DOCUMENT
## TICKET-001: Ubuntu Server Performance Investigation & Tuning
**Client:** RetailEdge Ltd
**Engineer:** Nkiruka Obilor
**Date:** $(date)
**Status:** Resolved — Pending monitoring period

---

## Findings Summary

### Root Cause
The server's kernel networking parameters were at default values optimized for
development workloads, not production web traffic. Under load, the TCP connection
queue (`somaxconn`) was filling up, causing new connections to be silently dropped.

### Changes Made

| Parameter | Before | After | Impact |
|---|---|---|---|
| net.core.somaxconn | 4096 | 65535 | Prevents connection drops under load |
| net.ipv4.tcp_tw_reuse | 0 | 1 | Reduces port exhaustion |
| vm.swappiness | 60 | 10 | Keeps active data in RAM |
| node_exporter service | Not installed | Running on :9100 | Visibility into server health |

### Files Modified
- `/etc/sysctl.d/99-canonical-lab-tuning.conf` — kernel tuning parameters
- `/etc/systemd/system/node_exporter.service` — monitoring service unit

### How to Rollback
```bash
# Remove our tuning file
sudo rm /etc/sysctl.d/99-canonical-lab-tuning.conf
# Reload sysctl
sudo sysctl --system
# Stop monitoring if desired
sudo systemctl stop node_exporter
sudo systemctl disable node_exporter

```

## Monitoring Access
Metrics available at: http://SERVER_IP:9100/metrics
Recommended: Connect this to Prometheus + Grafana for dashboards.

## Next Steps for Support Team
1. Monitor server performance over 48 hours under normal load
2. If latency issues persist, escalate to Session 2 (storage investigation)
3. Consider setting up Prometheus + Grafana for visualization
