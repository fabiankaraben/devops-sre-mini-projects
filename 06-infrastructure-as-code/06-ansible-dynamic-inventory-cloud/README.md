<!-- markdownlint-disable MD013 MD033 MD051 -->
# Mini-Project 06: Ansible Dynamic Inventory for Cloud Fleets

> **Domain**: 06. Infrastructure as Code (IaC)  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Docker / OrbStack) or Cloud (AWS EC2 / LocalStack)  

---

## 📋 Table of Contents

1. [Project Overview & Learning Objectives](#-project-overview--learning-objectives)
2. [The Challenge: Static Inventories vs. Dynamic Cloud Fleets](#-the-challenge-static-inventories-vs-dynamic-cloud-fleets)
3. [Dynamic Inventory Core Architecture: Scripts vs. Plugins](#-dynamic-inventory-core-architecture-scripts-vs-plugins)
4. [Tag-Based Fleet Grouping & Metadata Composition](#-tag-based-fleet-grouping--metadata-composition)
5. [Zero-Downtime Rolling Updates with Serial Concurrency](#-zero-downtime-rolling-updates-with-serial-concurrency)
6. [Architecture & Fleet Topology Flow](#-architecture--fleet-topology-flow)
7. [Directory & File Structure](#-directory--file-structure)
8. [Prerequisites & Environment Setup](#-prerequisites--environment-setup)
9. [Step-by-Step Hands-On Guide](#-step-by-step-hands-on-guide)
10. [Deploying to Production AWS EC2 Fleets](#-deploying-to-production-aws-ec2-fleets)
11. [Automated Testing & Verification Suite](#-automated-testing--verification-suite)
12. [Troubleshooting & FAQs](#-troubleshooting--faqs)
13. [Teardown & Cleanup](#-teardown--cleanup)

---

## 🎯 Project Overview & Learning Objectives

In traditional data centers, servers were static physical machines with permanent IP addresses recorded in static configuration files like `inventory.ini` or `/etc/hosts`.

In modern cloud environments (AWS, GCP, Azure) and containerized infrastructures, compute capacity is **ephemeral**:

- Auto Scaling Groups (ASG) dynamically launch and terminate instances based on real-time traffic spikes.
- Spot instances are routinely terminated with 2-minute eviction notices.
- Ephemeral nodes receive dynamic private and public IP addresses on every launch.

Maintaining static inventory files manually in such dynamic environments is impossible and guarantees configuration drift, missed patches, and deployment failures.

This mini-project demonstrates how to implement and operate an **Ansible Dynamic Inventory** system for cloud server fleets. It provides a local, zero-cloud-cost simulation using Docker labeled containers alongside production-ready configurations for AWS EC2 fleets.

```text
┌──────────────────────────────────────────────────────────────────────────────────┐
│                         ANSIBLE DYNAMIC INVENTORY PIPELINE                       │
├──────────────────────────┬───────────────────────────┬───────────────────────────┤
│ 1. Dynamic Discovery     │ 2. Tag-Based Grouping     │ 3. Rolling Orchestration  │
│    • Real-time API query │    • Keyed groups by Env  │    • Concurrency: serial:1│
│    • Zero hardcoded IPs  │    • Keyed groups by Role │    • Pre/Post Healthchecks│
│    • Instant node detect │    • Dynamic hostvars     │    • Zero-Downtime deploy │
└──────────────────────────┴───────────────────────────┴───────────────────────────┘
```

### What You Will Learn

- **Dynamic Inventory Mechanisms**: Understanding how Ansible discovers infrastructure dynamically using JSON scripts (`--list`, `--host`) and YAML inventory plugins (`amazon.aws.aws_ec2`).
- **Tag-Driven Categorization**: Grouping instances dynamically using cloud tags and labels (`Environment=production`, `Role=web`, `App=frontend`).
- **Metadata Composition (`compose` & `hostvars`)**: Dynamically injecting connection parameters, health check URLs, and environment variables into Ansible memory.
- **Pattern Targeting & Host Slicing**: Using Ansible pattern expressions (e.g. `env_production:&role_web`) to target exact fleet slices without static files.
- **Zero-Downtime Rolling Updates**: Implementing playbooks with `serial: 1`, automated pre-upgrade health validation, atomic deployment, and post-upgrade health polling with retry backoff.
- **Auto-Scaling Simulation**: Verifying that newly spawned nodes are discovered instantaneously by Ansible without modifying a single line of configuration code.

---

## 🧠 The Challenge: Static Inventories vs. Dynamic Cloud Fleets

### Why Static Inventories Fail in the Cloud

| Operational Vector | Static Inventory (`inventory.ini` / `hosts.yml`) | Dynamic Inventory (`docker_inventory.py` / `aws_ec2.yml`) |
| :--- | :--- | :--- |
| **IP Address Management** | Hardcoded static IPs; breaks when nodes scale, restart, or recreate. | Queries cloud API / Docker daemon at runtime; always accurate. |
| **Auto Scaling Integration** | Requires manual file edits or complex external sync scripts. | Automatically includes new instances the second they enter running state. |
| **Fleet Slicing** | Host groups are static and rigid. | Instances are dynamically sorted into groups based on multiple multidimensional tags. |
| **Maintenance Overhead** | High; files quickly suffer configuration drift and stale references. | Zero; infrastructure state is the single source of truth. |
| **Zero-Downtime Reliability** | Risk of applying updates to decommissioned or unresponsive nodes. | Validates real-time instance state and health endpoints before execution. |

---

## ⚙️ Dynamic Inventory Core Architecture: Scripts vs. Plugins

Ansible provides two complementary mechanisms to achieve dynamic inventory discovery:

### 1. Dynamic Inventory Scripts (Executable JSON Spec)

An executable script (in Python, Go, or Bash) that Ansible runs during inventory collection. When invoked, it must support two CLI flags:

- `--list`: Outputs a JSON dictionary containing all groups, host arrays, and `_meta.hostvars`.
- `--host <hostname>`: Outputs a JSON dictionary containing host-specific variables (optional when `_meta` is populated in `--list`).

Our included script [`docker_inventory.py`](docker_inventory.py) discovers local Docker containers tagged with `devops.fleet=ansible-dynamic-inventory` and returns:

```json
{
  "_meta": {
    "hostvars": {
      "web-prod-01": {
        "ansible_connection": "docker",
        "ansible_host": "web-prod-01",
        "environment_tag": "production",
        "role_tag": "web",
        "app_version": "1.0.0",
        "health_endpoint": "http://localhost:8080/health"
      }
    }
  },
  "all": {
    "children": ["ungrouped", "env_production", "env_staging", "role_web", "role_api", "role_db"]
  },
  "env_production": {
    "hosts": ["web-prod-01", "web-prod-02", "api-prod-01", "db-prod-01"]
  },
  "role_web": {
    "hosts": ["web-prod-01", "web-prod-02", "web-stage-01"]
  }
}
```

### 2. Dynamic Inventory Plugins (YAML Configuration)

The modern, high-performance standard in Ansible. Inventory plugins (e.g. `amazon.aws.aws_ec2`, `azure.azcollection.azure_rm`, `google.cloud.gcp_compute`) parse declarative YAML configuration files with built-in caching, authentication, and grouping logic.

Our included configuration [`aws_ec2.yml`](aws_ec2.yml) demonstrates how to configure the official AWS EC2 inventory plugin:

```yaml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
  - us-west-2
filters:
  instance-state-name:
    - running
  tag:Project:
    - "DevOps-SRE-Fleet"
```

---

## 🏷️ Tag-Based Fleet Grouping & Metadata Composition

In cloud fleets, instances are classified by multidimensional metadata tags. Dynamic inventories translate these tags into actionable Ansible groups and variables:

```text
┌─────────────────────────┐
│     Cloud Instance      │
├─────────────────────────┤
│ Name: web-prod-01       │
│ Tag: Environment = prod │ ──► Dynamic Group: env_production
│ Tag: Role = web         │ ──► Dynamic Group: role_web
│ Tag: App = frontend     │ ──► Dynamic Group: app_frontend
│ Tag: Cluster = alpha    │ ──► Composite: env_production_role_web
└─────────────────────────┘
```

### Key Dynamic Inventory Directives

1. **`keyed_groups`**: Automatically creates inventory groups by evaluating object attributes or tags:

   ```yaml
   keyed_groups:
     - prefix: env
       key: tags.Environment
     - prefix: role
       key: tags.Role
   ```

2. **`compose`**: Constructs custom variables dynamically in memory for each host:

   ```yaml
   compose:
     ansible_host: public_ip_address | default(private_ip_address)
     health_url: "'http://' + (public_ip_address) + ':8080/health'"
   ```

3. **`groups`**: Creates conditional groups based on Jinja2 expressions:

   ```yaml
   groups:
     production_web_fleet: "'production' in tags.Environment and 'web' in tags.Role"
   ```

---

## 🔄 Zero-Downtime Rolling Updates with Serial Concurrency

Deploying updates across an entire fleet simultaneously causes immediate downtime. A **Rolling Update** replaces or upgrades servers in batches while remaining instances continue serving live user traffic.

```mermaid
sequenceDiagram
    autonumber
    actor SRE as SRE / CI Runner
    participant Ansible as Ansible Controller (serial: 1)
    participant Node1 as web-prod-01 (Active)
    participant Node2 as web-prod-02 (Active)

    Note over SRE,Node2: Batch 1: Target web-prod-01
    SRE->>Ansible: ansible-playbook rolling_update.yml
    Ansible->>Node1: GET /health (Pre-Check: Verify 200 OK)
    Node1-->>Ansible: 200 OK (Healthy, v1.0.0)
    Note over Node1: Node 2 continues serving all traffic
    Ansible->>Node1: Deploy v2.0.0 Patch & Reload Service
    Ansible->>Node1: GET /health (Post-Check: Poll until 200 OK)
    Node1-->>Ansible: 200 OK (Healthy, v2.0.0)

    Note over SRE,Node2: Batch 2: Target web-prod-02
    Ansible->>Node2: GET /health (Pre-Check: Verify 200 OK)
    Node2-->>Ansible: 200 OK (Healthy, v1.0.0)
    Note over Node1: Node 1 now active on v2.0.0
    Ansible->>Node2: Deploy v2.0.0 Patch & Reload Service
    Ansible->>Node2: GET /health (Post-Check: Poll until 200 OK)
    Node2-->>Ansible: 200 OK (Healthy, v2.0.0)

    Ansible-->>SRE: ✅ Fleet Rolling Update Complete: 100% Availability Maintained
```

### Safety Guardrails in `rolling_update.yml`

- **`serial: 1`**: Enforces sequential execution. Only one node is updated at any time.
- **`max_fail_percentage: 0`**: If a single batch fails its post-update health check, execution aborts immediately to protect the remaining fleet.
- **Pre-Update Health Check**: Verifies that the node is healthy before making changes.
- **Post-Update Polling with Backoff**: Polls `/health` with retries (`retries: 10, delay: 2`) to allow service warm-up before marking the batch complete.

---

## 🏛️ Architecture & Fleet Topology Flow

```mermaid
graph TD
    subgraph FleetNodes ["☁️ Simulated Cloud Server Fleet"]
        WP1["web-prod-01\n(Env: prod, Role: web)\nPort: 8081"]
        WP2["web-prod-02\n(Env: prod, Role: web)\nPort: 8082"]
        WS1["web-stage-01\n(Env: stage, Role: web)\nPort: 8083"]
        AP1["api-prod-01\n(Env: prod, Role: api)\nPort: 8084"]
        DB1["db-prod-01\n(Env: prod, Role: db)\nPort: 8085"]
    end

    subgraph DynamicEngine ["🔍 Dynamic Inventory Engine"]
        DIS["docker_inventory.py\n(CLI JSON Spec)"]
        AEC2["aws_ec2.yml\n(AWS Plugin Spec)"]
    end

    subgraph AnsibleControl ["⚙️ Ansible Automation Engine"]
        CFG["ansible.cfg\n(Local Containment)"]
        ROLE["roles/fleet_app/\n(Deploy, Health & Config)"]
        ROLL["rolling_update.yml\n(serial: 1, Zero-Downtime)"]
        SITE["site.yml\n(Master Fleet Baseline)"]
    end

    FleetNodes -->|Labels & Tags| DIS
    DIS -->|Dynamic JSON Graph| AnsibleControl
    AnsibleControl -->|Targeted Orchestration| FleetNodes
```

---

## 📂 Directory & File Structure

```text
06-infrastructure-as-code/06-ansible-dynamic-inventory-cloud/
├── .gitignore                      # Ignores local .ansible caches, logs, and temp files
├── README.md                       # Comprehensive educational documentation
├── ansible.cfg                     # Local Ansible configuration with strict containment
├── aws_ec2.yml                     # Production AWS EC2 Dynamic Inventory Plugin definition
├── cleanup.sh                      # Standalone resource teardown and sanitation script
├── docker_inventory.py             # Executable Python Dynamic Inventory script
├── fleet_manager.sh                # CLI utility to build, run, scale, and inspect fleet nodes
├── rolling_update.yml              # Zero-downtime rolling update playbook (serial: 1)
├── site.yml                        # Master baseline fleet configuration playbook
├── test_dynamic_fleet.sh           # End-to-end automated test runner (12 verification checks)
├── roles/
│   └── fleet_app/                  # Modular application deployment role
│       ├── defaults/main.yml       # Default application variables (target version, ports)
│       ├── handlers/main.yml       # Service reload notification handlers
│       ├── tasks/main.yml          # Configuration deployment & handler triggers
│       └── templates/config.json.j2 # Dynamic JSON application configuration
└── test_environment/
    ├── Dockerfile                  # Lightweight Python 3 simulated cloud target node
    ├── app.py                      # HTTP microservice with /health, /version, /drain, /status
    └── entrypoint.sh               # Container runtime entrypoint script
```

---

## 💻 Prerequisites & Environment Setup

To run this mini-project locally with zero cloud costs, ensure the following tools are installed:

1. **Docker / OrbStack**: Container runtime to host simulated fleet nodes.
2. **Python 3.10+**: Runtime for the dynamic inventory script.
3. **Ansible & Ansible CLI** (`ansible`, `ansible-inventory`, `ansible-playbook`): Core automation engine.
4. **curl & bash**: Command-line utilities for inspection and testing.

Verify your environment:

```bash
docker --version
python3 --version
ansible --version
```

---

## 🚀 Step-by-Step Hands-On Guide

### Step 1: Provision the Simulated Cloud Fleet

Launch the 5-node simulated cloud fleet using the fleet manager:

```bash
./fleet_manager.sh up
```

This builds the lightweight container image and provisions five nodes with distinct tags:

- `web-prod-01`: Environment=`production`, Role=`web`, Port=`8081`
- `web-prod-02`: Environment=`production`, Role=`web`, Port=`8082`
- `web-stage-01`: Environment=`staging`, Role=`web`, Port=`8083`
- `api-prod-01`: Environment=`production`, Role=`api`, Port=`8084`
- `db-prod-01`: Environment=`production`, Role=`db`, Port=`8085`

Inspect the active fleet:

```bash
./fleet_manager.sh status
```

### Step 2: Query the Dynamic Inventory via CLI

Test the executable dynamic inventory script directly using the official `--list` flag:

```bash
./docker_inventory.py --list
```

Notice how `docker_inventory.py` queries running Docker containers and outputs a fully structured JSON payload with `env_*`, `role_*`, `app_*` groups and `_meta.hostvars`.

Inspect host variables for a single host:

```bash
./docker_inventory.py --host web-prod-01
```

### Step 3: Visualize the Inventory Graph

Use the `ansible-inventory` CLI tool to visualize the hierarchical group structure generated dynamically:

```bash
ansible-inventory --graph
```

Example output:

```text
@all:
  |--@app_backend:
  |  |--api-prod-01
  |--@app_datastore:
  |  |--db-prod-01
  |--@app_frontend:
  |  |--web-prod-01
  |  |--web-prod-02
  |  |--web-stage-01
  |--@env_production:
  |  |--api-prod-01
  |  |--db-prod-01
  |  |--web-prod-01
  |  |--web-prod-02
  |--@env_staging:
  |  |--web-stage-01
  |--@role_api:
  |  |--api-prod-01
  |--@role_db:
  |  |--db-prod-01
  |--@role_web:
  |  |--web-prod-01
  |  |--web-prod-02
  |  |--web-stage-01
  |--@ungrouped:
```

### Step 4: Test Dynamic Connectivity & Pattern Matching

Execute an Ansible ping against all dynamically discovered hosts:

```bash
ansible all -m ping
```

Target only **Production Web** nodes using Ansible pattern intersection (`env_production:&role_web`):

```bash
ansible "env_production:&role_web" -m command -a "cat /app/version.txt"
```

Notice that only `web-prod-01` and `web-prod-02` respond, while `web-stage-01` and other roles are ignored.

### Step 5: Execute the Zero-Downtime Rolling Update Playbook

Upgrade the production web fleet to version `2.0.0` sequentially using `serial: 1`:

```bash
ansible-playbook rolling_update.yml -e "app_target_version=2.0.0"
```

Observe the execution in the terminal:

1. Ansible selects `web-prod-02` as batch 1.
2. It verifies `http://127.0.0.1:8080/health` returns HTTP 200.
3. It updates configuration and version files.
4. It polls the health endpoint until healthy.
5. It proceeds to `web-prod-01` as batch 2 and repeats the verification.

Verify that the production web nodes were updated while staging and API nodes were preserved:

```bash
./fleet_manager.sh status
```

### Step 6: Simulate Auto-Scaling & Instant Dynamic Discovery

In a real cloud environment, an Auto Scaling Group launches new instances automatically. Simulate an auto-scaling event by launching `web-prod-03`:

```bash
./fleet_manager.sh scale --name web-prod-03 --env production --role web --port 8086
```

Immediately re-run `ansible-inventory --graph`:

```bash
ansible-inventory --graph
```

Notice `web-prod-03` is immediately present inside `@env_production` and `@role_web` **without modifying any configuration file or static host list!**

Ping the new host directly:

```bash
ansible web-prod-03 -m ping
```

### Step 7: Run the Master Baseline Playbook

Apply baseline configuration parameters across the entire multi-tier fleet:

```bash
ansible-playbook site.yml
```

---

## ☁️ Deploying to Production AWS EC2 Fleets

The file [`aws_ec2.yml`](aws_ec2.yml) is ready for use with live AWS EC2 fleets.

### 1. Required AWS IAM Permissions

Attach the following minimal IAM policy to the DevOps IAM user or CI/CD assume role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AnsibleEC2DynamicInventoryDiscovery",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeTags",
        "ec2:DescribeRegions",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    }
  ]
}
```

### 2. Configure AWS CLI Credentials

```bash
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_REGION="us-east-1"
```

### 3. Query AWS EC2 Fleets Dynamically

Install the required Ansible AWS collection (if not already installed):

```bash
ansible-galaxy collection install amazon.aws
```

Query and graph your live AWS EC2 inventory:

```bash
ansible-inventory -i aws_ec2.yml --graph
```

Execute the rolling update against live AWS EC2 production web nodes:

```bash
ansible-playbook -i aws_ec2.yml rolling_update.yml --limit "tag_Environment_production:&tag_Role_web"
```

---

## 🧪 Automated Testing & Verification Suite

The included test runner [`test_dynamic_fleet.sh`](test_dynamic_fleet.sh) executes an automated 12-step verification suite:

```bash
./test_dynamic_fleet.sh
```

### Verification Checks Performed

```text
======================================================================
  🧪 Ansible Dynamic Inventory for Cloud Fleets - Test Suite
======================================================================

▶ Step 1: Checking system prerequisites...
  [PASS] Test 1: All prerequisites verified (Docker daemon, Python 3, Ansible tools, curl)

▶ Step 2: Provisioning simulated cloud fleet (5 nodes)...
  [PASS] Test 2: Provisioned 5 fleet nodes (web-prod-01/02, web-stage-01, api-prod-01, db-prod-01)
         ↳ Active containers: 5

▶ Step 3: Validating Dynamic Inventory JSON Output (--list)...
  [PASS] Test 3: docker_inventory.py conforms to Ansible Dynamic Inventory JSON spec
         ↳ Discovered 5 hosts with hostvars

▶ Step 4: Generating Ansible inventory graph (ansible-inventory --graph)...
  [PASS] Test 4: Ansible successfully generated hierarchical inventory graph

▶ Step 5: Asserting dynamic group memberships...
  [PASS] Test 5: Tag-based dynamic groups (env_*, role_*) partitioned correctly
         ↳ Production: 4 hosts, Staging: 1 host, Web: 3 hosts

▶ Step 6: Testing host variable resolution (ansible-inventory --host)...
  [PASS] Test 6: Dynamic hostvars injected correctly (connection=docker, env=production, role=web)

▶ Step 7: Testing dynamic fleet ping connectivity (ansible -m ping all)...
  [PASS] Test 7: All dynamically discovered nodes responded to Ansible ping

▶ Step 8: Testing composite pattern execution ('env_production:&role_web')...
  [PASS] Test 8: Targeted composite pattern ('env_production:&role_web') selected exact nodes
         ↳ Matched: web-prod-01, web-prod-02

▶ Step 9: Executing Rolling Update Playbook (serial: 1, version: 2.0.0)...
  [PASS] Test 9: Rolling update playbook executed successfully with serial: 1

▶ Step 10: Verifying post-update versions & target isolation...
  [PASS] Test 10: Target isolation verified (prod web updated to 2.0.0; stage/api preserved at 1.0.0)

▶ Step 11: Simulating Auto-Scaling event (provisioning web-prod-03)...
  [PASS] Test 11: Auto-scaled node 'web-prod-03' discovered dynamically and reachable
         ↳ Instant discovery with 0 configuration file edits

▶ Step 12: Testing cleanup and resource teardown...
  [PASS] Test 12: Cleanup script purged all fleet containers, network, and temporary caches

======================================================================
  🎉 ALL 12 TESTS PASSED! (12/12)
======================================================================
```

---

## ❓ Troubleshooting & FAQs

### 1. `docker_inventory.py` returns empty groups

- **Cause**: No containers are running with the label `devops.fleet=ansible-dynamic-inventory`.
- **Fix**: Run `./fleet_manager.sh up` or inspect running labels with `docker ps --filter "label=devops.fleet"`.

### 2. `ansible -m ping all` fails with `Failed to find python interpreter`

- **Cause**: Python 3 is installed in a non-standard path inside the container.
- **Fix**: Ensure `docker_inventory.py` populates `ansible_python_interpreter: /usr/local/bin/python3` in `_meta.hostvars`.

### 3. Port conflict when running `./fleet_manager.sh up`

- **Cause**: Local ports 8081–8085 are already bound by other applications on your host.
- **Fix**: Free the conflicting ports or adjust the port mappings in `DEFAULT_NODES` inside [`fleet_manager.sh`](fleet_manager.sh).

### 4. How do I keep fleet containers running after tests?

- **Fix**: Pass the `--keep` flag to the test suite:

  ```bash
  ./test_dynamic_fleet.sh --keep
  ```

---

## 🧹 Teardown & Cleanup

After finishing all tests and experiments, clean up all created resources to leave your local environment completely clean for subsequent mini-projects:

### Fast Cleanup (Containers & Networks)

```bash
./cleanup.sh
```

### Full Purge (Containers, Network, Docker Images, and Local Caches)

```bash
./cleanup.sh --all
```

The cleanup script guarantees:

- All test containers (`web-prod-*`, `web-stage-*`, `api-prod-*`, `db-prod-*`) are stopped and removed.
- The custom Docker bridge network (`ansible-fleet-net`) is deleted.
- The custom Docker test image (`ansible-fleet-node:latest`) is purged (when `--all` is used).
- Local Ansible temporary caches (`.ansible/`) and execution logs (`logs/`) within this project directory are purged.
- Zero dangling files, volumes, or processes remain on your system.
