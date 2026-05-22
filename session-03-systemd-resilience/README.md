# TICKET-003 — Session 3: App Crash Recovery, systemd Resilience & Alerting

> **Cloud CFE Training Series** | Session 3 of 32 | `CFE-003`
> **Scenario:** A client's application crashes every night. No one is paged. No one knows until morning. You are fixing that today.

---

## The Ticket

```
TICKET ID:    CFE-003
PRIORITY:     Critical
ASSIGNED TO:  Cloud Field Engineer (You)
CLIENT:       RetailEdge Ltd — E-commerce platform, Lagos & London
ENVIRONMENT:  Ubuntu 22.04 LTS on AWS EC2

SUBJECT: Production application crashes nightly. No alerting in place.
         Support team only finds out when customers complain at 8am.

DESCRIPTION:
Our application process exits unexpectedly sometime between midnight and
3am every night. The ops team restarts it manually each morning. There is
no alerting, no automatic recovery, and logs are not being retained beyond
the current session. We need the process to restart itself, logs to be
preserved and rotated, and someone to be notified immediately when it goes
down, not eight hours later.

ACCEPTANCE CRITERIA:
- [ ] App managed as a systemd service with auto-restart on failure
- [ ] journald configured to persist logs across reboots
- [ ] logrotate configured for application log files
- [ ] rsyslog forwarding logs to a central destination
- [ ] Alerting script notifies Slack within 5 minutes of a crash
- [ ] Everything deployed via GitHub Actions to AWS EC2
- [ ] Handover README written for the support team
```

---

## Session Goals

By the end of this session you will have:

- Written a production-grade systemd service unit file with restart policies
- Configured journald to persist logs across reboots with size limits
- Set up logrotate to manage application log files
- Configured rsyslog to forward application logs to a remote syslog server
- Written a cron-driven alerting script that fires to Slack on service failure
- Deployed all configuration to EC2 using a GitHub Actions workflow
- Written a client-facing handover document

This is one of the most common field engineer engagements in production Linux support. Every skill in this session transfers directly to any Linux server running any application.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites & What You Need](#prerequisites--what-you-need)
3. [Phase 0 — Pre-flight: Prepare Your EC2 Instance](#phase-0--pre-flight-prepare-your-ec2-instance)
4. [Phase 1 — Create a Dummy App](#phase-1--create-a-dummy-app)
5. [Step 1 — Create the systemd Service Unit](#step-1--create-the-systemd-service-unit)
6. [Step 2 — Configure Auto-Restart Behaviour](#step-2--configure-auto-restart-behaviour)
7. [Step 3 — Configure journald Log Persistence](#step-3--configure-journald-log-persistence)
8. [Step 4 — Configure logrotate](#step-4--configure-logrotate)
9. [Step 5 — Configure rsyslog Forwarding](#step-5--configure-rsyslog-forwarding)
10. [Step 6 — Create the Alerting Cron Job](#step-6--create-the-alerting-cron-job)
11. [Step 7 — Deploy via GitHub Actions to AWS EC2](#step-7--deploy-via-github-actions-to-aws-ec2)
12. [Step 8 — Write the Handover Document](#step-8--write-the-handover-document)
13. [Step 9 — Commit Your Work to GitHub](#step-9--commit-your-work-to-github)
14. [Verification Checklist](#verification-checklist)
15. [Troubleshooting Reference](#troubleshooting-reference)
16. [What You Learned This Session](#what-you-learned-this-session)
17. [Go Deeper](#go-deeper)
18. [Next Session](#next-session)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Developer Workstation                                           │
│                                                                 │
│  git push → main branch                                         │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  GitHub                                                          │
│                                                                 │
│  ┌──────────────────────────────────────────┐                   │
│  │  GitHub Actions: deploy-session3.yml     │                   │
│  │  Triggered on push to main               │                   │
│  │  Uses: EC2_HOST, EC2_USER, EC2_SSH_KEY,  │                   │
│  │        SLACK_WEBHOOK_URL (Secrets)       │                   │
│  └──────────────────┬───────────────────────┘                   │
└─────────────────────┼───────────────────────────────────────────┘
                      │ SSH + SCP
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│  AWS EC2 — Ubuntu 22.04                                          │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  systemd                                                 │   │
│  │  ├── myapp.service (manages the process)                 │   │
│  │  │   ├── Restart=on-failure                              │   │
│  │  │   ├── StartLimitBurst=5 / 300s window                 │   │
│  │  │   └── stdout/stderr → journald                        │   │
│  │  └── systemd-journald                                    │   │
│  │      └── /var/log/journal/ (persistent, 500MB cap)       │   │
│  │                                                          │   │
│  │  ┌────────────────────────────────────────────────────┐  │   │
│  │  │  myapp process (/opt/myapp/app)                    │  │   │
│  │  │  writes to → /var/log/myapp/*.log                  │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  │                                                          │   │
│  │  logrotate (daily, 14 rotations, compress)               │   │
│  │  └── /var/log/myapp/*.log                                │   │
│  │                                                          │   │
│  │  rsyslog                                                 │   │
│  │  └── Forwards myapp logs → logs.example.com:514 (TCP)    │   │
│  │                                                          │   │
│  │  cron (every 5 minutes)                                  │   │
│  │  └── /usr/local/bin/myapp-alert.sh                       │   │
│  │      └── if service not active → POST to Slack webhook   │   │
│  └─────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────┬──────────────────────┘
                                           │
                    ┌──────────────────────┼──────────────────────┐
                    ▼                      ▼                      ▼
             Slack alert            Remote syslog          journald logs
             (webhook)         (logs.example.com)     (local, persistent)

Security Group:
  - Port 22 (SSH) → Your IP only
```

**Why this architecture matters:** This session teaches defence in depth for process reliability. systemd handles the first line of defence, automatic restart. journald ensures you have logs to diagnose the crash after the fact. logrotate prevents the disk from filling with logs over time. rsyslog sends logs off the box so they survive even if the instance is terminated. The cron alerting catches the case where systemd gives up retrying and the service enters a failed state, which would otherwise go unnoticed until morning.

---

## Prerequisites & What You Need

### Minimum starting point

| Requirement | Notes |
|---|---|
| AWS EC2 instance running Ubuntu 22.04 LTS | A fresh `t2.micro` or `t3.micro` is sufficient |
| SSH access with a `.pem` key pair | Keep this safe, you will add it as a GitHub Secret |
| GitHub account with a repository | Free account is fine; Actions is included |
| Slack workspace | Free tier works; you just need to create an incoming webhook |

### No application? No problem.

The lab requires an app binary at `/opt/myapp/app`. If you do not have a real application, **Phase 1 below walks you through creating a dummy app**  a shell script that behaves like a real long-running process: it logs output, runs for a random duration, then exits with code 1 (simulating a crash). This lets you exercise every part of the lab including real auto-restarts and real Slack alerts.

### Remote syslog server for rsyslog (Step 5)

The lab forwards logs to a central syslog server. You have two practical options:

- **Option A — Papertrail (recommended):** Sign up free at [papertrailapp.com](https://papertrailapp.com). It gives you a real hostname:port in under 2 minutes and lets you see your forwarded logs in a web UI.
- **Option B — Loopback (lab-only):** Forward to `127.0.0.1:514` to validate the config works without a remote server. Logs loop back to the local rsyslog instance.

---

## Phase 0 — Pre-flight: Prepare Your EC2 Instance

SSH into your instance:

```bash
ssh -i /path/to/your-key.pem ubuntu@<YOUR_EC2_PUBLIC_IP>
```

Update the system and install the required tools:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl rsyslog
```

Verify rsyslog is running:

```bash
sudo systemctl status rsyslog
# Expected: active (running)
```

---

## Phase 1 — Create a Dummy App

> **Skip this phase if you already have a real application binary at `/opt/myapp/app`.** If you do, ensure the `User=` and `Group=` in the systemd unit match the user that owns your binary, and that your app writes logs to `/var/log/myapp/`.

This dummy app is a shell script that simulates a production process. It writes timestamped log entries every 10 seconds, then exits with code 1 after a random interval, triggering the exact crash-and-restart cycle you are here to manage.

### 1a. Create the directory structure and system user

```bash
# Application binary and config directories
sudo mkdir -p /opt/myapp
sudo mkdir -p /etc/myapp
sudo mkdir -p /var/log/myapp

# Create a dedicated non-root system user for the app.
# --system: no login shell, no home directory created by default
# --no-create-home: do not create /home/myappuser
# --shell /bin/false: this account cannot be used to log in interactively
sudo useradd --system --no-create-home --shell /bin/false myappuser

# Give the app user ownership of the log directory it will write to
sudo chown myappuser:myappuser /var/log/myapp
```

> **Why a dedicated system user?** Never run a service as `root`. If the application is compromised, an attacker operating as `root` owns the entire server. As `myappuser`, they can only access what that user can access, which is almost nothing. This is the principle of least privilege.

### 1b. Write the dummy app

```bash
sudo nano /opt/myapp/app
```

Paste the following:

```bash
#!/usr/bin/env bash
# /opt/myapp/app
#
# Simulated production application.
# Writes timestamped log entries every 10 seconds, then crashes with exit code 1
# after a random lifetime between 60 and 300 seconds.
#
# This lets you observe and test every component of the resilience stack:
#   - systemd auto-restart fires when exit code 1 is returned
#   - journald captures all stdout/stderr from this process
#   - logrotate manages the /var/log/myapp/app.log file this script writes
#   - The Slack alert fires if the service enters 'failed' state

LOG=/var/log/myapp/app.log

echo "[$(date '+%Y-%m-%dT%H:%M:%S')] myapp starting up (pid $$)" | tee -a "$LOG"

# Pick a random lifetime so crashes happen unpredictably, just like production
LIFETIME=$(( RANDOM % 240 + 60 ))
echo "[$(date '+%Y-%m-%dT%H:%M:%S')] myapp will run for ${LIFETIME}s then simulate a crash" | tee -a "$LOG"

END=$((SECONDS + LIFETIME))
while [ $SECONDS -lt $END ]; do
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] myapp is healthy (pid $$, ${SECONDS}s elapsed)" | tee -a "$LOG"
    sleep 10
done

echo "[$(date '+%Y-%m-%dT%H:%M:%S')] myapp CRASH, exiting with code 1" | tee -a "$LOG"
exit 1
```

Make it executable and set correct ownership:

```bash
sudo chmod +x /opt/myapp/app
sudo chown myappuser:myappuser /opt/myapp/app
```

Create the environment file referenced in the unit:

```bash
sudo touch /etc/myapp/myapp.env
# This file can hold KEY=VALUE environment variables for your app.
# It is intentionally empty for the dummy app.
```

---

## Step 1 — Create the systemd Service Unit

**What we are doing and why:** systemd is the init system and service manager on all modern Ubuntu, Debian, Red Hat, and SUSE servers. It is the first process the kernel starts (PID 1), and it is responsible for starting and managing every other process on the system. When a client says "my app keeps dying", the field engineer's first action is always to put that app under systemd management with a proper restart policy. Manual restarts by a human are never the answer in production.

Create the unit file:

```bash
sudo nano /etc/systemd/system/myapp.service
```

Paste the following, reading each comment carefully, this is the most important file in this session:

```ini
# /etc/systemd/system/myapp.service
#
# A systemd unit file has three mandatory sections:
# [Unit]    — what this service is and what it depends on
# [Service] — how to run it, how to restart it, security constraints
# [Install] — when this service should start relative to the boot sequence

[Unit]
Description=My Client Application (RetailEdge Ltd)
Documentation=https://github.com/your-org/myapp
# After= means: do not start this service until these targets are reached.
# network-online.target means the system has a working network connection.
# Without this, an app that needs network might start and immediately fail.
After=network-online.target
Wants=network-online.target

[Service]
# Run as a dedicated non-root user — never run application services as root.
# If the application is compromised, the attacker gets only these permissions.
Type=simple
User=myappuser
Group=myappuser
WorkingDirectory=/opt/myapp

# The command that starts the application.
# Systemd needs the full absolute path — never rely on $PATH in unit files.
ExecStart=/opt/myapp/app

# Send a HUP signal when systemctl reload is called.
# Many apps use SIGHUP to reload configuration without restarting.
ExecReload=/bin/kill -HUP $MAINPID

# Where to send the application's stdout and stderr output.
# journal = send directly to journald (the systemd log system).
# This is the modern way — no log file path needed, logs go to the journal.
StandardOutput=journal
StandardError=journal

# SyslogIdentifier is the tag that appears in journal and rsyslog output.
# Set this to something recognisable — you will filter logs by this name.
SyslogIdentifier=myapp

# Load environment variables from this file if it exists.
# The leading dash (-) means: do not error if the file is missing.
EnvironmentFile=-/etc/myapp/myapp.env

# Restart policy — this is the core of crash recovery.
# on-failure = restart if the process exits with a non-zero code, or is killed
# by a signal. Does NOT restart if you run 'systemctl stop' manually.
Restart=on-failure

# How long to wait before each restart attempt.
# 10 seconds gives the system time to recover (release ports, flush state)
# before the app tries to come back up.
RestartSec=10s

# Rate limiting: if the service restarts more than 5 times in 300 seconds,
# systemd stops trying and marks the service as 'failed'.
# This prevents an app in a crash loop from thrashing the server.
# When this limit is hit, your alerting (Step 6) must catch it.
StartLimitInterval=300s
StartLimitBurst=5

[Install]
# WantedBy=multi-user.target: start this service when the system reaches
# normal operational state (networking up, no GUI, multi-user login available).
# This is the correct target for almost all server-side services.
WantedBy=multi-user.target
```

Enable and start the service:

```bash
# Tell systemd to scan for new and changed unit files.
# You must run this every time you create or modify a unit file.
# Without it, systemd still uses the old version it loaded at boot.
sudo systemctl daemon-reload

# Enable the service, creates the symlink that makes it start at boot.
# This does not start it yet; it only registers it for future boots.
sudo systemctl enable myapp.service

# Start the service immediately without waiting for a reboot
sudo systemctl start myapp.service

# Verify it is running
sudo systemctl status myapp.service
# Look for: Active: active (running)
# The status output also shows the PID, memory usage, and recent log lines.
```

> The distinction between `enable` and `start` trips up many engineers early in their careers. `enable` tells systemd "start this at boot" — it creates a symlink in the appropriate target directory. `start` tells systemd "start this right now". You almost always want both. If you only `enable`, the service starts after the next reboot but not now. If you only `start`, it runs now but dies on reboot.

---

## Step 2 — Configure Auto-Restart Behaviour

**What we are doing and why:** The restart directives in the unit file work as a system, not independently. Understanding how they interact is what allows you to tune reliably for production. The goal is: restart fast enough to minimise downtime, but slow enough that a recurring crash does not thrash the server, and give up loudly enough that alerting catches it.

| Directive | Value | What it does |
|---|---|---|
| `Restart` | `on-failure` | Restart only if the process exits with a non-zero code or is killed by a signal. Does not restart on clean exit (exit code 0) or manual stop. |
| `RestartSec` | `10s` | Wait 10 seconds before each restart attempt. Prevents rapid crash loops. |
| `StartLimitInterval` | `300s` | The rolling time window in which restart attempts are counted. |
| `StartLimitBurst` | `5` | Maximum restart attempts within the window. After 5 failures in 300 seconds, systemd stops retrying and sets the service to `failed`. |

When the burst limit is hit, the service enters the `failed` state. It will not restart automatically. This is exactly when the alerting cron job in Step 6 must fire and wake someone up.

To manually reset a service that has hit its burst limit:

```bash
# Reset the failure counter so systemd will try again
sudo systemctl reset-failed myapp.service

# Start the service again
sudo systemctl start myapp.service
```

To test the restart behaviour deliberately:

```bash
# Find the process ID
systemctl show -p MainPID myapp.service

# Kill the process with SIGKILL — simulates a crash
sudo kill -9 $(systemctl show -p MainPID myapp.service | cut -d= -f2)

# Watch systemd restart it automatically
sleep 15
sudo systemctl status myapp.service
# Should show: active (running) again
```

> Why SIGKILL (-9) for the test? SIGKILL cannot be caught or ignored by the process, it is the most realistic simulation of a crash. SIGTERM (-15) allows the process to handle the signal and exit cleanly, which may not trigger the restart policy depending on the exit code.

---

## Step 3 — Configure journald Log Persistence

**What we are doing and why:** journald is the logging subsystem built into systemd. It receives log output from every service (via `StandardOutput=journal`), the kernel, and the boot process, and stores it in a structured binary format. By default on many Ubuntu installs, journald stores logs only in memory, they are lost on reboot. For a production server running an app that crashes at 2am, you need logs that survive the reboot.

### 3a. Make journal storage persistent

```bash
# Create the directory that signals to journald that persistent storage should be used.
# journald checks for this directory at startup. If it exists, logs go to disk.
# If it does not exist, logs go to /run/log/journal/ which is in-memory (tmpfs).
sudo mkdir -p /var/log/journal

# Apply the directory configuration immediately
sudo systemd-tmpfiles --create --prefix /var/log/journal

# Restart journald to pick up the new storage location
sudo systemctl restart systemd-journald
```

### 3b. Tune the journald configuration

```bash
sudo nano /etc/systemd/journald.conf
```

Replace the contents of the `[Journal]` section with:

```ini
[Journal]
# persistent = write logs to /var/log/journal/ (survives reboots)
# auto = use /var/log/journal/ if it exists, otherwise /run/log/journal/ (in-memory)
# volatile = always use /run/ (in-memory, lost on reboot)
# We want persistent.
Storage=persistent

# Compress log entries larger than a threshold.
# This significantly reduces disk usage for verbose applications.
Compress=yes

# Maximum total disk space the journal can use across all files.
# When this limit is reached, the oldest journal files are deleted.
SystemMaxUse=500M

# Minimum free disk space to maintain.
# journald will delete old logs before letting free space fall below this.
SystemKeepFree=100M

# Maximum size of a single journal file before it is rotated.
SystemMaxFileSize=50M

# How long to retain journal entries regardless of disk space.
# 1month = delete entries older than 30 days.
MaxRetentionSec=1month

# Forward a copy of every journal entry to rsyslog via the syslog socket.
# This is how rsyslog picks up systemd service logs for forwarding (Step 5).
ForwardToSyslog=yes
```

Apply the configuration:

```bash
sudo systemctl restart systemd-journald

# Verify that persistent storage is now active
ls /var/log/journal/
# You should see a directory named after the machine ID containing .journal files
```

### 3c. Essential journalctl commands you will use daily

```bash
# Follow the live log stream for your service (like tail -f but structured)
journalctl -u myapp.service -f

# Show the last 50 lines
journalctl -u myapp.service -n 50

# Show only error-level and above (emergency, alert, critical, error)
journalctl -u myapp.service -p err

# Show logs since a specific time
journalctl -u myapp.service --since "2 hours ago"
journalctl -u myapp.service --since "2024-01-15 02:00:00"

# Show logs between two times — useful for investigating a crash window
journalctl -u myapp.service --since "01:00" --until "03:00"

# Show logs from the previous boot — critical for crash investigations
journalctl -u myapp.service -b -1
# -b -1 = the boot before the current one
# -b -2 = two boots ago

# Show disk space used by the journal
journalctl --disk-usage
```

> `journalctl -b -1` is the most important command for investigating a crash that happened at 2am on a server that was rebooted at 3am. The current boot's logs start at 3am, the crash evidence is in the previous boot's logs. Without persistent storage configured in step 3a, this command returns nothing.

---

## Step 4 — Configure logrotate

**What we are doing and why:** Even though journald manages the journal, many applications also write directly to log files in `/var/log/myapp/`. Without rotation, these files grow indefinitely and will eventually fill the disk, a common cause of production outages. logrotate solves this by automatically compressing, archiving, and deleting old log files on a schedule.

### 4a. Create the logrotate configuration

```bash
sudo nano /etc/logrotate.d/myapp
```

```
/var/log/myapp/*.log {
    # Rotate once per day
    daily

    # Do not error if no log files match the glob
    missingok

    # Keep 14 rotated copies (14 days of history)
    rotate 14

    # Compress rotated files using gzip
    compress

    # Do not compress the most recently rotated file.
    # This gives the application time to close its file handle before compression.
    # Without this, an app still writing to a just-rotated file will write to a compressed file.
    delaycompress

    # Do not rotate if the log file is empty
    notifempty

    # Create a new empty log file after rotation with these permissions
    # 0640 = owner read/write, group read, others none
    create 0640 myappuser adm

    # Run the postrotate script once for all matched files, not once per file
    sharedscripts

    # After rotating, signal the application to close and reopen its log file handle.
    # Without this, the app continues writing to the old (now rotated) file descriptor.
    # HUP (SIGHUP) is the standard signal for "reload configuration / reopen log files".
    postrotate
        systemctl kill -s HUP myapp.service 2>/dev/null || true
    endscript
}
```

> Why is the `postrotate` block necessary? When logrotate renames `app.log` to `app.log.1`, the application still has an open file descriptor pointing to the renamed file. It will keep writing to `app.log.1` even though logrotate created a fresh `app.log`. The `postrotate` sends a HUP signal, which tells the application "reopen your log file". The app then opens the new `app.log`. The `|| true` at the end prevents the script from failing if the service is down during rotation.

### 4b. Test and verify the configuration

```bash
# Dry run, shows what logrotate WOULD do without actually doing it.
# Always run this first to catch configuration errors.
sudo logrotate --debug /etc/logrotate.d/myapp

# Force a rotation right now to validate the full process works
sudo logrotate --force /etc/logrotate.d/myapp

# Confirm the rotation happened
ls -la /var/log/myapp/
# You should see app.log (new empty file) and app.log.1 (or app.log.1.gz)
```

logrotate is called automatically by the system cron at `/etc/cron.daily/logrotate`. You do not need to add a separate cron entry, it runs daily as part of the standard Linux maintenance schedule.

---

## Step 5 — Configure rsyslog Forwarding

**What we are doing and why:** Logs stored only on the server are a single point of failure. If the instance is terminated, corrupted, or the disk fails, the logs are gone. rsyslog forwards a copy of every log entry off the box to a central syslog server in real time. This is also how teams feed logs into SIEM systems, log aggregation platforms like Papertrail or Datadog, or their own ELK stack.

> **Choosing a remote syslog target:**
> - **Papertrail (recommended for this lab):** Go to [papertrailapp.com](https://papertrailapp.com), create a free account, and add a system. Papertrail gives you a hostname like `logs2.papertrailapp.com` and a port like `12345`. Use those below.
> - **Loopback (no remote server):** Replace `logs.example.com` with `127.0.0.1` and port `514`. This validates the config without requiring a remote server.

### 5a. Create the rsyslog forwarding rule

```bash
sudo nano /etc/rsyslog.d/49-myapp.conf
```

```
# /etc/rsyslog.d/49-myapp.conf
# Forward myapp logs to a central syslog server.
#
# rsyslog processes config files in /etc/rsyslog.d/ in filename order.
# We use 49- so this runs before the default rules (50-default.conf).
# This ensures we catch the messages before anything else acts on them.

# Match log entries where the program name is 'myapp'.
# $programname matches the SyslogIdentifier field we set in the unit file.
if $programname == 'myapp' then {
    # omfwd = output module for forwarding (UDP or TCP)
    action(
        type="omfwd"
        target="127.0.0.1"   # Replace with your syslog server hostname or IP
        port="514"                  # Replace with your syslog server port
        protocol="tcp"              # TCP = reliable delivery (use UDP only if required)
        template="RSYSLOG_SyslogProtocol23Format"  # RFC 5424 format — most compatible
    )
    # stop = do not pass this message to any further rules.
    # Without this, the message would also be written to /var/log/syslog locally.
    stop
}
```

> Why TCP and not UDP? Syslog historically used UDP because it is simple and low overhead. However, UDP is fire-and-forget — if the network drops a packet, the log entry is silently lost. In production, use TCP so the sender knows if the message was not delivered. The performance difference is negligible for log volumes.

```bash
# Validate the rsyslog configuration syntax before restarting
sudo rsyslogd -N1
# -N1 = validate configuration and exit. No output = no errors.

# Apply the new configuration
sudo systemctl restart rsyslog

# Verify rsyslog is running
sudo systemctl status rsyslog
```

### 5b. Test that forwarding is working

```bash
# The logger command injects a test message into syslog with a specific tag.
# -t myapp makes the message appear to come from the 'myapp' program.
logger -t myapp "rsyslog forwarding test from $(hostname) at $(date)"

# If using Papertrail, the message should appear in your Papertrail dashboard within seconds.
# If using loopback (127.0.0.1), check the local syslog:
sudo grep myapp /var/log/syslog | tail -5
```

---

## Step 6 — Create the Alerting Cron Job

**What we are doing and why:** systemd's `StartLimitBurst` protects against crash loops, but when it gives up, the service sits in a `failed` state silently. The cron alerting script is the safety net: it runs every 5 minutes, checks whether the service is active, and fires a Slack notification if not. This closes the most dangerous gap in the reliability stack, the scenario where the application is down and nobody knows.

### 6a. Get a Slack Webhook URL

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App → From scratch**
2. Name it `RetailEdge Alerts`, select your workspace, click **Create App**
3. Under **Add features and functionality**, click **Incoming Webhooks**
4. Toggle **Activate Incoming Webhooks** to On
5. Click **Add New Webhook to Workspace**, choose a channel (e.g. `#alerts`), click **Allow**
6. Copy the webhook URL — it looks like `https://hooks.slack.com/services/T.../B.../...`

### 6b. Create the alert script

```bash
sudo nano /usr/local/bin/myapp-alert.sh
```

```bash
#!/usr/bin/env bash
# /usr/local/bin/myapp-alert.sh
#
# Checks the health of myapp.service and fires a Slack alert if it is not active.
# Designed to be called by cron every 5 minutes.
#
# Dependencies: curl, systemctl, journalctl
# Environment variables required:
#   SLACK_WEBHOOK_URL — Slack incoming webhook URL

set -euo pipefail
# set -e: exit immediately if any command returns a non-zero exit code
# set -u: treat unset variables as errors, prevents silent bugs
# set -o pipefail: a pipeline fails if any command in it fails, not just the last one

SERVICE="myapp.service"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-INPUT SLACK WEBHOOK URL}"  # Read from environment, empty string if not set
HOSTNAME=$(hostname -f)                 # Fully qualified hostname for the alert message

# Check the current state of the service.
# systemctl is-active returns 'active', 'inactive', 'failed', 'activating', etc.
# The '|| true' prevents the script from exiting if the command returns non-zero
# (which it does when the service is not active).
STATE=$(systemctl is-active "$SERVICE" 2>/dev/null || true)

# Only alert if the service is not running
if [[ "$STATE" != "active" ]]; then

    # Collect the last 20 log lines to include in the alert.
    # This gives the on-call engineer immediate context without needing to SSH in.
    # --no-pager prevents journalctl from opening an interactive pager
    JOURNAL=$(journalctl -u "$SERVICE" -n 20 --no-pager 2>&1)

    # Build the Slack message.
    # Backtick formatting in Slack renders as monospace code blocks.
    MESSAGE="*ALERT* \`${SERVICE}\` on \`${HOSTNAME}\` is *${STATE}*.\n\`\`\`${JOURNAL}\`\`\`"

    # Only try to send the Slack alert if the webhook URL is configured
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"$MESSAGE\"}"
        # -s = silent mode (no progress bar)
    fi

    # Always write to a local alert log — this is the fallback if Slack is down
    echo "$(date --iso-8601=seconds) ALERT: $SERVICE is $STATE on $HOSTNAME" \
        >> /var/log/myapp-alert.log
fi

# If STATE is 'active', the script exits here silently.
# Cron jobs should produce no output when everything is healthy —
# cron emails the owner if the script produces any stdout/stderr.
```

```bash
# Make the script executable
sudo chmod +x /usr/local/bin/myapp-alert.sh
```

### 6c. Test the alert script manually

```bash
# Test while service is healthy — should produce NO output
  sudo  /usr/local/bin/myapp-alert.sh
# Silence = success

# Test while service is DOWN — should fire a Slack message
sudo systemctl stop myapp.service

  sudo /usr/local/bin/myapp-alert.sh
# Check your Slack channel — you should see the alert within seconds

# Bring the service back up
sudo systemctl start myapp.service
```

### 6d. Add the cron job

```bash
# Edit the root crontab
sudo crontab -e
```

Add this line at the bottom (replace the webhook URL with yours):

```
# Check myapp health every 5 minutes and alert Slack if it is not running
*/5 * * * * SLACK_WEBHOOK_URL=" INPUT SLACK WEBHOOK URL" /usr/local/bin/myapp-alert.sh
```

> Understanding the cron time expression `*/5 * * * *`: the five fields are minute, hour, day-of-month, month, day-of-week. A `*` means "every". `*/5` means "every 5th value" — so every 5 minutes. This runs at :00, :05, :10, :15... every hour, every day.

> Why does the cron entry set the environment variable inline? Cron runs in a minimal environment, it does not source `.bashrc`, `.profile`, or any shell configuration files. Variables set in your shell session are not available inside cron. The solution is to set the variable in the crontab line itself, as shown above.

---

## Step 7 — Deploy via GitHub Actions to AWS EC2

**What we are doing and why:** In the previous steps, we made changes directly on the server by SSHing in. That works for a lab, but in a professional engagement every change should be version-controlled and deployed consistently. GitHub Actions lets us commit config files to the repository and have them automatically deployed to the server on every push to main. This makes deployments repeatable, auditable, and reviewable by a teammate before they go out.

### 7a. Create the repository file structure

On your EC2 instance (or your local machine), create the project layout:

```bash
mkdir -p ~/cloud-field-engineer-labs
cd ~/cloud-field-engineer-labs
git init

mkdir -p session-03-systemd-resilience/infra/systemd
mkdir -p session-03-systemd-resilience/infra/logrotate
mkdir -p session-03-systemd-resilience/infra/rsyslog
mkdir -p session-03-systemd-resilience/scripts
mkdir -p session-03-systemd-resilience/docs
mkdir -p .github/workflows
```

Copy the config files you created on the server into the repo:

```bash
sudo cp /etc/systemd/system/myapp.service \
    session-03-systemd-resilience/infra/systemd/myapp.service

sudo cp /etc/logrotate.d/myapp \
    session-03-systemd-resilience/infra/logrotate/myapp

sudo cp /etc/rsyslog.d/49-myapp.conf \
    session-03-systemd-resilience/infra/rsyslog/49-myapp.conf

sudo cp /usr/local/bin/myapp-alert.sh \
    session-03-systemd-resilience/scripts/myapp-alert.sh

# Fix ownership so your ubuntu user can work with the files
sudo chown -R ubuntu:ubuntu session-03-systemd-resilience/
```

The final layout should look like this:

```
cloud-field-engineer-labs/
└── session-03-systemd-resilience/
    ├── infra/
    │   ├── systemd/
    │   │   └── myapp.service        ← the unit file from Step 1
    │   ├── logrotate/
    │   │   └── myapp                ← the logrotate config from Step 4
    │   └── rsyslog/
    │       └── 49-myapp.conf        ← the rsyslog config from Step 5
    ├── scripts/
    │   └── myapp-alert.sh           ← the alert script from Step 6
    └── docs/
        └── HANDOVER-TICKET-003.md   ← written in Step 8
```

### 7b. Store secrets in GitHub

Go to your repository on GitHub: **Settings → Secrets and variables → Actions → New repository secret**

Add each of the following:

| Secret name | Value |
|---|---|
| `EC2_HOST` | The public IP or DNS hostname of your EC2 instance |
| `EC2_USER` | `ubuntu` (the default user for Ubuntu AMIs on EC2) |
| `EC2_SSH_KEY` | The full contents of your private key `.pem` file |
| `SLACK_WEBHOOK_URL` | Your Slack incoming webhook URL |

> Why use GitHub Secrets and not values hardcoded in the workflow YAML? Secrets are encrypted at rest and are never printed in the Actions log output, even if you accidentally `echo` one. Values hardcoded in the workflow file are committed to the repository and visible to anyone with repository access. Never put credentials in code files.

### 7c. Create the GitHub Actions workflow

```bash
nano .github/workflows/deploy-session3.yml
```

```yaml
# .github/workflows/deploy-session3.yml
#
# This workflow deploys all Session 3 configuration files to the EC2 instance
# whenever changes are pushed to main that affect the session-03 directory.

name: Deploy Session 3 — systemd Resilience Config

on:
  push:
    branches:
      - main
    # Only run this workflow if files in these paths changed.
    # Prevents unnecessary deployments when other sessions are updated.
    paths:
      - 'session-03-systemd-resilience/**'
      - '.github/workflows/deploy-session3.yml'

jobs:
  deploy:
    name: Deploy config to EC2
    runs-on: ubuntu-latest

    steps:
      # Step 1: Check out the repository code onto the Actions runner.
      # Without this, the runner has no access to our config files.
      - name: Checkout repository
        uses: actions/checkout@v4

      # Step 2: Load the SSH private key into the runner's ssh-agent.
      # The ssh-agent holds the key in memory so subsequent SSH and SCP
      # commands can authenticate without manually specifying the key file.
      - name: Set up SSH agent
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.EC2_SSH_KEY }}

      # Step 3: Copy config files from the runner to the server.
      # SCP (Secure Copy Protocol) transfers files over SSH.
      # -o StrictHostKeyChecking=no: accept the server's host key without prompting.
      # We copy to /tmp/ first because we need sudo to write to /etc/ and /usr/local/.
      - name: Copy config files to EC2
        run: |
          scp -o StrictHostKeyChecking=no \
            session-03-systemd-resilience/infra/systemd/myapp.service \
            ${{ secrets.EC2_USER }}@${{ secrets.EC2_HOST }}:/tmp/myapp.service

          scp -o StrictHostKeyChecking=no \
            session-03-systemd-resilience/infra/logrotate/myapp \
            ${{ secrets.EC2_USER }}@${{ secrets.EC2_HOST }}:/tmp/logrotate-myapp

          scp -o StrictHostKeyChecking=no \
            session-03-systemd-resilience/infra/rsyslog/49-myapp.conf \
            ${{ secrets.EC2_USER }}@${{ secrets.EC2_HOST }}:/tmp/49-myapp.conf

          scp -o StrictHostKeyChecking=no \
            session-03-systemd-resilience/scripts/myapp-alert.sh \
            ${{ secrets.EC2_USER }}@${{ secrets.EC2_HOST }}:/tmp/myapp-alert.sh

      # Step 4: SSH into the server and apply all configuration.
      - name: Apply configuration on EC2
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key: ${{ secrets.EC2_SSH_KEY }}
          script: |
            set -e  # Exit immediately if any command fails

            # ── systemd unit ──────────────────────────────────────────
            sudo cp /tmp/myapp.service /etc/systemd/system/myapp.service
            sudo systemctl daemon-reload
            sudo systemctl enable myapp.service
            sudo systemctl restart myapp.service

            # ── logrotate ─────────────────────────────────────────────
            sudo cp /tmp/logrotate-myapp /etc/logrotate.d/myapp

            # ── rsyslog ───────────────────────────────────────────────
            sudo cp /tmp/49-myapp.conf /etc/rsyslog.d/49-myapp.conf
            sudo systemctl restart rsyslog

            # ── alert script ──────────────────────────────────────────
            sudo cp /tmp/myapp-alert.sh /usr/local/bin/myapp-alert.sh
            sudo chmod +x /usr/local/bin/myapp-alert.sh

            # ── cron entry ────────────────────────────────────────────
            # Add the cron job if it is not already present.
            # The subshell reads the existing crontab, strips any existing myapp-alert
            # line, appends the fresh line, and pipes the result back to crontab.
            CRON_LINE="*/5 * * * * SLACK_WEBHOOK_URL=${{ secrets.SLACK_WEBHOOK_URL }} /usr/local/bin/myapp-alert.sh"
            ( sudo crontab -l 2>/dev/null | grep -v 'myapp-alert'; echo "$CRON_LINE" ) | sudo crontab -

            echo "All configuration applied successfully."

      # Step 5: Verify the service came up correctly after all changes.
      # This is the deployment smoke test — if the service is not active,
      # the workflow fails and the team is notified via GitHub's built-in alerting.
      - name: Verify service is active
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key: ${{ secrets.EC2_SSH_KEY }}
          script: |
            systemctl is-active myapp.service \
              && echo "Service is active. Deployment successful." \
              || (echo "ERROR: Service is not active after deployment." && exit 1)
```

> Why split the deploy and verify into two separate SSH steps? If the apply step fails, the verify step still runs and gives a clear failure signal. Separating concerns in a workflow makes debugging much easier.

### 7d. Push to GitHub and watch the deployment

```bash
cd ~/cloud-field-engineer-labs

git config --global user.email "you@example.com"
git config --global user.name "Your Name"

git remote add origin https://github.com/YOUR_USERNAME/cloud-field-engineer-labs.git
git add .
git commit -m "session-03: systemd resilience, log rotation, and alerting for TICKET-003"
git branch -M main
git push -u origin main
```

Go to your repository on GitHub → **Actions** tab. You should see the workflow running. Watch the steps execute: checkout → SSH agent setup → copy files → apply config → verify service is active.

If the final step shows `Service is active. Deployment successful.` — your pipeline is working end to end.

---

## Step 8 — Write the Handover Document

**What we are doing and why:** At the end of every engagement, a Cloud Field Engineer produces a handover document. This is the professional record of the work: what was broken, what was changed, why, and what the support team needs to know going forward. A good handover document means the client never has to call you back to ask "what did you do to our server?".

```bash
cd session-03-systemd-resilience/docs/

cat > HANDOVER-TICKET-003.md << 'EOF'
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
no process manager watching it. When it exited (cause still under investigation, see Findings below), no one was notified and no recovery attempt was made.

---

## Changes Made

| Component | Before | After |
|---|---|---|
| Process management | Manual start, no recovery | systemd service with Restart=on-failure |
| Restart rate limiting | None | Max 5 restarts per 300 seconds, then fails loudly |
| Log persistence | Lost on reboot | journald persistent, 500MB cap, 1 month retention |
| Log rotation | None | logrotate daily, 14 days history, compressed |
| Log forwarding | None | rsyslog forwarding to 127.0.0.1:514 (TCP) |
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
EOF
```

---

## Step 9 — Commit Your Work to GitHub

```bash
cd ~/cloud-field-engineer-labs/

git add session-03-systemd-resilience/

git commit -m "session-03: systemd resilience, log rotation, and alerting for TICKET-003

git push origin main
```

---

## Verification Checklist

Run these checks after deployment to confirm every component is working:

```bash
# 1. Service is running
systemctl is-active myapp.service
# Expected: active

# 2. Service is enabled for boot
systemctl is-enabled myapp.service
# Expected: enabled

# 3. Simulate a crash and verify auto-restart
sudo kill -9 $(systemctl show -p MainPID myapp.service | cut -d= -f2)
sleep 15
systemctl is-active myapp.service
# Expected: active (restarted automatically)

# 4. Journal storage is persistent (directory must exist)
ls /var/log/journal/
# Expected: a directory containing .journal files

# 5. logrotate configuration is valid
sudo logrotate --debug /etc/logrotate.d/myapp
# Expected: no errors, shows what would be rotated

# 6. rsyslog configuration is valid
sudo rsyslogd -N1
# Expected: no output (no errors)

# 7. rsyslog forwarding test (verify on your remote syslog server or local syslog)
logger -t myapp "connectivity test $(date)"

# 8. Alert script runs without error
sudo /usr/local/bin/myapp-alert.sh
# Expected: no output (service is healthy, script exits silently)

# 9. Cron job is registered
sudo crontab -l | grep myapp-alert
# Expected: the cron line you added

# 10. Alert fires correctly when service is stopped
sudo systemctl stop myapp.service
sudo SLACK_WEBHOOK_URL="your-url" /usr/local/bin/myapp-alert.sh
# Expected: Slack message received within seconds
sudo systemctl start myapp.service
```

---

## Troubleshooting Reference

| Symptom | Diagnostic command | Fix |
|---|---|---|
| Service stays in `failed` state | `systemctl status myapp.service` | Check `StartLimitBurst` was hit. Run `systemctl reset-failed myapp.service` then `start` |
| No journal logs after reboot | `ls /var/log/journal/` | Directory missing, re-run `mkdir -p /var/log/journal && systemctl restart systemd-journald` |
| logrotate does nothing | `logrotate --debug /etc/logrotate.d/myapp` | Check the glob path matches actual log file locations |
| rsyslog not forwarding | `rsyslogd -N1` | Syntax error in config — check the error output and fix the offending line |
| Alert script not firing | `bash -x /usr/local/bin/myapp-alert.sh` | `-x` traces every command, look for the failing line |
| Slack alert not arriving | Check `SLACK_WEBHOOK_URL` in crontab | Verify the URL is correct and the Slack app is still authorised |
| GitHub Actions SSH fails | Check the Actions run log | Confirm `EC2_SSH_KEY` secret contains the private key (not the public key) |
| Cron never runs | `sudo grep CRON /var/log/syslog` | Check cron is running: `systemctl status cron` |
| `myappuser` does not exist | `id myappuser` returns error | Re-run the `useradd` command from Phase 1 |
| `/var/log/myapp/` permission denied | `ls -la /var/log/myapp/` | Run `sudo chown myappuser:myappuser /var/log/myapp` |

---

## What You Learned This Session

**systemd service management in depth.** You wrote a unit file from scratch and understand every directive. You know the difference between `Restart=on-failure` and `Restart=always`, between `enable` and `start`, and between `StartLimitBurst` and `RestartSec`. This knowledge transfers to every Linux server you will ever work on.

**journald and log persistence.** You know why logs disappear on reboot by default, how to fix it, and how to use `journalctl -b -1` to investigate crashes in previous boot sessions. This single command has solved countless production mysteries.

**logrotate.** You understand why the `postrotate` HUP signal is necessary, what `delaycompress` protects against, and how to test a config without causing damage. Disk-full incidents caused by unmanaged logs are extremely common, you now know how to prevent them.

**rsyslog forwarding.** You configured log shipping off the box over TCP, understanding why reliable delivery matters. You know where rsyslog's config drop-in directory is and how rule ordering works.

**Cron for operational scripting.** You understand the time expression syntax, why environment variables must be set inline in crontab, and why cron scripts should be silent on success. These patterns apply to every scheduled task you will write.

**GitHub Actions for infrastructure deployment.** You built a workflow that automatically copies config files to a server on push and verifies the deployment succeeded. This is the baseline for all CI/CD in infrastructure work.

---

## Go Deeper

- Read `man systemd.service` fully — pay attention to the `[Service]` section and all `Restart=` options
- What is `Type=forking` and when would you use it instead of `Type=simple`?
- Read the rsyslog documentation on message queues — what happens to logs if the remote syslog server is temporarily unreachable?
- Investigate `systemd-analyze blame` — which service is slowest to start on your server?
- Read about `journald` rate limiting: what happens if an application writes 10,000 log lines per second?
- Brendan Gregg's USE Method for performance analysis: [http://www.brendangregg.com/usemethod.html](http://www.brendangregg.com/usemethod.html)

---


*Cloud CFE Training Series — Session 3 | TICKET-003*

