# Mini-Project 07: Network Port Scanner and Troubleshooter

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Docker Bridge Network / macOS)  

---

## 🎯 Overview & Context

In Site Reliability Engineering (SRE), Cloud Infrastructure, and Distributed Systems, **network connectivity failures are among the most frequent and elusive causes of production incidents**. When a service cannot communicate with an upstream API, database cluster, or cache instance, engineers must determine:

- Is the target daemon crashed or not listening? (**`CLOSED`**)
- Is an AWS Security Group, Kubernetes NetworkPolicy, or host `iptables` firewall silently dropping packets? (**`FILTERED`**)
- Is the service running, reachable, and returning expected protocol handshakes? (**`OPEN`**)
- Is DNS resolution failing or introducing severe latency into the request pipeline?

Relying on heavyweight external tools like `nmap` is not always feasible on stripped-down cloud containers, minimal Kubernetes pods, or locked-down production bastions.

### What This Mini-Project Implements

This project delivers a **non-blocking, high-concurrency network auditing and troubleshooting engine** built from first principles in **Python 3 (`asyncio`)**, **Go (goroutines & worker pools)**, and pure **POSIX/Bash (`/dev/tcp`)**.

Key capabilities:

1. **Three-State TCP Port Diagnostics**: Differentiates between `OPEN` (SYN-ACK), `CLOSED` (TCP RST packet received), and `FILTERED` (silent packet drop / timeout).
2. **Asynchronous Non-Blocking Scanning**: Scans hundreds of ports and CIDR blocks (`172.28.0.0/28`) concurrently in under 1 second.
3. **Automated Service Banner Grabbing**: Probes and extracts application identification strings (HTTP server headers, OpenSSH daemon strings, PostgreSQL protocol greetings, Redis `PING`/`PONG`).
4. **DNS Latency Profiling**: Benchmarks A and AAAA DNS resolution latency in milliseconds.
5. **Multi-Format Reporting**: Emits rich ANSI color terminal tables, GitHub Flavored Markdown (`--markdown`), machine-readable JSON (`--json`), and Prometheus / OpenMetrics format (`--prometheus`).
6. **Multi-Container Mock Network Grid**: Includes a Docker Compose bridge network (`172.28.0.0/24`) hosting mock Web, Database, and Filtered Gateway services (with real `iptables -j DROP` rules).
7. **CI/CD Quality Gate Assertions**: Supports `--require-open <port>` with deterministic exit codes (`0` = healthy, `1` = port down, `3` = scan error).

---

## 🧠 Networking Internals & Packet Mechanics Deep-Dive

### 1. The TCP 3-Way Handshake & Port States

Transmission Control Protocol (TCP, RFC 793) is a connection-oriented transport protocol. A connection is established using a three-way handshake:

```text
Client (net_troubleshoot)                          Server / Firewall
         |                                                 |
         | -------------- 1. [SYN] (Seq=X) --------------> |
         |                                                 |
         | <--- 2. [SYN-ACK] (Seq=Y, Ack=X+1) [OPEN] ----- |
         |                                                 |
         | -------------- 3. [ACK] (Ack=Y+1) ------------> |
         |                                                 |
[Connection Established]                           [Socket Connected]
```

### 2. How the Linux Kernel Handles Closed and Filtered Ports

When a client sends a `SYN` packet to a host, three distinct outcomes can occur:

```text
                                [ Client sends TCP SYN ]
                                           |
                   +-----------------------+-----------------------+
                   |                       |                       |
                   v                       v                       v
          [ Port is Listening ]    [ Port is NOT Bound ]   [ Firewall Filter / DROP ]
                   |                       |                       |
         Server sends SYN-ACK      Kernel sends TCP RST    Firewall silently drops packet
                   |                       |                       |
             Client marks:           Client marks:           Client times out & marks:
               [ OPEN ]                [ CLOSED ]                 [ FILTERED ]
```

#### The Differences Between CLOSED, FILTERED, and REJECTED

| Port State | Underlying Kernel / Network Behavior | Client Symptom | Typical Root Cause |
| :--- | :--- | :--- | :--- |
| **`OPEN`** | The application socket is bound and in `LISTEN` state. Server responds with `SYN-ACK`. | Instant connection success (RTT < 2ms). | Service is healthy and listening. |
| **`CLOSED`** | The kernel receives a SYN for an unbound port. The kernel immediately sends a `RST` (Reset) packet. | Instant `ConnectionRefusedError` (RTT < 2ms). | Application crashed, stopped, or listening on wrong interface (`127.0.0.1` vs `0.0.0.0`). |
| **`FILTERED`** | A firewall rule (`iptables -j DROP`, AWS Security Group) discards the packet without responding. | Client retransmits SYN until timeout (e.g. 1000ms). | Security group missing ingress rule, firewall block, or unrouted IP. |
| **`REJECTED`** | A firewall rule (`iptables -j REJECT`) sends an ICMP `Destination Unreachable` packet. | Fast ICMP Port Unreachable error. | Explicit firewall reject rule. |

---

### 3. Service Banner Grabbing Mechanics

Once a TCP handshake completes on an `OPEN` port, `net_troubleshoot` inspects the protocol banner:

1. **Unsolicited Banners**: Protocols like SSH (RFC 4253), SMTP (RFC 5321), and FTP immediately transmit a server identification string upon connection:

   ```text
   SSH-2.0-OpenSSH_9.9
   220 mail.example.com ESMTP Postfix
   ```

2. **Probe-Triggered Banners**: Protocols like HTTP, Redis, and PostgreSQL wait for client data. The scanner transmits lightweight protocol probes:
   - **HTTP (Ports 80, 8080, 443)**: `HEAD / HTTP/1.0\r\nHost: <host>\r\n\r\n` $\rightarrow$ parses `Server: nginx/1.27.5`.
   - **Redis (Port 6379)**: `PING\r\n` $\rightarrow$ parses `+PONG\r\n`.
   - **PostgreSQL (Port 5432)**: SSLRequest probe `\x00\x00\x00\x08\x04\xd2\x16\x2f` $\rightarrow$ identifies database backend.

---

## 📂 Project Structure

```text
01-linux-scripting/07-network-port-scanner-troubleshooter/
├── net_troubleshoot.py          # Asynchronous Python scanner (asyncio, banner grabbing, DNS, RTT)
├── net_troubleshoot.go          # Ultra-fast Go scanner using goroutines and worker pools
├── net_troubleshoot.sh          # POSIX / Bash companion script using /dev/tcp and netcat
├── targets.txt                  # Sample target manifest with CIDRs, hostnames, and port ranges
├── test_net_troubleshoot.sh     # Automated test suite (17 assertions, speed benchmarks)
├── Dockerfile                   # Isolated container definition for containerized network scans
├── docker-compose.yml           # Root orchestration (scanner + mock network grid)
├── .markdownlint.json           # Linter configuration (MD013/MD033 disabled)
├── README.md                    # Educational guide, architecture deep-dive & cleanup instructions
└── mock_network_grid/
    ├── web_service/             # Nginx Web & API mock service (Ports 80, 8080)
    │   ├── Dockerfile
    │   └── nginx.conf
    ├── db_service/              # Mock database service (Port 5432 open, 6379 open, 22 closed)
    │   ├── Dockerfile
    │   └── mock_db.py
    ├── secure_gateway/          # Filtered gateway service (Port 22 open, 9999 iptables DROP)
    │   ├── Dockerfile
    │   └── entrypoint.sh
    └── docker-compose.yml       # Standalone Docker Compose bridge network (172.28.0.0/24)
```

---

## 🚀 Quickstart & Hands-On Usage

### Step 1: Start the Local Mock Network Grid

Start the multi-service mock network grid using Docker Compose:

```bash
cd mock_network_grid
docker compose up -d --build
cd ..
```

Verify that the mock network grid is running on host ports:

- `localhost:9080` $\rightarrow$ Web Server (HTTP Nginx)
- `localhost:9081` $\rightarrow$ API Gateway (REST JSON API)
- `localhost:9432` $\rightarrow$ PostgreSQL Database Engine
- `localhost:9379` $\rightarrow$ Redis Key-Value Store
- `localhost:9022` $\rightarrow$ OpenSSH Gateway Daemon
- `localhost:9843` $\rightarrow$ Secure Gateway Management Console
- `localhost:59999` $\rightarrow$ Unused port (CLOSED, sends TCP RST)

---

### Step 2: Run the Python Async Scanner (`net_troubleshoot.py`)

Make all scripts executable:

```bash
chmod +x net_troubleshoot.py net_troubleshoot.sh test_net_troubleshoot.sh
```

#### 1. Scan Mock Endpoints (CLI Table View)

```bash
./net_troubleshoot.py -t 127.0.0.1 -p 9080,9081,9432,9379,9022,9843,59999 --all
```

Sample output:

```text
========================================================================================================
                         NETWORK PORT SCANNER & TROUBLESHOOTER REPORT                                   
========================================================================================================
Scan Time : 2026-08-25 03:07:52 UTC
Execution : 0.704 seconds

DNS RESOLUTION & LATENCY:
  - 127.0.0.1                 -> 127.0.0.1                 [Latency: 0.0 ms]

STATE      TARGET HOST           PORT    SERVICE         RTT        BANNER / DIAGNOSTIC                
--------------------------------------------------------------------------------------------------------
[ OPEN  ]  127.0.0.1             9022    SSH-Mock        0.63 ms    SSH-2.0-OpenSSH_9.9
[ OPEN  ]  127.0.0.1             9080    HTTP-Mock       0.53 ms    Server: nginx/1.27.5
[ OPEN  ]  127.0.0.1             9081    API-Mock        0.48 ms    Server: nginx/1.27.5
[ OPEN  ]  127.0.0.1             9379    Redis-Mock      0.45 ms    Redis Key-Value Store (+PONG)
[ OPEN  ]  127.0.0.1             9432    Postgres-Mock   0.43 ms    PostgreSQL 16.3 (Ubuntu 16.3-1.pgdg22.04+1)
[ OPEN  ]  127.0.0.1             9843    HTTPS-Mock      0.40 ms    Secure Gateway Management Console v2.1
[CLOSED ]  127.0.0.1             59999   Unknown         0.24 ms    Connection refused (TCP RST)
--------------------------------------------------------------------------------------------------------

SUMMARY STATISTICS:
  Total Probes : 7
  ✔ OPEN Ports   : 6
  ○ CLOSED Ports : 1
  ✖ FILTERED Port: 0
  Scan Duration: 0.704s
```

#### 2. Scan with Built-In Port Profiles

Use named profiles (`mock`, `web`, `db`, `common`, `top10`):

```bash
# Scan web ports
./net_troubleshoot.py -t 127.0.0.1 -p web

# Scan database ports
./net_troubleshoot.py -t 127.0.0.1 -p db

# Scan port ranges
./net_troubleshoot.py -t 127.0.0.1 -p 9080-9085
```

#### 3. Scan Entire CIDR Subnets

Scan a subnet block (`/28` = 14 usable host IPs) concurrently:

```bash
./net_troubleshoot.py -t 172.28.0.0/28 -p 80,22,5432 --timeout 0.5
```

#### 4. Export Markdown Table Report (`--markdown`)

```bash
./net_troubleshoot.py -t 127.0.0.1 -p 9080,9081,9432,9379 -m
```

Sample Markdown Output:

```markdown
# Network Port Scan & Troubleshooter Report

- **Scan Timestamp**: `2026-08-25 03:07:52 UTC`
- **Scan Duration**: `0.021 seconds`
- **Total Probes**: `4` (Open: `4`, Closed: `0`, Filtered: `0`)

## Port Status Diagnostics

| Host | Port | Service | State | RTT (ms) | Banner / Details |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `127.0.0.1` | `9080` | `HTTP-Mock` | **`OPEN`** | `0.53 ms` | Server: nginx/1.27.5 |
| `127.0.0.1` | `9081` | `API-Mock` | **`OPEN`** | `0.48 ms` | Server: nginx/1.27.5 |
| `127.0.0.1` | `9379` | `Redis-Mock` | **`OPEN`** | `0.45 ms` | Redis Key-Value Store (+PONG) |
| `127.0.0.1` | `9432` | `Postgres-Mock` | **`OPEN`** | `0.43 ms` | PostgreSQL 16.3 |
```

#### 5. Export JSON & Prometheus Metrics

```bash
# JSON Output (pipe to jq)
./net_troubleshoot.py -t 127.0.0.1 -p 9080,9432 --json | jq '.results[] | {port, service, state, rtt_ms}'

# Prometheus / OpenMetrics Format
./net_troubleshoot.py -t 127.0.0.1 -p 9080,9432 --prometheus
```

#### 6. SRE Port Availability Assertion (`--require-open`)

Assert that required service ports are open in deployment scripts. Exits `0` if all required ports are OPEN, or `1` if any required port is CLOSED or FILTERED:

```bash
./net_troubleshoot.py -t 127.0.0.1 -p 9080,9081 --require-open 9080 --require-open 9081
echo "Exit code: $?" # Returns 0 (OK)
```

---

### Step 3: Run the Compiled Go Scanner (`net_troubleshoot.go`)

For high-throughput environments, run the Go scanner:

```bash
go run net_troubleshoot.go -t 127.0.0.1 -p 9080,9081,9432,9379,9022 --all
```

Markdown export in Go:

```bash
go run net_troubleshoot.go -t 127.0.0.1 -p 9080,9081 -m
```

---

### Step 4: Run the POSIX/Bash Companion (`net_troubleshoot.sh`)

In minimal Linux environments without Python or Go:

```bash
./net_troubleshoot.sh -t 127.0.0.1 -p 9080,9081,9432,9379,9022
```

---

### Step 5: Run with Docker Compose (Containerized Audit)

Audit the internal Docker bridge network directly from an isolated container:

```bash
docker compose up --build --abort-on-container-exit
```

---

## 📊 SRE Observability & Prometheus Monitoring Integration

### Node Exporter Textfile Collector Integration

Schedule periodic network diagnostic scans to export metrics to Prometheus Node Exporter:

```bash
# Periodically run network health probe every 5 minutes
*/5 * * * * /opt/net_troubleshoot/net_troubleshoot.py -t 10.0.0.0/24 -p 80,443,5432 --prometheus --no-fail > /var/lib/node_exporter/textfile_collector/network_scan.prom
```

### Prometheus Alertmanager Rules

Add the following rules to `alerts.yml`:

```yaml
groups:
  - name: network_connectivity_alerts
    rules:
      # Alert when a critical production port becomes unreachable
      - alert: CriticalPortUnreachable
        expr: net_port_state{port=~"80|443|5432", state="open"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Critical service port {{ $labels.port }} on {{ $labels.host }} is DOWN"
          description: "TCP handshake failed. State is {{ $labels.state }} (Service: {{ $labels.service }})."

      # Alert when firewall packet drops are detected
      - alert: PortFilteredByFirewall
        expr: net_port_state{state="filtered"} == 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Firewall packet drop detected on {{ $labels.host }}:{{ $labels.port }}"
          description: "TCP connect timed out. Check Security Group or iptables rules."

      # Alert on slow DNS resolution latency
      - alert: HighDNSResolutionLatency
        expr: net_dns_lookup_latency_seconds > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Slow DNS resolution for {{ $labels.hostname }}"
          description: "DNS resolution took {{ $value }}s (> 100ms)."
```

---

## 🔄 CI/CD Quality Gate & Automation

### Automated Post-Deployment Smoke Test in GitHub Actions

Integrate `net_troubleshoot.py` into deployment workflows to verify that load balancers and services are accepting connections:

```yaml
name: "Post-Deployment Network Validation"

on:
  deployment_status:
  workflow_dispatch:

jobs:
  validate-network:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Audit Ingress and Database Ports
        run: |
          python3 01-linux-scripting/07-network-port-scanner-troubleshooter/net_troubleshoot.py \
            -t "staging-api.mycompany.com" \
            -p "80,443,8080" \
            --require-open 443 \
            --timeout 2.0
```

---

## 🧪 Automated Testing Suite

The project includes an automated end-to-end test suite (`test_net_troubleshoot.sh`) covering 17 assertions across 10 distinct test suites:

```bash
./test_net_troubleshoot.sh
```

### Test Suite Coverage

1. **CLI Flags & Port Range Parsing**: Validates `--help`, missing target files, and exit code 3.
2. **TCP Connect State Accuracy**: Tests `OPEN` (9080), `CLOSED` with RST (59999), and `FILTERED` with timeout (192.0.2.1).
3. **Banner Grabbing Accuracy**: Verifies detection of Nginx, OpenSSH, PostgreSQL, and Redis banners.
4. **DNS Latency Benchmarks**: Validates hostname resolution and latency measurement.
5. **Markdown & JSON Output**: Verifies structured reporting and file writing strictly inside the project directory.
6. **Prometheus Metrics**: Validates OpenMetrics schema compliance.
7. **Performance Benchmark**: Asserts that scanning over 100 ports completes in under 3 seconds.
8. **Go Scanner Parity**: Confirms that `net_troubleshoot.go` produces matching results.
9. **Bash Script Parity**: Confirms that `net_troubleshoot.sh` correctly probes open/closed ports.
10. **`--require-open` Assertion**: Tests SRE exit codes (`0` when open, `1` when closed).

---

## 🧹 Teardown & Resource Cleanup

To ensure a clean environment with zero leftover Docker containers, networks, images, volumes, or temporary test artifacts, execute the following teardown commands:

### 1. Stop and Remove All Docker Containers, Images, and Networks

```bash
# Stop and remove the mock network grid containers, images, and network
docker compose -f mock_network_grid/docker-compose.yml down -v --rmi all

# Stop and remove root compose scanner resources (if used)
docker compose down -v --rmi all
```

### 2. Clean Generated Test Files

```bash
# Remove temporary test reports
rm -f .test_report.md .test_report.json .test_prom.txt
```

### 3. Verify Clean State

```bash
# Confirm no lingering containers
docker ps -a | grep -E "mock_web_server|mock_db_server|mock_secure_gateway|net_troubleshoot_scanner" || echo "✔ No lingering containers found"

# Confirm no lingering images
docker images | grep -E "mock-web-server|mock-db-server|mock-secure-gateway|net-troubleshoot-scanner" || echo "✔ No lingering images found"
```

---

## 📚 Key Takeaways & Best Practices

1. **Differentiate Closed vs. Filtered**: A `CLOSED` port means network routing works and the host is alive, but the application is down. A `FILTERED` port points to firewall or routing packet loss.
2. **Non-Blocking I/O for Fast Scans**: Synchronous socket loops take minutes to scan large subnets due to timeouts. Asynchronous non-blocking scanners (`asyncio`, goroutines) complete the same scan in milliseconds.
3. **Combine Probing with Banner Inspection**: Port 80 being open does not guarantee the API is functioning. Inspecting the protocol banner verifies service identity.
4. **Implement Continuous Probing**: Static firewall rules decay over time. Automated synthetic network probes prevent silent firewall regression outages.
