# Mini-Project 10: Unified DevOps Toolkit CLI

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Multi-Container Docker Bridge / macOS)  

---

## 🎯 Overview & Context

In high-velocity engineering organizations and Site Reliability Engineering (SRE) teams, engineers frequently accumulate dozens of ad-hoc bash scripts, Python helpers, and one-off diagnostic tools. This **script sprawl** introduces significant operational risks:

- Lack of uniform CLI ergonomics and help documentation.
- Inconsistent exit codes breaking CI/CD deployment pipelines.
- Fragmented outputs that cannot be reliably piped to JSON parsers (`jq`) or monitoring agents.
- Missing concurrency controls causing connection timeouts when diagnosing multi-node clusters.

### What This Mini-Project Implements

This project delivers **`devops-cli`**, a consolidated, production-grade DevOps engineering CLI implemented in **Go** (compiled static binary) and **Python 3** that merges four essential operational workflows into a single standardized toolkit:

1. **`devops-cli sys health`**: Cross-platform hardware and OS diagnostics (CPU cores, load averages, memory and swap utilization, disk mount points, active processes, and zombie process detection).
2. **`devops-cli log stats`**: Access log aggregation engine that extracts status code distributions (2xx, 3xx, 4xx, 5xx), error rates, top requested endpoints, top client IPs, and latency percentiles (P50, P90, P99).
3. **`devops-cli ssh run`**: Parallel multi-host SSH execution pool with worker concurrency controls and per-host timeout management.
4. **`devops-cli cost estimate`**: Cloud infrastructure cost estimator that parses resource manifests and produces monthly/annual cost forecasts with automated Graviton/arm64 right-sizing recommendations.
5. **`devops-cli completion`**: Shell autocompletion generator for `bash` and `zsh`.

---

## 🧠 CLI Engineering & Systems Architecture Deep-Dive

### 1. The 12-Factor CLI Engineering Standard

`devops-cli` adheres to modern CLI engineering standards:

```text
                                 [ User Command / CI Runner ]
                                              |
                     +------------------------+------------------------+
                     |                        |                        |
                     v                        v                        v
             [ stdout (FD 1) ]        [ stderr (FD 2) ]        [ Exit Codes ]
                     |                        |                        |
             Structured Data           Diagnostic Logs          0 = Success
           (JSON, Tables, GFM)        & Actionable Errors       1 = Warning / Alert
                     |                        |                 3 = Usage / Syntax Error
                     v                        v
            Pipeable to 'jq'           Visible in Logs
```

- **Clean I/O Separation**: Program data is emitted to `stdout`, allowing seamless piping (`devops-cli sys health --json | jq .cpu`). Diagnostic logs and errors are routed exclusively to `stderr`.
- **Deterministic Exit Codes**:
  - `0`: Operation succeeded or all system metrics are within normal operational limits.
  - `1`: Warning threshold triggered (e.g. high CPU/RAM load, detected zombies, or HTTP error rate > 5%).
  - `3`: Missing input files, invalid arguments, or execution error.

---

### 2. Multi-Host SSH Execution Worker Pool

When executing commands across multiple servers, sequential loops scale linearly with latency ($O(N \times \text{RTT})$). `devops-cli` uses a **Worker Pool pattern** with bounded concurrency:

```text
Target Hosts [Node 1, Node 2, Node 3, ... Node N]
                     |
            [ Work Channel / Queue ]
                     |
         +-----------+-----------+
         |           |           |
     [Worker 1]  [Worker 2]  [Worker 3]  (Max Concurrency: e.g. 5)
         |           |           |
         +-----------+-----------+
                     |
          [ Aggregated Results Map ]
         (Grouped by Host & Exit Code)
```

---

## 📂 Project Structure

```text
01-linux-scripting/10-unified-devops-toolkit-cli/
├── devops_cli.py                # Unified Python CLI implementation (Click/Argparse pattern)
├── main.go                      # Production-grade Go codebase compiling to devops-cli binary
├── go.mod                       # Go module definition
├── fixtures/                    # Test data fixtures
│   ├── sample_access.log        # Sample web access log with status codes and latency
│   ├── sample_infra.json        # Cloud infrastructure manifest for cost estimation
│   └── inventory.txt            # Multi-host SSH target manifest
├── mock_cluster/                # Multi-node Docker Compose SSH test environment
│   ├── node1/
│   │   ├── Dockerfile
│   │   └── entrypoint.sh
│   ├── node2/
│   │   ├── Dockerfile
│   │   └── entrypoint.sh
│   └── docker-compose.yml
├── test_devops_cli.sh           # Automated test runner (15 assertions across all subcommands)
├── Dockerfile                   # Isolated container definition with compiled Go & Python CLIs
├── docker-compose.yml           # Root orchestration
├── .markdownlint.json           # Linter configuration (MD013/MD033 disabled)
└── README.md                    # Educational guide, CLI architecture & cleanup instructions
```

---

## 🚀 Quickstart & Hands-On Usage

### Step 1: Compile the Go Binary or Use the Python CLI

Compile the standalone Go binary:

```bash
chmod +x devops_cli.py test_devops_cli.sh
go build -o devops-cli main.go
```

Verify version metadata:

```bash
# Go binary
./devops-cli version

# Python CLI
./devops_cli.py --version
```

---

### Step 2: System Health Diagnostics (`sys health`)

Inspect local hardware, memory, load averages, and process lifecycles:

```bash
# Formatted ANSI Terminal Table
./devops-cli sys health

# Machine-Readable JSON Output
./devops-cli sys health --json | jq .

# Markdown Table Summary
./devops_cli.py sys health --markdown
```

Sample output:

```text
========================================================================================================
                               DEVOPS-CLI: SYSTEM HEALTH (GO EDITION)                                   
========================================================================================================
Host     : Fabians-MacBook-Air.local (darwin/arm64)
Status   : [ HEALTHY ]

1. CPU SUBSYSTEM:
  - Cores         : 8
  - Load Averages : 1m: 1.25 | 5m: 1.45 | 15m: 1.80 (15.6% load)

2. MEMORY SUBSYSTEM:
  - RAM Usage     : 9830 MB / 16384 MB (60.0% utilized)

3. ACTIVE PROCESSES:
  - Total Count   : 627 (Zombies: 0)
```

---

### Step 3: Web Access Log Analytics (`log stats`)

Analyze web access logs to compute status code distributions, error rates, and latency percentiles:

```bash
# Analyze sample access log
./devops-cli log stats -f fixtures/sample_access.log

# Filter exclusively for 5xx server errors
./devops_cli.py log stats -f fixtures/sample_access.log -s 5xx --json

# Display top 10 endpoints and top 10 client IPs
./devops-cli log stats -f fixtures/sample_access.log --top 10
```

Sample output:

```text
========================================================================================================
                               DEVOPS-CLI: LOG ANALYTICS REPORT                                         
========================================================================================================
Log File : fixtures/sample_access.log
Analyzed : 15 total requests (6 unique client IPs)

1. HTTP STATUS CODE DISTRIBUTION:
  - 2xx (Success)    : 9
  - 3xx (Redirect)   : 1
  - 4xx (Client Err) : 3
  - 5xx (Server Err) : 2
  - Overall Error Rate: 33.33%

2. TOP REQUESTED ENDPOINTS:
  - /api/v1/health                      : 2 requests
  - /api/v1/users                       : 2 requests
  - /api/v1/reports/monthly             : 2 requests

3. TOP CLIENT IP ADDRESSES:
  - 192.168.1.10              : 6 requests
  - 10.0.0.15                 : 3 requests

4. RESPONSE LATENCY PERCENTILES:
  - P50 (Median) : 25.0 ms
  - P90          : 850.0 ms
  - P99          : 1250.0 ms
```

---

### Step 4: Parallel Multi-Host SSH Execution (`ssh run`)

Execute commands across an inventory of servers concurrently:

```bash
# Run command across inventory file with 5 worker threads
./devops-cli ssh run "uptime" -i fixtures/inventory.txt -c 5

# Run command across comma-separated hosts with JSON output
./devops-cli ssh run "uname -a" -H "127.0.0.1,localhost" --json
```

---

### Step 5: Cloud Infrastructure Cost Estimation (`cost estimate`)

Evaluate cloud resource manifests (VM instances, storage, and egress bandwidth):

```bash
# Calculate monthly/annual costs
./devops-cli cost estimate -f fixtures/sample_infra.json

# Machine-readable JSON output for automated budget alerts
./devops-cli cost estimate -f fixtures/sample_infra.json --json
```

Sample output:

```text
========================================================================================================
                          DEVOPS-CLI: CLOUD INFRASTRUCTURE COST ESTIMATE                                 
========================================================================================================
Project  : ecommerce-production-stack
Estimate : $1,738.90 / month ($20,866.75 / year USD)

RESOURCE NAME                   TYPE          COUNT     MONTHLY COST
--------------------------------------------------------------------------------------------------------
api-gateway-cluster             compute       3         $364.42
db-primary-postgres             compute       1         $367.92
db-persistent-storage           storage       1         $40.00
redis-cache-cluster             compute       2         $198.56
outbound-cdn-egress             bandwidth     1         $768.00
--------------------------------------------------------------------------------------------------------

💡 SRE RIGHT-SIZING & COST OPTIMIZATION RECOMMENDATIONS:
  - Consider migrating 'api-gateway-cluster' (t3.xlarge) to Graviton arm64 (e.g. t4g/m6g) for ~20% cost reduction.
```

---

### Step 6: Shell Autocompletion Setup (`completion`)

Generate autocompletion scripts for your shell:

```bash
# For Bash (Add to ~/.bashrc)
./devops-cli completion bash > /tmp/devops-cli-completion.bash
source /tmp/devops-cli-completion.bash

# For Zsh (Add to ~/.zshrc)
./devops-cli completion zsh > ~/.zfunc/_devops-cli
```

---

### Step 7: Run in Containerized Lab (Docker Compose)

Launch the multi-node SSH mock cluster and run the containerized toolkit:

```bash
docker compose up --build --abort-on-container-exit
```

---

## 🔄 CI/CD Quality Gates & Automation

Integrate `devops-cli` into GitHub Actions deployment workflows for automated pre-deployment sanity checks:

```yaml
name: "Infrastructure Health & Log Audit"

on:
  push:
    branches: [ main ]

jobs:
  devops-audit:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: "1.23"

      - name: Build Unified CLI
        run: |
          cd 01-linux-scripting/10-unified-devops-toolkit-cli
          go build -o /usr/local/bin/devops-cli main.go

      - name: System Health Diagnostic
        run: devops-cli sys health --json

      - name: Audit Staging Access Logs
        run: |
          devops-cli log stats \
            -f 01-linux-scripting/10-unified-devops-toolkit-cli/fixtures/sample_access.log \
            --json
```

---

## 🧪 Automated Testing Suite

The project includes an end-to-end automated test runner (`test_devops_cli.sh`) with 15 test assertions:

```bash
./test_devops_cli.sh
```

### Test Coverage Highlights

1. **Compilation & Metadata**: Asserts Go build succeeds and reports semantic version 1.0.0.
2. **System Health Metrics**: Validates CPU, RAM, and process data structures in Go and Python.
3. **Log Analytics Engine**: Validates parsing of 15 requests, 6 unique IPs, status codes, and P50/P90/P99 latency percentiles.
4. **Cloud Cost Modeling**: Verifies accurate calculation of $1,738.90/month and right-sizing recommendations.
5. **Autocompletion Generators**: Confirms valid shell script generation for Bash and Zsh.
6. **Parallel SSH Worker Pool**: Tests concurrent multi-target dispatching.

---

## 🧹 Teardown & Resource Cleanup

To remove all Docker containers, networks, images, compiled binaries, and temporary files generated during testing:

### 1. Remove Docker Containers, Networks, and Images

```bash
# Stop and remove all Docker Compose lab resources
docker compose down -v --rmi all
```

### 2. Remove Compiled Binary and Temporary Files

```bash
# Remove compiled Go binary and test reports
rm -f devops-cli .test_out.json .test_sys.json .test_log.json
```

### 3. Verify Clean State

```bash
# Confirm no lingering lab containers
docker ps -a | grep -E "mock_ssh_node1|mock_ssh_node2|devops_toolkit_runner" || echo "✔ No lingering lab containers"

# Confirm no lingering Docker images
docker images | grep -E "mock-ssh-node1|mock-ssh-node2|unified-devops-toolkit" || echo "✔ No lingering Docker images"
```

---

## 📚 Key Takeaways & Best Practices

1. **Consolidate Tools into a Single CLI**: Unifying operations into a cohesive binary reduces context switching and simplifies automated pipeline integrations.
2. **Support Multiple Output Formats**: Human operators prefer rich ANSI tables; automated scripts and monitoring agents require JSON. Always support both.
3. **Control Concurrency in Network Pools**: Unbounded parallelism can overwhelm remote hosts or local network interfaces. Always use bounded worker pools with timeouts.
4. **Automate Shell Autocompletion**: Providing shell completion drastically improves developer productivity and prevents command syntax errors in production bastions.
