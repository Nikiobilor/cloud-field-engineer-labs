Cloud Field Engineer Lab Series | Session 1 of 32

---

## 🎫 The Ticket

```
TICKET ID:    CFE-001
PRIORITY:     High
ASSIGNED TO:  Cloud Field Engineer (You)
CLIENT:       RetailEdge Ltd — E-commerce platform, Lagos & London
ENVIRONMENT:  Ubuntu 22.04 LTS on AWS EC2

SUBJECT: Production web server showing high latency under load.
         Ops team cannot explain why. CTO wants a report within 48 hours.

DESCRIPTION:
Our Ubuntu 22.04 server starts lagging when traffic hits ~500 concurrent
users. CPU doesn't look maxed out but response times spike. We need
someone to investigate the OS-level configuration, identify bottlenecks,
apply safe tuning, and set up basic monitoring so we can see what's
happening in real time.

ACCEPTANCE CRITERIA:
- [ ] Server profiled with findings documented
- [ ] Kernel parameters tuned for a network-heavy workload
- [ ] System monitoring set up (visible metrics)
- [ ] Systemd service configured to keep monitoring agent running
- [ ] Handover README written for support team
```

---

## 🎯 Task Goal

By the end of this session you will have:
- Deployed an Ubuntu 22.04 EC2 instance using Terraform
- Profiled the OS using Linux tools (`htop`, `vmstat`, `ss`, `sysctl`)
- Applied kernel-level tuning for network performance
- Installed and configured a lightweight monitoring agent (`node_exporter`)
- Set up `node_exporter` as a systemd service
- Documented everything in a format you could hand off to a client


## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS (Free Tier)                       │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPC (10.0.0.0/16)                 │   │
│  │                                                     │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │           Public Subnet (10.0.1.0/24)        │   │   │
│  │  │                                              │   │   │
│  │  │   ┌────────────────────────────────────┐    │   │   │
│  │  │   │    EC2: Ubuntu 22.04 (t2.micro)    │    │   │   │
│  │  │   │                                    │    │   │   │
│  │  │   │  ┌──────────────────────────────┐  │    │   │   │
│  │  │   │  │  node_exporter (port 9100)   │  │    │   │   │
│  │  │   │  │  systemd service             │  │    │   │   │
│  │  │   │  └──────────────────────────────┘  │    │   │   │
│  │  │   │                                    │    │   │   │
│  │  │   │  Kernel Tuning Applied:            │    │   │   │
│  │  │   │  - net.core.somaxconn = 65535      │    │   │   │
│  │  │   │  - tcp_tw_reuse = 1                │    │   │   │
│  │  │   │  - vm.swappiness = 10              │    │   │   │
│  │  │   └────────────────────────────────────┘    │   │   │
│  │  │                                              │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  │                                                     │   │
│  │  Security Group:                                    │   │
│  │  - Port 22 (SSH) → Your IP only                    │   │
│  │  - Port 9100 (metrics) → Your IP only              │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
