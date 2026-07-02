# CFE Training Series — Session 13
## RetailEdge Ltd: OpenStack Sandbox Evaluation & Infrastructure-as-Code Migration

**Track:** Canonical Junior Cloud Field Engineer Prep
**Client (fictional):** RetailEdge Ltd
**Time budget:** 2.5–3 hours (split across two free days)
**Standalone session:** Yes — this ticket provisions all of its own infrastructure from scratch. It does not depend on any resources from Sessions 1–12 still running, and it ends with full teardown.

---

## 🎫 Client Ticket

**Ticket:** RE-2031
**Raised by:** Adaeze Okonkwo, Head of Infrastructure, RetailEdge Ltd
**Priority:** Medium
**Category:** Infrastructure Strategy / Internal Tooling

> Two things came out of last month's infrastructure audit.
>
> First — the auditors flagged that several of our AWS environments were built by engineers running CLI commands by hand, with no record of *why* a resource exists or who approved it. We got lucky that nothing broke, but the CAB doesn't want to rely on luck. Going forward, anything our cloud engineering contractors provision for us must be done through code we can review, version, and re-run — not ad-hoc commands typed into a terminal. We'd like you to demonstrate this on a small sandbox first, using Terraform, before we mandate it everywhere.
>
> Second — separately, our CTO has asked us to put together a cost/feasibility case for OpenStack as a private cloud option for our upcoming regional distribution centre. Public cloud egress and data residency costs are becoming a real concern for that site, and OpenStack keeps coming up as the open-source option enterprises in our position use. None of our current engineers have real hands-on OpenStack experience — we've only ever used AWS. Before we hire a specialist or sign a vendor contract, we need someone to actually stand up a small OpenStack environment, kick the tyres, and tell us honestly what it does, what it would take to run in production, and where it differs from what we already know on AWS.
>
> Can you handle both in the same engagement? Use Terraform to provision the sandbox host, then use that host to install and evaluate OpenStack. Also — our finance team asked again for a clean, auditable list of what's currently running and what it's tagged to. Last time someone asked "what's live right now" we had to manually check the console. Can you also leave us with something that answers that question programmatically instead of from memory?

**Acceptance criteria:**
1. Sandbox infrastructure is provisioned via Terraform, not manual `aws` CLI commands — config must be reviewable and re-runnable.
2. A working MicroStack (single-node OpenStack) deployment, with evidence of at least: identity (Keystone), compute (Nova), networking (Neutron), image service (Glance) all functioning, and one test instance launched *inside* OpenStack.
3. A Python script using `boto3` that discovers AWS infrastructure dynamically by tag — no hardcoded instance lists — producing a reviewable inventory artifact.
4. An honest write-up of the lab-vs-production gap for OpenStack (this is a sandbox on a single cloud VM, not bare metal — that distinction matters and must be stated, not glossed over).
5. Full teardown at the end — RetailEdge is not paying to keep an idle sandbox running.

---

## Block 1 — Session Context (~15 min)

### Why this matters for the Junior CFE role

The Canonical Junior Cloud Field Engineer job description names a specific stack: **OpenStack, Kubernetes, Ceph, Hadoop, Spark, public cloud (AWS/GCP/Azure), Linux, and networking.** Up to Session 12, this series has built strength in AWS, Linux, and networking. OpenStack has been a near-zero-hands-on gap. This session is the first real attempt to close it — not a five-minute overview, but an actual install, actual CLI usage, actual instance launch.

This session is also a deliberate process change: from here on, every infrastructure-provisioning step in this series uses **Terraform** instead of raw `aws` CLI commands, with **Ansible** layered in for configuration/hardening where it fits. This mirrors how a real client would expect a contractor to work after an audit finding like the one in the ticket above — and it's also simply the more professional way to work, since you're Terraform Associate–certified already.

### What "real" field engineering looks like here

A field engineer evaluating a new technology for a client doesn't get unlimited time or a perfect lab. They get a constrained budget, a deadline, and a need to give an honest technical opinion — including admitting what doesn't fully match production reality. That honesty is exactly what today's Block 3 write-up needs to capture.

### Lab vs. reality — flagged up front

Production OpenStack deployments (including what Canonical sells and supports as Charmed OpenStack) typically run on **bare metal**, because Nova (the compute service) wants direct access to hardware virtualization (KVM) for performance. A standard AWS EC2 instance is *itself* a virtual machine — it does not expose nested virtualization to the guest OS by default. That means MicroStack, running inside an EC2 instance, will fall back to **QEMU software emulation** instead of hardware-accelerated KVM. It will work, and every concept and command will be real, but it will be noticeably slower than a true production deployment, and that's a meaningful difference between this lab and what RetailEdge would actually run. State this plainly in any interview answer — claiming hands-on production-grade OpenStack experience from this lab would be overclaiming.

---

## Block 2 — Infrastructure Lab: Terraform Provisioning (~60 min)

### Why Terraform instead of CLI commands, in plain English

Up to now, this series has used `aws ec2 run-instances ...` and similar one-off commands. That works, but it has a problem the audit in the ticket called out directly: once you run a command, the *record* of what you did lives only in your shell history. Nobody else can review it before it runs, and there's no clean way to tear down exactly what was built without remembering every command you typed.

Terraform flips that. You write a file describing the **desired end state** ("I want one EC2 instance, this size, this security group"), and Terraform figures out the steps to get there. That file is reviewable before anything is created (a real CAB could read it and approve it), reusable (anyone can re-run it and get the same result), and reversible (`terraform destroy` removes exactly what `terraform apply` created — nothing more, nothing less).

### Step 1 — Project structure

```bash
mkdir -p ~/cfe-labs/session-13/terraform
cd ~/cfe-labs/session-13/terraform
```

### Step 2 — `provider.tf`

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}
```

### Step 3 — `network.tf`

A minimal, self-contained network — this session does not reuse any VPC from a prior session.

```hcl
resource "aws_vpc" "session13_vpc" {
  cidr_block           = "10.13.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "retailedge-session13-vpc"
    Session = "13"
    Project = "RetailEdge"
  }
}

resource "aws_subnet" "session13_subnet" {
  vpc_id                  = aws_vpc.session13_vpc.id
  cidr_block               = "10.13.1.0/24"
  map_public_ip_on_launch  = true
  availability_zone        = "eu-west-1a"

  tags = {
    Name    = "retailedge-session13-subnet"
    Session = "13"
  }
}

resource "aws_internet_gateway" "session13_igw" {
  vpc_id = aws_vpc.session13_vpc.id

  tags = {
    Name = "retailedge-session13-igw"
  }
}

resource "aws_route_table" "session13_rt" {
  vpc_id = aws_vpc.session13_vpc.id

  route {
    cidr_block = "0.0.0.0 slash 0"
    gateway_id = aws_internet_gateway.session13_igw.id
  }

  tags = {
    Name = "retailedge-session13-rt"
  }
}

resource "aws_route_table_association" "session13_rta" {
  subnet_id      = aws_subnet.session13_subnet.id
  route_table_id = aws_route_table.session13_rt.id
}
```

### Step 4 — `security_group.tf`

MicroStack needs SSH for you, and HTTPS for the Horizon dashboard and OpenStack API endpoints. Scope source IP to your own address in a real engagement; for this lab, the access scope is documented as a known gap rather than left silently open.

```hcl
resource "aws_security_group" "session13_sg" {
  name        = "retailedge-session13-openstack-sandbox"
  description = "Sandbox SG for MicroStack evaluation - Session 13"
  vpc_id      = aws_vpc.session13_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["YOUR_IP_HERE slash 32"]
  }

  ingress {
    description = "MicroStack dashboard and APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["YOUR_IP_HERE slash 32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0 slash 0"]
  }

  tags = {
    Name    = "retailedge-session13-sg"
    Session = "13"
  }
}
```

### Step 5 — `instance.tf`

MicroStack needs meaningful CPU, RAM, and disk. `c5.xlarge` (4 vCPU / 8 GB RAM) with 60 GB of storage is the practical floor for a usable single-node install.

```hcl
resource "aws_instance" "openstack_sandbox" {
  ami                    = "ami-0XXXXXXXXXXXXXXXX" # Ubuntu 22.04 LTS, eu-west-1 - confirm current AMI ID
  instance_type          = "c5.xlarge"
  subnet_id              = aws_subnet.session13_subnet.id
  vpc_security_group_ids = [aws_security_group.session13_sg.id]
  key_name               = "your-keypair-name"

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
  }

  tags = {
    Name        = "retailedge-openstack-sandbox"
    Session     = "13"
    Project     = "RetailEdge"
    Environment = "lab-openstack-eval"
    Client      = "RetailEdge-Ltd"
  }
}

output "sandbox_public_ip" {
  value = aws_instance.openstack_sandbox.public_ip
}
```

Note the tags — `Session = "13"` and `Project = "RetailEdge"` aren't decorative. Block 4's boto3 script will use exactly these tags to find this instance programmatically, instead of you ever having to hardcode its ID or IP anywhere.

### Step 6 — Apply

```bash
terraform init
terraform plan      # review before applying — this is the auditable "approval" step
terraform apply
```

**Portfolio deliverable #1:** a clean, version-controlled Terraform module that provisions a fully self-contained sandbox VPC and host — reviewable by anyone before it runs, with no manual CLI steps involved.

---

## Block 3 — OpenStack Component: MicroStack First Hands-On (~45 min)

### What OpenStack actually is, in plain English

AWS gives you compute, networking, and storage as a fully managed service you never see the internals of. OpenStack is the open-source equivalent — except *you* (or your client) own and run the underlying software stack that provides those same capabilities. It's not one program; it's a collection of independent services that talk to each other over APIs:

| Service | Plain-English role |
|---|---|
| **Keystone** | Identity and authentication — like AWS IAM. Every other service checks with Keystone before doing anything. |
| **Nova** | Compute — launches and manages virtual machines. The OpenStack equivalent of EC2. |
| **Neutron** | Networking — virtual networks, routers, floating IPs. The OpenStack equivalent of VPC. |
| **Glance** | Image service — stores the OS images (like AMIs) that Nova boots instances from. |
| **Cinder** | Block storage — the OpenStack equivalent of EBS volumes. |
| **Horizon** | The web dashboard — optional, but useful for visualizing what the CLI is doing underneath. |

This is exactly the stack Canonical builds commercial support around (Charmed OpenStack). A field engineer's day-to-day work is largely about keeping these services healthy and talking to each other correctly — so seeing them as separate, cooperating pieces (rather than one monolithic "OpenStack") is the single most useful mental model to walk away with today.

### Step 1 — SSH in and install MicroStack

```bash
ssh -i your-key.pem ubuntu@<sandbox_public_ip>
```

MicroStack ships as a **snap** — Ubuntu's self-contained package format that bundles an application with everything it needs to run, isolated from the rest of the system.

```bash
sudo snap install microstack --channel=latest/edge --classic
```

### Step 2 — Initialize a single-node cloud

```bash
sudo microstack init --auto --control
```

This one command brings up Keystone, Nova, Neutron, Glance, and Cinder, wires them together, and creates an initial admin account. In a production deployment this would be the job of an orchestration tool managing many separate physical nodes — here, `--auto --control` collapses all of that onto a single host for learning purposes. That collapse is itself worth naming as a lab-vs-production gap: real OpenStack is rarely one node.

### Step 3 — Retrieve credentials and explore via CLI

```bash
cat ~/snap/microstack/common/etc/microstack.rc
source ~/snap/microstack/common/etc/microstack.rc

openstack service list
openstack image list
openstack network list
```

`openstack service list` is the equivalent of asking "which AWS services are even turned on right now" — except here you're seeing your own deployment's services report in directly, rather than trusting that AWS has them running somewhere.

### Step 4 — Launch a real instance inside OpenStack

MicroStack ships a small test image (`cirros`) by default — purpose-built for verifying that compute and networking actually work, not for running anything real.

```bash
openstack flavor list
openstack server create --flavor m1.small --image cirros --network <network-id> test-instance
openstack server list
```

`openstack server create` here is doing the same conceptual job as `aws ec2 run-instances` — but now Nova, not AWS, is the thing deciding where the VM runs and Neutron, not a VPC, is the thing deciding how it gets an IP address.

### Step 5 — Verify and capture evidence

```bash
openstack server show test-instance
openstack console log show test-instance
```

Screenshot or copy the output of `openstack service list`, `openstack server list`, and the console log — this is your evidence pack for today.

**Portfolio deliverable #2:** a documented, evidenced single-node OpenStack deployment with a launched test instance — plus an honest written assessment (Block 5) of how this differs from a production Charmed OpenStack deployment.

---

## Block 4 — Python Component: boto3 Fundamentals & Dynamic Discovery (~60 min)

### What boto3 is, in plain English

Every time you've run an `aws` CLI command in earlier sessions, the CLI was doing the same thing under the hood: sending an HTTP request to an AWS API endpoint and getting a structured response back. **boto3** is AWS's official Python library that lets your own Python code do exactly that, directly — no CLI in between. Anything you can do with the `aws` CLI, you can do with boto3, and you get the response back as native Python data (dictionaries and lists) instead of text you'd have to parse.

### Step 1 — Install and set up

```bash
pip install boto3
```

Credentials work the same way they already do for your IAM user — boto3 reads the same configured credentials the CLI uses. No profile flag, no separate setup.

### Stage 1 — Make your first API call and look at the raw shape

```python
import boto3

ec2 = boto3.client("ec2", region_name="eu-west-1")
response = ec2.describe_instances()
print(response)
```

- `boto3.client("ec2", ...)` creates an object that knows how to talk to the EC2 API — think of it as opening a phone line to that specific AWS service.
- `.describe_instances()` is one *method* on that object — it asks AWS "tell me about all my EC2 instances" and gets back a Python dictionary.

Run this and look at the output. It will be a deeply **nested** structure: a dictionary, containing a list called `Reservations`, where each item in that list is itself a dictionary containing a list called `Instances`, where each item is a dictionary describing one actual instance. AWS groups instances by "reservation" (the launch request that created them) — which is why there are two levels of list before you reach an actual instance. This nesting is exactly what the CLI was quietly handling for you every time you ran `aws ec2 describe-instances` and read a formatted table.

### Stage 2 — Pull out the fields that actually matter

```python
import boto3

ec2 = boto3.client("ec2", region_name="eu-west-1")
response = ec2.describe_instances()

for reservation in response["Reservations"]:
    for instance in reservation["Instances"]:
        instance_id = instance["InstanceId"]
        state = instance["State"]["Name"]
        public_ip = instance.get("PublicIpAddress", "none")
        print(f"{instance_id} | state: {state} | public IP: {public_ip}")
```

- The outer `for` loop walks each reservation; the inner `for` loop walks each instance inside it — this is how you flatten that nested structure into something useful.
- `instance["State"]["Name"]` is a dictionary inside a dictionary — `State` itself has multiple fields (a numeric code and a name), and you only want `Name`.
- `.get("PublicIpAddress", "none")` is used instead of `["PublicIpAddress"]` because a stopped instance has no public IP — `.get()` with a default avoids a `KeyError` crash when the key simply isn't there.

### Stage 3 — Filter by tag instead of listing everything

Listing *every* instance in the account doesn't scale and isn't what the ticket asked for. AWS lets you filter server-side, so you only get back what you actually need.

```python
import boto3

ec2 = boto3.client("ec2", region_name="eu-west-1")

response = ec2.describe_instances(
    Filters=[
        {"Name": "tag:Session", "Values": ["13"]},
        {"Name": "tag:Project", "Values": ["RetailEdge"]},
    ]
)

for reservation in response["Reservations"]:
    for instance in reservation["Instances"]:
        print(instance["InstanceId"], instance["State"]["Name"])
```

`Filters` is a list of dictionaries, each describing one condition. This is the same filtering AWS's own console search bar does — you're just doing it in code, which means it's repeatable and scriptable rather than a manual search every time someone in finance asks "what's live right now."

### Stage 4 — Turn it into a reusable, reportable tool

```python
import boto3
import json
from datetime import datetime, timezone

def find_instances_by_tag(tag_key, tag_value, region="eu-west-1"):
    """
    Returns a list of dicts describing every EC2 instance matching
    the given tag key/value pair. No hardcoded instance IDs anywhere -
    this works for any session's tagged infrastructure.
    """
    ec2 = boto3.client("ec2", region_name=region)
    response = ec2.describe_instances(
        Filters=[{"Name": f"tag:{tag_key}", "Values": [tag_value]}]
    )

    results = []
    for reservation in response["Reservations"]:
        for instance in reservation["Instances"]:
            results.append({
                "instance_id": instance["InstanceId"],
                "state": instance["State"]["Name"],
                "public_ip": instance.get("PublicIpAddress", "none"),
                "instance_type": instance["InstanceType"],
                "launch_time": instance["LaunchTime"].isoformat(),
            })
    return results


if __name__ == "__main__":
    inventory = find_instances_by_tag("Project", "RetailEdge")

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "instance_count": len(inventory),
        "instances": inventory,
    }

    with open("retailedge_inventory.json", "w") as f:
        json.dump(report, f, indent=2)

    print(f"Found {len(inventory)} instance(s). Written to retailedge_inventory.json")
```

- Wrapping the logic in a `function` (`find_instances_by_tag`) means this same code can be reused for *any* tag, in *any* future session — that's what "no hardcoded server lists" actually means in practice.
- `if __name__ == "__main__":` is a Python convention meaning "only run this block when the file is executed directly, not when it's imported as a module elsewhere." It separates the reusable logic from the one-off reporting action.
- The script writes a timestamped JSON report — this is the artifact finance asked for: a programmatic, auditable answer to "what's live right now," instead of someone manually checking the console.

**Portfolio deliverable #3:** `inventory_by_tag.py` — a reusable boto3 script producing a timestamped, tag-filtered infrastructure inventory report.

---

## Block 5 — Written Interview Capture (~20 min)

Append the following to `~/cfe-labs/canonical-written-interview-draft.md`. Answers must be specific to today's work and honest about the gap being closed — not generic textbook answers.

```markdown
## Session 13 — Terraform Provisioning, OpenStack First Look, boto3 Discovery

**Q: Walk me through why you'd provision infrastructure with Terraform
instead of CLI commands, and what that changes for a client.**

A: [Your answer — reference the RetailEdge audit scenario: reviewability
before execution via `terraform plan`, repeatability, and clean teardown
via `terraform destroy` removing exactly what was created. Mention the
specific VPC/subnet/SG/instance module you built today.]

**Q: What is OpenStack, and what hands-on experience do you have with it?
Be specific about what you ran and what you didn't.**

A: [Your answer — name the services you actually exercised (Keystone,
Nova, Neutron, Glance), the test instance you launched via
`openstack server create`, and state honestly that this was a single-node
sandbox on a cloud VM using QEMU software emulation rather than a
bare-metal production deployment. Don't claim more than you did.]

**Q: How would you write a script to discover what's running in an AWS
account, without relying on a hardcoded list of servers?**

A: [Your answer — describe filtering `describe_instances()` by tag,
and why tag-based, function-based discovery scales to any future
environment instead of breaking the moment server names change.]
```

---

## ✅ Completion Checklist

- [ ] Terraform module (`provider.tf`, `network.tf`, `security_group.tf`, `instance.tf`) applied successfully, with `terraform plan` output captured as evidence of the review step
- [ ] MicroStack installed and initialized on the sandbox host
- [ ] `openstack service list` showing Keystone, Nova, Neutron, Glance, Cinder all active
- [ ] One test instance launched inside OpenStack via `openstack server create`, with `openstack server show` / console log captured as evidence
- [ ] `inventory_by_tag.py` written, run, and producing `retailedge_inventory.json`
- [ ] Lab-vs-production gap (QEMU emulation, single-node collapse) explicitly documented in your own notes
- [ ] Written interview draft updated with this session's 3 questions, answered specifically and honestly
- [ ] All deliverables committed to `github.com/Nikiobilor/cloud-field-engineer-labs`

---

## 🔻 End of Session — Decommission

Everything in this session lives on one Terraform-managed host — teardown is a single command.

```bash
cd ~/cfe-labs/session-13/terraform
terraform destroy
```

Confirm in the AWS console that the instance, security group, route table, internet gateway, subnet, and VPC are all gone. No lingering resources, no idle billing — RetailEdge isn't paying for a sandbox nobody's using.

---

## 📣 LinkedIn Post Prompt

**Type A (sharp technical insight).** The strongest moment from today isn't "I installed OpenStack" — it's the realization underneath it: AWS makes you forget that compute, networking, and storage are actually separate services talking to each other over APIs, because it hides the seams. Standing up Keystone, Nova, Neutron, and Glance by hand on MicroStack makes those seams visible again. Write a short post around that single realization — what you assumed was "one thing" (the cloud) and discovered was actually several cooperating services, and why that distinction matters for someone who'll be debugging exactly those seams as a field engineer. Don't summarize the session — extract that one moment.

---

## 🔭 What's Coming Next — Session 14 Preview

Session 14 stays on OpenStack but goes deeper into **Neutron networking** — virtual routers, floating IP assignment, and security groups from the OpenStack side rather than the AWS side — plus a first pass at using **Ansible** to harden the MicroStack host itself (the way Sessions 7–9 hardened AWS bastion hosts). This is also where the series starts setting up the conceptual bridge toward **Ceph**, since in a real Charmed OpenStack deployment, Ceph is typically the backing store for Cinder volumes and Glance images — the two services you only touched lightly today.
