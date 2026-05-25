# HANDOVER DOCUMENT
## TICKET-004: Network Diagnostics, Firewall Configuration & Connectivity Restoration

**Client:** RetailEdge Ltd
**Engineer:** [Your Name]
**Date:** [Date]
**Status:** Resolved — 48-hour monitoring period recommended

---

## Executive Summary

A junior engineer applied ad-hoc iptables commands that set the default INPUT
chain policy to DROP without adding corresponding ALLOW rules for HTTP and HTTPS.
All three application services (nginx on port 80, node_exporter on port 9100)
were reachable at the process level but silently dropped at the OS firewall level.
The application process (myapp) was healthy throughout — the failure was entirely
at the firewall layer.

Connectivity has been fully restored. The firewall has been rebuilt from scratch
using ufw with documented rules, committed to version control, and deployed via
GitHub Actions so future changes are reproducible and auditable.

---

## Diagnostic Evidence

Collected before any changes were made:

- `ss -tulpn` output confirmed all services (nginx, myapp, node_exporter, sshd)
  were listening on the correct ports. Application processes were healthy.
- `tcpdump` on port 80 confirmed SYN packets arriving from clients but no SYN-ACK
  being sent — signature of an iptables DROP rule (not a REJECT or process fault).
- `iptables -L -v -n` confirmed: Chain INPUT default policy was DROP. No rules
  existed for ports 80, 443, or 9100. Three rules existed (SSH, ESTABLISHED, lo).
- Broken state saved to /tmp/iptables-broken-state.txt on the server.

---

## Root Cause

The following iptables command was run without prior planning:
    iptables -P INPUT DROP

This sets the default policy for all unmatched input packets to DROP.
Without corresponding ALLOW rules for ports 80, 443, and 9100, all
non-SSH traffic was silently discarded.

---

## Changes Made

| Component | Before | After |
|---|---|---|
| iptables INPUT default policy | DROP (misconfigured) | DENY via ufw (intentional, with explicit allows) |
| Port 80 (HTTP) | Blocked — no rule | ALLOW from anywhere |
| Port 443 (HTTPS) | Blocked — no rule | ALLOW from anywhere |
| Port 9100 (node_exporter) | Blocked — no rule | ALLOW from OPS_IP only |
| Loopback interface | Partially blocked | ALLOW all (nginx → myapp internal path) |
| SSH (port 22) | Allowed (existing rule) | ALLOW from anywhere (explicit ufw rule) |
| Firewall management | Mixed iptables + ufw | ufw only (single-tool policy enforced) |
| Config in version control | No | Yes — deployed via GitHub Actions |

---

## Current Firewall Rules

| Port | Protocol | Source | Reason |
|---|---|---|---|
| 22 | TCP | Anywhere | SSH access |
| 80 | TCP | Anywhere | HTTP — proxied to myapp via nginx |
| 443 | TCP | Anywhere | HTTPS — TLS termination via nginx (Session 6) |
| 9100 | TCP | OPS_IP only | node_exporter — ops team only |
| All | All | Loopback only | nginx to myapp internal communication |
| All (outbound) | All | Anywhere | Package updates, external APIs |

---

## Files Created

| Location | Purpose |
|---|---|
| /usr/local/bin/configure-firewall.sh | Idempotent firewall config script |
| .github/workflows/deploy-session4.yml | CI/CD deployment pipeline |

---

## How to Add Future Rules

Never use raw iptables on this server. Always use ufw:

    sudo ufw allow PORT/proto comment "reason for this rule"

After any manual change, update configure-firewall.sh in the GitHub repository
so the change is recorded and will be reapplied if the server is rebuilt.

---

## How to Roll Back

    sudo ufw disable
    # WARNING: removes all firewall rules. Only use in emergency.
    # To reapply: sudo /usr/local/bin/configure-firewall.sh YOUR_OPS_IP

---

## Support Team Diagnostic Commands

    sudo ufw status verbose              # Current firewall rules
    sudo tcpdump -i eth0 -n port 80      # Live traffic on port 80
    sudo ss -tulpn                       # All listening services
    sudo iptables -L INPUT -v -n         # Raw iptables INPUT chain
    curl -v http://127.0.0.1/            # Test nginx → myapp internal path
