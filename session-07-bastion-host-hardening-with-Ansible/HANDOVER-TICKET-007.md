# Handover Document — TICKET-007
## Bastion Host Security Hardening

**Date:** $(date +"%Y-%m-%d")
**Engineer:** [Your name]
**Client:** RetailEdge Ltd
**Environment:** Ubuntu 22.04 — EC2 (eu-west-1)
**Ticket:** TICKET-007

---

## Summary

Implemented a three-layer hardening baseline on the RetailEdge bastion host,
delivered as an idempotent Ansible playbook. All changes are version-controlled
and reproducible.

---

## Root Cause (Pre-Hardening State)

The instance was running with default OpenSSH settings:
- `PermitRootLogin yes` — root accessible directly over SSH
- `PasswordAuthentication yes` — password brute-force possible
- No failed-login rate limiting (fail2ban absent)
- No privileged command auditing (auditd absent)
- No authentication file integrity monitoring

This configuration would fail a PCI-DSS assessment under requirements 2.2
(system configuration standards), 8.3 (authentication controls), and 10.2
(audit log requirements).

---

## Changes Made

### 1. SSH Daemon Hardening (CIS Ubuntu 22.04 Benchmark)

| Setting | Before | After |
|---|---|---|
| PermitRootLogin | yes | no |
| PasswordAuthentication | yes | no |
| MaxAuthTries | default (6) | 4 |
| LoginGraceTime | default (120s) | 60s |
| Idle timeout | none | 10 minutes (300s × 2) |
| AllowUsers | not set (any user) | ubuntu only |
| Ciphers | default (includes weak) | aes256-gcm, chacha20-poly1305, aes128-gcm |
| MACs | default (includes sha1) | sha2-512-etm, sha2-256-etm |
| AllowTcpForwarding | yes | no |
| X11Forwarding | yes | no |

### 2. fail2ban (Brute-Force Intrusion Prevention)

Installed and configured to monitor SSH authentication failures:
- Ban threshold: 5 failures within 10 minutes
- Ban duration: 1 hour
- Backend: systemd journal (correct for Ubuntu 22.04)
- Ban action: ufw (integrates with existing firewall)

### 3. auditd (Privileged Command and File Integrity Auditing)

Installed with a CIS-aligned ruleset covering:
- Login and logout events
- Authentication file integrity (/etc/passwd, /etc/shadow, /etc/group)
- SSH configuration integrity (/etc/ssh/sshd_config)
- Sudo and privilege escalation
- Privileged command execution (setuid/setgid, euid=0 execve)
- Network configuration changes
- Kernel module load/unload
- File deletion by non-root users
- Configuration locked immutable at boot (-e 2)

---

## Files Modified / Created

| Path | Action | Description |
|---|---|---|
| /etc/ssh/sshd_config | Modified | Hardened SSH daemon configuration |
| /etc/ssh/banner | Created | Pre-authentication warning banner |
| /etc/fail2ban/jail.local | Created | fail2ban SSH jail configuration |
| /etc/audit/auditd.conf | Modified | Audit daemon log rotation settings |
| /etc/audit/rules.d/99-retailedge-hardening.rules | Created | CIS-aligned audit ruleset |
| ~/retailedge-hardening/ | Created | Ansible playbook repository |

---

## Rollback Instructions

**SSH config rollback** (only if engineer is locked out):
```bash
# From AWS Session Manager or EC2 Instance Connect (does not require SSH)
sudo cp /etc/ssh/sshd_config.orig /etc/ssh/sshd_config
sudo systemctl restart sshd
```

**fail2ban — unban a specific IP:**
```bash
sudo fail2ban-client set sshd unbanip <IP_ADDRESS>
```

**auditd — remove custom rules:**
```bash
sudo rm /etc/audit/rules.d/99-retailedge-hardening.rules
sudo augenrules --load
```

**Full rollback via Ansible:**
```bash
# Delete the playbook changes and re-run bootstrap-session7.sh
# which restores the pre-hardening state
sudo bash bootstrap-session7.sh
```

---

## Verification Evidence

```bash
# SSH: confirm root login and password auth are disabled
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication'
# Expected: permitrootlogin no | passwordauthentication no

# fail2ban: confirm sshd jail is active
sudo fail2ban-client status sshd
# Expected: Status for the jail: sshd / Currently banned: 0 / ...

# auditd: confirm rules are loaded
sudo auditctl -l | head -20
# Expected: list of rules from our 99-retailedge-hardening.rules file

# auditd: confirm it is listening for events
sudo ausearch -m USER_LOGIN --start today | tail -5
```

---

## Next Steps for Support Team

1. Mount `/var/log/audit` on a dedicated volume (reference: Session 5 LVM pattern)
   before audit logs can grow large enough to trigger `HALT` action.
2. Configure a Slack or PagerDuty alert when fail2ban bans exceed 10 per hour
   (potential coordinated attack).
3. Ship auditd logs to a centralised SIEM (Elastic, Splunk) for retention beyond
   this host's lifecycle — required for PCI-DSS audit trail requirements.
4. Schedule quarterly review of AllowUsers list as team membership changes.
5. Consider adding a second SSH key as backup before disabling password auth
   in a production environment.
