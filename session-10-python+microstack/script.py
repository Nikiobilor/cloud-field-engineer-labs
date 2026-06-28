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
