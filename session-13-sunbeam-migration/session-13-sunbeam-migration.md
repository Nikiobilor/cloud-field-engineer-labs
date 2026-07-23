# CFE Training Series — Session 13
## Rebuilding the Private Cloud on Sunbeam (Migrating Off MicroStack)

**Status:** Standalone session — full infra + teardown included. This session provisions its own fresh host and rebuilds every layer it needs, including MicroCeph. It has zero dependency on Session 12's infrastructure still existing.
**Recreates, using Session 12's configuration:** the single-node MicroCeph cluster with RBD block storage. This is a deliberate rebuild, not an assumption of persistence — see the note in Section 12 on why that distinction matters.
**What's changing conceptually:** The OpenStack control plane. Session 12 was built on MicroStack. MicroStack is now officially discontinued by Canonical. Sunbeam (the `openstack` snap) is the current Canonical-endorsed path, and it's what you'll be tested on and expected to operate in the field.

> **Revision note:** this session's infrastructure target has moved twice. It started on AWS EC2, hit an account-level vCPU service quota block (both `m5.xlarge` and `m5.2xlarge` were greyed out), and pivoted to a local WSL2 build. That pivot ran into its own wall — WSL2 showed `vmx` flags in `/proc/cpuinfo` but never exposed a working `/dev/kvm`, most likely because the Windows 11 host is on build 22000, past its update-support window and predating relevant Hyper-V nested-virtualization work. Rather than keep fighting that, the session is now back on AWS EC2 (`us-east-1`), accepting the same **QEMU software emulation** tradeoff there instead — a clean, isolated, one-command-teardown environment beats troubleshooting Windows/WSL2 quirks for the same underlying performance outcome. Two real Terraform errors surfaced during that AWS setup (an undeclared variable, a missing key pair) and are folded into the fixed configuration below and into the debugging scenarios in Section 11 — genuine troubleshooting, not hypothetical.

---

## 1. The engagement

> **Change Request: CR-2091**
> **Client:** Corvex Manufacturing — Private Cloud Platform Team
> **Requested by:** Daniel Okoro, Infrastructure Lead, Corvex Manufacturing
> **Priority:** High
> **CAB status:** Approved — ref CAB-2026-0714
> **Maintenance window:** Saturday 02:00–06:00 WAT
> **Access:** Time-boxed sudo on the target host, granted via Corvex's PAM tool for the duration of the window. Access auto-revokes at 06:00 whether or not the work is done — if you run over, you file an extension request, you don't just keep working.
>
> **Description:** Corvex's private cloud POC (built by a previous vendor on MicroStack) is now unsupported following Canonical's MicroStack retirement. Corvex's Q3 compliance audit flagged this as a blocking risk — an unsupported control plane fails their infrastructure attestation. We've been engaged to migrate the existing workload (Cinder-backed volumes on a MicroCeph cluster) onto Sunbeam before the audit re-check in three weeks.
>
> **Explicitly out of scope for this engagement:** MAAS-managed bare metal (Corvex's servers aren't MAAS-enrolled yet — that's a separate, later engagement). Charm authoring — we're operating Juju, not writing charms.

**Why this ticket is realistic, and why it matters for how you read it:** nobody hands a field engineer a blank slate. You inherit someone else's decisions (a previous vendor's MicroStack build), a compliance deadline that isn't about the technology at all, and a maintenance window that isn't negotiable. Part of the job is working inside those constraints, not just running commands.

---

## 2. Plain-English primers — read these before touching a terminal

**What was MicroStack, and why does it matter that it's gone?**
MicroStack was Canonical's original "OpenStack in a snap" — a fast way to get a single-node OpenStack cloud running for testing or small deployments. Canonical discontinued it. If a client's private cloud is still running on it, that client has an unsupported control plane with no upstream security patches — which is exactly the kind of thing a compliance audit flags.

**What is Sunbeam, and how is it different from MicroStack?**
Sunbeam is Canonical's current answer to the same problem — a snap-installable OpenStack distribution — but it's built on a fundamentally different foundation: it deploys and manages OpenStack services using **Juju**, the same tool Canonical uses for large production OpenStack deployments. MicroStack was a standalone, simplified installer. Sunbeam is a lightweight entry point into the same operational model you'd use at real scale. That's why Canonical is steering everyone toward it — what you learn on Sunbeam transfers to a production Juju-managed cloud; what you learned on MicroStack didn't.

**What is Juju, in one paragraph, and why do you need to know it now?**
Juju is an application/service orchestration tool — think of it as "deploy and wire together a whole distributed system as a set of coordinated units, instead of installing each service by hand." Juju has three ideas you need for this session: a **controller** (the brain that manages deployments), a **model** (a workspace holding a set of related deployed applications — Sunbeam runs its OpenStack services inside a Juju model), and **applications/units** (each OpenStack service — nova, cinder, keystone — is a Juju application; each running instance of it is a unit). You do **not** need to write charms (the packages that define how an application deploys) for this role. You need to be able to read `juju status`, understand what a model is, and know how to point Sunbeam's bootstrap at a controller. That's operational awareness, not charm development, and that's the line we're holding for this track.

**Does MicroCeph go away too?**
No, conceptually — this is an important distinction to hold onto. MicroCeph is your **storage backend**. Sunbeam is your **compute/control-plane orchestrator**. They're different layers, and only the orchestrator is changing. In this lab, though, both layers get rebuilt from scratch in this session, because each session provisions its own host and nothing carries over automatically. In a real client engagement this distinction matters a lot more than it seems: you would never destroy and rebuild a client's actual storage cluster just because you're changing the control plane — Session 12 and Session 13's storage layer would be the same physical, continuous cluster the whole way through. Here, you're rebuilding it identically so you get the reps on the commands, but the *decision* being made — "storage backend stays, control plane changes" — is the real-world one. Hold onto that distinction; it's flagged again in Section 12.

---

## 3. Architecture — what you're building

```
                        ┌─────────────────────────────┐
                        │   EC2 host (single node,     │
                        │   us-east-1)                 │
                        │                              │
                        │  ┌────────────────────────┐  │
                        │  │   Juju controller (LXD) │  │
                        │  └───────────┬────────────┘  │
                        │              │ manages         │
                        │  ┌───────────▼────────────┐  │
                        │  │  Sunbeam model:          │  │
                        │  │  keystone · nova · cinder│  │
                        │  │  neutron · glance ...    │  │
                        │  └───────────┬────────────┘  │
                        │              │ cinder-ceph backend
                        │  ┌───────────▼────────────┐  │
                        │  │  MicroCeph cluster       │  │
                        │  │  (rebuilt this session)  │  │
                        │  │  RBD pool: cinder-vols   │  │
                        │  └──────────────────────────┘  │
                        └──────────────────────────────┘
```

**Lab-vs-reality gap #1, flagged up front:** a real Sunbeam/OpenStack deployment targets MAAS-enrolled bare metal or, at minimum, hosts with real hardware virtualization support, because Nova needs to run actual VMs. A single EC2 instance can only nest virtualization on bare-metal instance types (`*.metal`), which are expensive. This lab runs on a standard instance with **QEMU software emulation** instead of KVM acceleration — Nova will work, but VM boot times and performance will be noticeably worse than production. This is a real, common constraint in the field too: you'll sometimes be handed hardware that wasn't specced correctly for what's being asked of it, and part of the job is recognizing that early and flagging it in writing, not silently working around it.

---

## 4. Block 1 — Terraform: provision the host

**What this does and why:** we need one EC2 instance sized to run Sunbeam's Kubernetes substrate, Juju controller, and OpenStack model. Provisioning goes through Terraform so the infrastructure is versioned and reproducible rather than a one-off `aws ec2 run-instances` call.

**A real bug fixed here:** the version of this file used earlier referenced `var.key_pair_name` inside the `aws_instance` resource without ever declaring it as a variable — Terraform correctly rejected the `-var="key_pair_name=..."` flag on the command line because the config never declared anything by that name. That's fixed below. Separately, `key_name` on an EC2 instance references a key pair that has to already exist in AWS — Terraform doesn't create it for you — so this block assumes you've already run `aws ec2 create-key-pair` for the key you're passing in, in the same region as `aws_region` below.

**A second, bigger correction:** an earlier version of this file provisioned Ubuntu 22.04 (jammy). Sunbeam requires Ubuntu 24.04 (noble) — attempting `sunbeam prepare-node-script` on jammy fails immediately with `ERROR: Sunbeam deploy only supported on noble`. The AMI filter below targets noble now. Worth noting for anyone adapting this further: the AMI path itself changed between releases, not just the release name — 22.04 and earlier used `hvm-ssd`, 24.04 uses `hvm-ssd-gp3`, so swapping just the version string in the old path wouldn't have worked either.

```hcl
# main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "allowed_ssh_cidr" {
  description = "Your current IP, /32 only — never 0.0.0.0 slash 0"
  type        = string
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair in this region — must already exist in AWS, Terraform doesn't create it"
  type        = string
}

resource "aws_security_group" "sunbeam_lab" {
  name        = "session13-sunbeam-lab"
  description = "Session 13 - Sunbeam private cloud lab"

  ingress {
    description = "SSH from operator IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Juju controller <-> unit communication (loopback-scoped, but declared
  # explicitly so the intent is documented, not implicit)
  ingress {
    description = "Juju controller API"
    from_port   = 17070
    to_port     = 17070
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Session = "13"
    Purpose = "sunbeam-migration-lab"
  }
}

resource "aws_instance" "sunbeam_host" {
  ami           = data.aws_ami.ubuntu_2404.id
  instance_type = "m5.xlarge" # 4 vCPU / 16GB — matches Sunbeam's documented minimum; step up to m5.2xlarge only if bootstrap struggles for resources
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.sunbeam_lab.id]

  root_block_device {
    volume_size = 100 # Juju controller + Sunbeam + MicroCeph OSD all share this disk in the lab
    volume_type = "gp3"
  }

  tags = {
    Name    = "session13-sunbeam-host"
    Session = "13"
  }
}

data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

output "instance_public_ip" {
  value = aws_instance.sunbeam_host.public_ip
}
```

```bash
# One-line explanation: create the key pair first if it doesn't already exist
# in this region — this is the step that's easy to skip and hit
# InvalidKeyPair.NotFound on apply (see Debugging Scenario 1).
aws ec2 describe-key-pairs --region us-east-1 --key-names linux 2>/dev/null \
  || aws ec2 create-key-pair --key-name linux --region us-east-1 \
       --query 'KeyMaterial' --output text > linux.pem && chmod 400 linux.pem

# One-line explanation: initializes the working directory and downloads the AWS provider plugin.
terraform init

# One-line explanation: shows exactly what will be created before anything is touched — always review this against the CR before applying.
terraform plan -var="allowed_ssh_cidr=$(curl -s ifconfig.me)/32" -var="key_pair_name=linux"

# One-line explanation: creates the EC2 instance and security group defined above.
terraform apply -var="allowed_ssh_cidr=$(curl -s ifconfig.me)/32" -var="key_pair_name=linux"
```

---

## 5. Block 2 — Ansible: host preparation

**What this does and why:** Sunbeam has host-level prerequisites before it will bootstrap — kernel modules loaded, snapd ready, the right packages present. Doing this by hand is exactly the kind of step that's easy to get subtly wrong (see Debugging Scenario 3 below), so it's automated and idempotent.

**A correction reversed here, based on what the tool actually did, not documentation:** an earlier version of this session removed LXD from Ansible's job, based on Canonical's written documentation describing `sunbeam cluster bootstrap` installing Canonical Kubernetes as its own substrate. Running it for real against this specific `openstack` snap channel produced a different result: `sunbeam cluster bootstrap` failed outright with `Error: Missing Juju controller on LXD`, explicitly instructing `juju bootstrap localhost` as the fix. LXD is restored below. The lesson worth keeping from this, not just the fix: when a tool's actual behavior contradicts its own documentation, the tool's behavior is what you build against — docs can describe a target architecture, a different channel, or a future version, but the error message in front of you describes what's actually installed.

**Where this actually runs:** this playbook runs *from* the machine where you have Ansible installed — your WSL2 terminal, the same place you just ran `terraform apply` from — *against* the EC2 instance Terraform just created, over SSH. It does not run on the EC2 instance directly, and it isn't installed or executed inside WSL2 itself; WSL2 here is just your control machine, the same role your laptop would play against a real client's infrastructure.

**A prerequisite worth checking before running anything below, not after:** an old `ansible-core` on your control machine will fail against a Python 3.12 target (which is what Ubuntu 24.04 ships) with `ModuleNotFoundError: No module named 'ansible.module_utils.six.moves'` — a control-machine problem, not a playbook problem, and it won't be obvious from the error that this is the cause (see Debugging Scenario 11). Check and fix this once, up front:
```bash
ansible --version
python3 --version
```
If `ansible-core` is old, install a current one in an isolated virtual environment rather than fighting whatever's already on your system PATH:
```bash
python3 -m venv ~/ansible-venv
source ~/ansible-venv/bin/activate
pip install --upgrade pip
pip install ansible-core
ansible-galaxy collection install community.general
```
This venv needs reactivating (`source ~/ansible-venv/bin/activate`) every time you come back to this session in a new terminal — easy to forget, and forgetting it silently puts you back on the old system Ansible.

```bash
# One-line explanation: the playbook below uses community.general.modprobe
# and community.general.snap — neither ships with Ansible core, so without
# this step the playbook fails immediately with "couldn't resolve
# module/action" before it touches the target host at all (see Debugging
# Scenario 5). Run this once, from your WSL2 control machine.
ansible-galaxy collection install community.general
```

```yaml
# playbook-host-prep.yml
---
- name: Prepare host for Sunbeam
  hosts: all
  become: true

  tasks:
    - name: Ensure required kernel modules are loaded
      # one-line explanation: br_netfilter is needed for bridged network
      # traffic between LXD containers to be visible to iptables — without
      # it, Juju units can come up but lose network connectivity to each
      # other in ways that look like a completely different failure (see
      # Debugging Scenario 4).
      community.general.modprobe:
        name: "{{ item }}"
        state: present
      loop:
        - br_netfilter
        - overlay

    - name: Persist kernel modules across reboot
      copy:
        dest: /etc/modules-load.d/sunbeam-lab.conf
        content: |
          br_netfilter
          overlay

    - name: Install LXD
      # one-line explanation: sunbeam cluster bootstrap expects a Juju
      # controller already running on LXD — it does not install or bootstrap
      # LXD itself (see Debugging Scenario 12).
      command: snap install lxd
      args:
        creates: /snap/lxd/current

    - name: Add operator user to lxd group
      user:
        name: ubuntu
        groups: lxd
        append: true

    - name: Initialize LXD with lab-sized defaults
      command: lxd init --auto
      args:
        creates: /var/snap/lxd/common/lxd/database/local.db

    - name: Install snapd prerequisites
      apt:
        name:
          - snapd
          - jq
        state: present
        update_cache: true

    - name: Install Sunbeam (openstack snap)
      # one-line explanation: this uses the plain command module instead of
      # community.general.snap deliberately — that module has a documented,
      # multi-year history of breaking on Ubuntu snap installs across several
      # of its own releases (confirmed independently, not assumed). A plain
      # command call with `creates:` for idempotency avoids depending on a
      # wrapper with that track record for something this simple. The short
      # module name (`command`, not `ansible.builtin.command`) matters too —
      # see Debugging Scenario 9 if this fails with a parameter error.
      command: snap install openstack --channel=2024.1/stable
      args:
        creates: /snap/openstack/current

    - name: Install MicroCeph
      # one-line explanation: this host has no prior MicroCeph cluster — this
      # session rebuilds it from scratch, so the snap install happens here
      # rather than being assumed present. Same reasoning as above for using
      # command instead of community.general.snap.
      command: snap install microceph
      args:
        creates: /snap/microceph/current
```

```bash
# One-line explanation: runs the playbook against the Terraform-provisioned
# host, using the IP from Terraform's output so nothing is hardcoded. Run
# this from the same directory as your main.tf, in your WSL2 terminal. The
# trailing comma after the IP is what tells Ansible this is a single-host
# ad-hoc inventory — and that host's name is the IP itself, which is why the
# playbook above targets `hosts: all` rather than a named host (see
# Debugging Scenario 6 if that mismatch bites you).
ansible-playbook -i "$(terraform output -raw instance_public_ip)," \
  -u ubuntu --private-key ./linux.pem \
  playbook-host-prep.yml
```

**Note the `-u ubuntu` and `--private-key` flags are the equivalent of manually SSHing in — in a real client engagement this is where you'd instead be handed a client-managed bastion host or an existing SSH access grant, not a key you generated yourself. Flagging that gap explicitly: in this lab, you own both ends of the access chain. In reality, the client's IAM/PAM tooling provisions and revokes that access on their schedule, not yours.**

---

## 6. Block 3 — Bootstrap Sunbeam

```bash
# One-line explanation: generates and runs the dependency-install script —
# handles the remaining node prep sunbeam needs beyond what Ansible already did.
sunbeam prepare-node-script | bash -x

# One-line explanation: bootstraps a Juju controller into the LXD installed
# by Ansible — sunbeam cluster bootstrap expects this to already exist and
# fails immediately with "Missing Juju controller on LXD" if it doesn't (see
# Debugging Scenario 12). This is the "brain" that will manage the Sunbeam
# OpenStack model.
juju bootstrap localhost sunbeam-controller

# One-line explanation: confirms the controller is up before adding anything
# to it — get comfortable reading this output, it's your primary operational
# view into what Juju is managing for the rest of this session.
juju status

# One-line explanation: with the controller already running, this deploys
# keystone, nova, neutron, glance, and cinder as Juju applications into it —
# control, compute, and storage roles all on this one node since it's a
# single-node lab.
sunbeam cluster bootstrap --accept-defaults --role control,compute,storage

# One-line explanation: this is the single most useful command for the rest
# of this session — every OpenStack service is a Juju application, every
# "unit" column tells you if that service is healthy. Watch this during
# bootstrap.
watch -n 5 juju status
```

Bootstrap on a machine without working KVM acceleration takes considerably longer than the docs suggest — expect 25–40 minutes, not the 10–15 you'll see quoted, because of the QEMU emulation gap flagged in the revision note and Section 3.

---

## 7. Block 4 — Rebuild the MicroCeph cluster

**What this does and why:** this host has no MicroCeph cluster on it — it's a fresh EC2 instance. This block recreates the single-node cluster and RBD pool exactly as Session 12 built it, so the rest of this session has something real to reconnect Cinder to. Doing this explicitly, rather than assuming it exists, is what actually makes this session standalone.

```bash
# One-line explanation: pins the snap to its current channel so it doesn't
# auto-update mid-session and change behavior underneath you.
sudo snap refresh --hold microceph

# One-line explanation: bootstraps a single-node Ceph cluster — a monitor and
# manager daemon running on this one host, same as Session 12's setup.
sudo microceph cluster bootstrap

# One-line explanation: MicroCeph needs at least one real or loop-backed block
# device to act as an OSD (the actual unit that stores data). This EC2
# instance only has its root volume, so a raw file mounted as a loop device
# stands in for a dedicated disk — this is a lab substitution, not something
# you'd do against a real client's storage tier.
sudo fallocate -l 20G /var/snap/microceph/common/osd-disk.img
sudo losetup -fP /var/snap/microceph/common/osd-disk.img
LOOP_DEV=$(losetup -j /var/snap/microceph/common/osd-disk.img | cut -d: -f1)
sudo microceph disk add "$LOOP_DEV"

# One-line explanation: confirms the OSD joined and the cluster is reporting
# healthy before anything is built on top of it.
sudo microceph status
sudo ceph -s

# One-line explanation: creates the RBD pool Cinder will store its volumes
# in — same pool name Session 12 used, so the naming stays consistent every
# time this lab is rebuilt.
sudo ceph osd pool create cinder-vols 32
sudo rbd pool init cinder-vols
```

At this point you have a freshly rebuilt, healthy, single-node MicroCeph cluster with a `cinder-vols` pool — functionally identical to where Session 12 left off, but built from nothing in this session.

---

## 8. Block 5 — Reconnect Cinder to the MicroCeph cluster

**What this does and why:** Sunbeam's Cinder service needs to be told to use the MicroCeph cluster you just built as its storage backend, rather than provisioning its own.

**Worth checking before you run this:** the `--role control,compute,storage` flag used in Block 3's bootstrap may already handle wiring a storage backend automatically in current Sunbeam versions — the steps below reflect the explicit manual pattern that's known to work from Session 12's build. If `openstack volume service list` already shows a backend after bootstrap, some of this may be redundant rather than wrong; verify what's already there before assuming you need all of it.

```bash
# One-line explanation: creates a dedicated Ceph client identity scoped only to
# the cinder-vols pool, rather than reusing the admin keyring — least privilege,
# same principle as scoping an IAM role instead of using root credentials.
sudo ceph auth get-or-create client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=cinder-vols' \
  mgr 'profile rbd pool=cinder-vols'

# One-line explanation: exports that identity's key so Sunbeam's cinder-ceph
# charm can authenticate to the cluster.
sudo ceph auth get-key client.cinder > /tmp/cinder.key

# One-line explanation: deploys cinder-ceph as a Juju application inside the
# Sunbeam model and relates it to the existing cinder application — "relate" is
# Juju's term for wiring two applications together so they exchange config
# automatically instead of you hand-editing config files on both sides.
juju deploy cinder-ceph --channel 2024.1/stable
juju relate cinder-ceph cinder
juju relate cinder-ceph microceph

# One-line explanation: confirms Cinder now sees the Ceph-backed pool as an
# available volume backend.
openstack volume service list
```

---

## 9. Block 6 — Hybrid inventory script (boto3)

**What this does and why:** Corvex isn't fully private-cloud — they still run workloads on AWS, and part of a field engineer's job during a migration like this is being able to answer "what do we actually have, across both environments" without switching between five different consoles. This script pulls a unified inventory across the AWS side (via boto3) and the new Sunbeam OpenStack side (via the OpenStack SDK), which is the first real building block toward the hybrid-cloud design work in a later session.

```python
#!/usr/bin/env python3
"""
hybrid_inventory.py
Pulls a unified compute inventory across AWS and the Sunbeam OpenStack cloud.
Read-only — this script never creates, modifies, or deletes anything.
"""
import boto3
import openstack
import json
import sys


def get_aws_inventory(region: str) -> list[dict]:
    """One-line explanation: lists running EC2 instances rather than hardcoding
    an instance ID, so this stays correct as the AWS side changes."""
    ec2 = boto3.client("ec2", region_name=region)
    instances = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                name_tag = next(
                    (t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"),
                    "unnamed",
                )
                instances.append(
                    {
                        "source": "aws",
                        "id": inst["InstanceId"],
                        "name": name_tag,
                        "type": inst["InstanceType"],
                        "state": inst["State"]["Name"],
                        "private_ip": inst.get("PrivateIpAddress"),
                    }
                )
    return instances


def get_openstack_inventory() -> list[dict]:
    """One-line explanation: uses the OpenStack SDK, which reads connection
    details from clouds.yaml the same way boto3 reads from your AWS credentials
    file — same pattern, different SDK."""
    conn = openstack.connect(cloud="sunbeam")
    instances = []
    for server in conn.compute.servers():
        instances.append(
            {
                "source": "openstack",
                "id": server.id,
                "name": server.name,
                "type": server.flavor.get("original_name", "unknown"),
                "state": server.status.lower(),
                "private_ip": next(
                    iter(server.addresses.values()), [{}]
                )[0].get("addr"),
            }
        )
    return instances


def main():
    try:
        aws_inventory = get_aws_inventory(region="eu-west-2")
    except Exception as e:
        print(f"[warn] AWS inventory failed: {e}", file=sys.stderr)
        aws_inventory = []

    try:
        os_inventory = get_openstack_inventory()
    except Exception as e:
        print(f"[warn] OpenStack inventory failed: {e}", file=sys.stderr)
        os_inventory = []

    combined = aws_inventory + os_inventory
    print(json.dumps(combined, indent=2))
    print(
        f"\nTotal: {len(combined)} instances "
        f"({len(aws_inventory)} AWS, {len(os_inventory)} OpenStack)",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
```

**Honest scope note:** this script is read-only inventory, not a control-plane bridge — it doesn't do cross-cloud networking or identity federation. That's real hybrid-cloud design work, and it's intentionally being left for the dedicated hybrid session later in the roadmap rather than bolted on here.

---

## 10. Block 7 — Carry forward the Slack health-check alerting

Session 12's health-check script gets updated to check Sunbeam's services instead of MicroStack's:

```bash
#!/usr/bin/env bash
set -euo pipefail

# One-line explanation: checks the same three things Session 12 checked
# (control plane reachability, volume service, Ceph health) but through
# Sunbeam's service names instead of MicroStack's.
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:?Set SLACK_WEBHOOK_URL first}"

check_failed=0
messages=()

if ! openstack volume service list -f json | jq -e '.[] | select(.State=="up")' >/dev/null 2>&1; then
  check_failed=1
  messages+=("Cinder volume service is not reporting up")
fi

if ! sudo ceph -s --format json | jq -e '.health.status == "HEALTH_OK"' >/dev/null 2>&1; then
  check_failed=1
  messages+=("MicroCeph cluster health is not HEALTH_OK")
fi

if ! juju status --format json | jq -e '[.applications[].units[]."workload-status".current] | all(. == "active")' >/dev/null 2>&1; then
  check_failed=1
  messages+=("One or more Juju units are not in active state")
fi

if [ "$check_failed" -eq 1 ]; then
  payload=$(jq -n --arg text "Session 13 Sunbeam health check FAILED: $(IFS='; '; echo "${messages[*]}")" '{text: $text}')
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL"
fi
```

---

## 11. Debugging scenarios — real fixes, first-time-path corrected

These are written as the correct path, with the failure noted so you know what you'd actually hit.

**Scenario 1 — `terraform apply` fails with "Value for undeclared variable"**
*What happened:* the `aws_instance` resource referenced `var.key_pair_name`, but no matching `variable "key_pair_name" {}` block existed anywhere in `main.tf`. Terraform validates that every `-var` flag on the command line corresponds to a declared variable, and correctly refused to proceed rather than silently ignoring the value.
*Fix:* add the missing declaration:
```hcl
variable "key_pair_name" {
  description = "Name of an existing EC2 key pair in this region"
  type        = string
}
```
*The lesson:* Terraform's variable validation is doing you a favor here, not getting in your way. A tool that silently accepted an unused `-var` flag would be worse — you'd have no signal that the value you thought you were passing in was actually being used anywhere.

**Scenario 2 — `terraform apply` fails with `InvalidKeyPair.NotFound`**
*What happened:* `key_name = var.key_pair_name` in the `aws_instance` resource references a key pair name that has to already exist in AWS — Terraform doesn't create EC2 key pairs on your behalf just because you referenced one by name. The value passed (`linux`) hadn't been created yet, at least not in the region Terraform was targeting.
*Fix:* create it explicitly before applying, in the same region:
```bash
aws ec2 create-key-pair --key-name linux --region us-east-1 \
  --query 'KeyMaterial' --output text > linux.pem
chmod 400 linux.pem
```
*The lesson:* key pairs are scoped per-region, and referencing one by name doesn't validate it exists until Terraform actually calls `RunInstances` against the AWS API — the earlier `terraform plan` step won't catch this, since plan doesn't make that particular API call. Two different classes of error can both surface as "value error" at first glance: one caught by Terraform's own config validation before touching AWS at all (Scenario 1), and one only caught once AWS itself rejects the request (this one). Worth being able to tell which kind you're looking at from the error text alone.

**Scenario 3 — OpenStack units come up but can't reach each other**
*What happened:* the `br_netfilter` kernel module wasn't loaded before Sunbeam's internal Kubernetes created its pod networking, so bridged pod traffic wasn't visible to iptables, silently dropping inter-service traffic.
*Fix:* this is why the Ansible playbook loads `br_netfilter` before the openstack snap is installed, not after. If you hit this: `sudo modprobe br_netfilter`, then restart the affected services — a module loaded after the bridge network already exists doesn't retroactively apply.
*The lesson:* ordering matters in provisioning, not just presence. "Is the module loaded" and "was it loaded before the thing that needed it started" are different questions.

**Scenario 4 — `juju relate cinder-ceph cinder` succeeds but Cinder still shows no available backend**
*What happened:* the `client.cinder` Ceph key was generated correctly, but scoped to the wrong pool name — `cinder-vols` in Session 12's MicroCeph setup vs. the default `cinder-ceph` pool name Sunbeam's charm expects unless told otherwise.
*Fix:* explicitly pass the pool name during the relation config rather than relying on the default:
```bash
juju config cinder-ceph rbd-pool-name=cinder-vols
```
*The lesson:* "it worked in the demo" configs assume default names. The moment you're deliberately preserving a naming convention across rebuilds (like keeping `cinder-vols` consistent with how Session 12 named it), you have to explicitly configure that name rather than assume the new tool's defaults will match what you intended.

**Scenario 5 — `ansible-playbook` fails immediately with "couldn't resolve module/action 'community.general.modprobe'"**
*What happened:* the playbook uses two modules from the `community.general` collection (`modprobe` and `snap`), but that collection isn't part of Ansible core and isn't installed by default — only `ansible-galaxy collection install community.general` puts it on the control machine. Without it, the playbook fails on its very first task, before ever connecting to the target host.
*Fix:* install the collection once, on whichever machine is running `ansible-playbook` (your WSL2 control machine, not the EC2 target):
```bash
ansible-galaxy collection install community.general
```
*The lesson:* a module namespaced as `community.*` is a signal on its own — it means "not core, must be fetched separately" — worth reading before assuming any module referenced in a playbook is automatically available just because Ansible itself is installed.

**Scenario 6 — `ansible-playbook` runs clean but reports "Could not match supplied host pattern" and "skipping: no hosts matched"**
*What happened:* `-i "$(terraform output -raw instance_public_ip),"` builds an ad-hoc inventory with exactly one host, and that host's name in Ansible's eyes is the IP address itself — not any name you might expect, like `sunbeam_host`. The playbook's `hosts:` line was set to `sunbeam_host`, which matches nothing in an inventory that only ever contained an IP.
*Fix:* target `hosts: all` in the playbook when working against a single ad-hoc host passed by IP — `all` matches whatever's actually in the inventory regardless of its name, rather than requiring the play and the inventory to agree on a specific hostname that was never defined anywhere.
*The lesson:* `hosts:` in a playbook and the identifiers in your inventory have to actually agree, and an ad-hoc inventory built from a bare IP doesn't give you a friendly name for free — it names the host exactly what you typed. This is an easy thing to get away with in a static inventory file with named groups, and an easy thing to trip on the moment you switch to a one-off IP passed straight from Terraform's output.

**Scenario 7 — `community.general.snap` fails with `ValueError: ...module_utils._snap.__spec__ is None`**
*What happened:* the snap task failed inside the collection's own Python code, not in anything task-specific — an internal import error in the `_snap` module_utils file. This isn't a one-off: `community.general.snap` has a documented, multi-version history of breaking on Ubuntu snap installs, with several separate open GitHub issues against different releases of the collection over multiple years. The kernel-module tasks earlier in the same playbook, also from `community.general`, worked fine — so this wasn't the whole collection failing, just this one specific module.
*Fix:* stop depending on the module for this operation. A plain `command` task with a `creates:` argument gets the same idempotency (skip the task if the snap's already installed, by checking for its `/snap/<name>/current` path) without going through code that has a track record of breaking — see Scenario 9 for why the short module name matters here, not the fully-qualified `ansible.builtin.command`:
```yaml
- name: Install openstack snap
  command: snap install openstack --channel=2024.1/stable
  args:
    creates: /snap/openstack/current
```
*The lesson:* a wrapper module existing for a task doesn't automatically make it the more reliable choice than the plain command underneath it — sometimes the abstraction is the thing that's broken, and the boring, direct approach is the more dependable one. Worth checking a module's own issue tracker when it fails in a way that looks internal rather than config-related, rather than assuming the bug is always in your playbook.

**Scenario 8 — `ansible-playbook` reports `UNREACHABLE`, "Connection closed by [ip] port 22", right after accepting the host key**
*What happened:* the SSH handshake itself succeeded — that's why a host key fingerprint prompt appeared and got accepted — but authentication failed immediately afterward and the server actively closed the connection rather than timing out. Two distinct causes can both produce exactly this pattern: an overly permissive private key file (OpenSSH silently refuses to use a key that's group- or world-readable), or running the playbook before `cloud-init` has finished writing the `ubuntu` user's `authorized_keys` file on a freshly-booted instance — the port opens before that boot-time setup completes.
*Fix:* check both, in order:
```bash
chmod 400 ~/.ssh/your-key.pem
```
Then wait a minute or two after `terraform apply` finishes before running Ansible, rather than immediately chaining the two commands.
*The lesson:* "connection closed" and "connection timed out" are different failure signatures pointing at different problem classes — a closed connection means something on the remote end actively rejected you, which narrows the search to authentication and access, not general network reachability.

**Scenario 9 — resolving `ansible.builtin.command`'s free-form-plus-args restriction took two wrong turns before the right one**
*What happened, step by step:* the first fix attempt kept the fully-qualified module name (`ansible.builtin.command`) with a free-form command string and a separate `args: {creates: ...}` block — and failed, because this `ansible-core` version only allows that specific combination (free-form content plus a separate `args:` block) for a module's *short* name, not its fully-qualified one. Its own error message listed `command` as allowed, `ansible.builtin.command` was not on that list. The second attempt switched to the FQCN with an explicit `cmd:` keyword instead of free-form content — and failed differently, because this `ansible-core` version's `command` module doesn't recognize `cmd` as a parameter at all; its error message listed the actual supported set (`_raw_params`, `argv`, `chdir`, `creates`, and a handful of others), which doesn't include `cmd`. The fix that actually works combines what both errors independently confirmed: the short module name (satisfies the first error), with free-form content and a separate `args:` block (satisfies the second, since `_raw_params` and `creates` are both genuinely supported):
```yaml
- name: Install openstack snap
  command: snap install openstack --channel=2024.1/stable
  args:
    creates: /snap/openstack/current
```
*The lesson:* when two consecutive fixes both fail with *different* errors, that's a signal each error message is narrowing down the actual constraint rather than being unrelated noise — reading what each one explicitly says is and isn't supported, rather than guessing at a third syntax, is what actually converges on the answer. This also says something concrete about the environment itself: multiple modern syntax forms failing in sequence points at an older `ansible-core` version behind the scenes — confirmed directly in Scenario 11 below, which turned out to be the actual root cause connecting this scenario to that one.

**Scenario 10 — `sunbeam prepare-node-script | bash -x` fails immediately with `ERROR: Sunbeam deploy only supported on noble`**
*What happened:* the EC2 instance was provisioned on Ubuntu 22.04 (jammy) — an assumption baked into this README from the start, carried over from Session 12's MicroStack build, which didn't have this constraint. Sunbeam checks the OS release directly (`lsb_release -sc`) before doing anything else, and refuses to proceed on anything other than noble.
*Fix:* this isn't fixable on a running jammy host — it requires provisioning a new instance on the right release. The AMI filter has to target 24.04, and the release path in the AMI name changes too, not just the version number:
```hcl
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}
```
Since changing the AMI forces Terraform to replace the instance, this means a new public IP too — Ansible host prep (Block 2) has to run again afterward against the new IP, not just Block 3 retried against the old host.
*The lesson:* a working setup from a previous, related session (Session 12's MicroStack build on jammy) doesn't guarantee the same OS choice carries forward correctly to a new tool with different requirements — Sunbeam and MicroStack are both OpenStack distributions solving a similar problem, but that similarity doesn't extend to their platform requirements. Worth checking a new tool's actual supported-OS list explicitly rather than assuming continuity from what worked last session.

**Scenario 11 — `ansible-playbook` fails on the very first task, "Gathering Facts," with `ModuleNotFoundError: No module named 'ansible.module_utils.six.moves'`**
*What happened:* this turned out to be the actual root cause behind several earlier scenarios in this session, not a new, unrelated problem. The control machine's `ansible-core` was old enough that it doesn't correctly support Python 3.12, which is what Ubuntu 24.04 ships by default. Host prep had worked fine against the previous jammy instance (Python 3.10) — the exact same control-machine Ansible install, unchanged, started failing the moment the target moved to noble. This is a well-documented, independently confirmed issue, not specific to this session's setup.
*Fix:* this isn't fixable in the playbook — it requires a current `ansible-core` on the control machine, installed in an isolated environment so it doesn't conflict with whatever's already on the system:
```bash
python3 -m venv ~/ansible-venv
source ~/ansible-venv/bin/activate
pip install --upgrade pip
pip install ansible-core
ansible-galaxy collection install community.general
```
*The lesson:* when a chain of increasingly strange, version-specific errors shows up across an otherwise straightforward session — a missing `cmd:` parameter, an FQCN restriction, now this — it's worth stepping back and checking the tool's own version directly rather than continuing to patch around each symptom individually. `ansible --version` at the very start of a session is a five-second check that would have surfaced this before any of the syntax-level troubleshooting in Scenario 9 became necessary at all.

**Scenario 12 — `sunbeam cluster bootstrap` fails immediately with `Error: Missing Juju controller on LXD`**
*What happened:* an earlier version of this session removed LXD from the build entirely, based on Canonical's written documentation describing `sunbeam cluster bootstrap` installing its own Kubernetes substrate and bootstrapping Juju onto that automatically. Running the real command against the actual `2024.1/stable` channel produced a direct contradiction of that documentation: `sunbeam cluster bootstrap` refused to proceed and explicitly named the fix itself — `Bootstrap Juju controller on LXD: juju bootstrap localhost`.
*Fix:* install and initialize LXD, then bootstrap a Juju controller into it manually before running `sunbeam cluster bootstrap`:
```bash
sudo snap install lxd
sudo lxd init --auto
sudo usermod -aG lxd ubuntu
newgrp lxd
juju bootstrap localhost sunbeam-controller
sunbeam cluster bootstrap --accept-defaults --role control,compute,storage
```
*The lesson:* documentation describes an intended or target state; the error message in front of you describes the actual state of what's installed, on the channel you actually pulled. When the two genuinely conflict, the tool's own behavior wins, and it's worth updating the plan rather than continuing to trust the source that turned out to be wrong. This is also just a fact of working with fast-moving infrastructure tooling in the field — Canonical's own docs note that installation instructions for OpenStack can evolve rapidly, and the version installed on a given day doesn't always match the version the current docs describe.

---

## 12. Lab-vs-reality gaps — consolidated

- **Compute:** this lab runs on a single EC2 instance with software-emulated virtualization. Real Sunbeam deployments target MAAS-managed bare metal or hardware-virtualization-capable hosts. Performance and some Nova features will differ.
- **Access:** you provisioned your own SSH key and hold both ends of access in this lab. In a real engagement, the client's IAM/PAM system provisions and time-boxes your access, and you don't control the revocation.
- **Scale:** this is a single-node Juju controller and single-node MicroCeph cluster. Production Juju deployments run multi-unit, highly-available controllers, and Ceph clusters are sized in multiples of the failure domain, not one node.
- **Storage replication:** untouched by this session — this is exactly why storage replication is getting its own dedicated session (Session 14) rather than being assumed solved because MicroCeph is "working."
- **Charm authoring:** deliberately out of scope. You're consuming existing charms (cinder-ceph, cinder, nova) via Juju relations, not writing new ones. That's a distinct, deeper skill this track isn't targeting.
- **Storage continuity:** this is the one worth sitting with. In this lab, MicroCeph is destroyed at teardown and rebuilt from nothing next time, because the session needs to be runnable standalone. In a real engagement, you would never do that — the whole point of the ADR below is that the storage cluster *doesn't* move or get touched while the control plane migrates around it. The lab's rebuild-every-time pattern is a reproducibility tool for practicing the commands repeatedly, not a reflection of how you'd actually treat a client's live storage.

---

