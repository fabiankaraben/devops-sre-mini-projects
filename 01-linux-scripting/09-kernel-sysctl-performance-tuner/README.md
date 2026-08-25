# Mini-Project 09: Kernel and Sysctl Performance Tuner

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Privileged Docker Container / macOS)  

---

## 🎯 Overview & Context

In production environments running high-traffic web servers (Nginx, Envoy), high-throughput databases (PostgreSQL, Redis, MySQL), or Kubernetes worker nodes, **default Linux kernel parameters frequently become the silent bottleneck** for infrastructure performance.

Default Linux kernel settings are intentionally conservative—optimized for generic multi-user desktop workstations or low-memory virtual machines to ensure broad hardware compatibility. Under heavy production workloads, these defaults lead to:

- **Socket Queue Saturation & Dropped Connections**: `net.core.somaxconn` defaults to `128` or `4096`. When sudden traffic spikes occur, incoming SYN packets that exceed the listen backlog queue are silently dropped.
- **Ephemeral Port Exhaustion (`EADDRNOTAVAIL`)**: `net.ipv4.ip_local_port_range` defaults to ~28,000 ports (`32768-60999`). High-throughput API gateways and reverse proxies rapidly exhaust available source ports, failing upstream connections.
- **Memory Thrashing via Aggressive Swapping**: `vm.swappiness` defaults to `60`, causing the kernel to page process memory to disk even when ample RAM remains, introducing latency spikes of $10\times$ to $100\times$.
- **Bandwidth Bottlenecks on High-Speed Links**: Default TCP read/write buffer ceilings (`net.core.rmem_max`, `net.core.wmem_max`) prevent TCP connections from expanding their congestion window to fill large Bandwidth-Delay Product (BDP) pipes.
- **File Descriptor Exhaustion (`EMFILE` / `Too many open files`)**: Low system-wide `fs.file-max` and inotify limits prevent scaling to thousands of concurrent microservices and worker threads.

### What This Mini-Project Implements

1. **Linux Kernel Parameter Auditor**: Evaluates active `/proc/sys/*` values against production baselines, calculates an SRE Compliance Score, and highlights misaligned parameters.
2. **Multi-Profile Tuning Presets**:
   - `web.conf`: Tuned for high-concurrency HTTP reverse proxies and API gateways (Nginx, Envoy, Node.js, Go).
   - `db.conf`: Tuned for memory-intensive, low-latency database engines (PostgreSQL, Redis, MySQL).
   - `hpc.conf`: Tuned for ultra-high throughput computing and 10G/40G/100G network interfaces.
3. **Automated Snapshot Backups & 1-Click Rollback**: Automatically captures a timestamped parameter snapshot before applying modifications and provides instant rollback (`--rollback`).
4. **Network Socket Concurrency Micro-Benchmark**: Measures TCP handshake latency (P50, P95, P99), socket drop rate, and throughput (req/sec) before and after tuning.
5. **Multi-Format Reporting**: ANSI color comparison tables, machine-readable JSON (`--json`), and Prometheus / OpenMetrics metrics (`--prometheus`).
6. **Isolated Privileged Sandbox (Docker Compose)**: Safe containerized environment to test live kernel parameter changes without altering host OS settings.

---

## 🧠 Linux Kernel Subsystems & Sysctl Internals Deep-Dive

### 1. How `sysctl` Interacts with the Kernel

In Linux, `sysctl` is the user-space interface to view and modify kernel parameters at runtime. It directly manipulates pseudo-files exposed under the `/proc/sys/` virtual filesystem:

```text
sysctl key:         net.core.somaxconn
Virtual file path:  /proc/sys/net/core/somaxconn
```

Modifications can be made:

- **In-Memory (Ephemeral)**: `sysctl -w net.core.somaxconn=65535` or `echo 65535 > /proc/sys/net/core/somaxconn` (lost on reboot).
- **Persistent Across Reboots**: Placed in configuration files under `/etc/sysctl.d/99-performance.conf` and loaded by `systemd-sysctl.service` during boot.

---

### 2. Key Kernel Parameters & Recommended Baselines

| Parameter | Default Value | Tuned Baseline | Target Subsystem | SRE Rationale & Impact |
| :--- | :--- | :--- | :--- | :--- |
| **`net.core.somaxconn`** | `128` or `4096` | `65535` | Network Sockets | Maximum queue length for pending socket connections (`listen()`). Prevents connection drops during traffic spikes. |
| **`net.ipv4.tcp_max_syn_backlog`** | `512` or `1024` | `65535` | TCP Stack | Maximum number of remembered connection requests (half-open connections in SYN queue). Protects against SYN floods. |
| **`net.ipv4.tcp_tw_reuse`** | `0` or `2` | `1` | TCP Stack | Allows reusing sockets in `TIME_WAIT` state for new outbound connections when safe from a protocol standpoint. |
| **`net.ipv4.tcp_fin_timeout`** | `60` | `15` | TCP Stack | Time in seconds to hold socket in `FIN-WAIT-2` state before releasing resources. Reduces socket exhaustion. |
| **`net.ipv4.ip_local_port_range`** | `32768 60999` | `10240 65535` | TCP Stack | Expands ephemeral source port range from ~28,000 to >55,000 available ports for reverse proxies. |
| **`net.ipv4.tcp_syncookies`** | `1` | `1` | TCP Stack | Sends SYN cookies when the SYN backlog queue fills up, preventing denial of service attacks. |
| **`net.ipv4.tcp_rmem`** | `4096 131072 6MB` | `4096 87380 16MB` | TCP Buffers | Min, default, and max TCP read window buffer size. Allows TCP window auto-tuning to scale to line rate. |
| **`net.ipv4.tcp_wmem`** | `4096 16384 4MB` | `4096 65536 16MB` | TCP Buffers | Min, default, and max TCP write buffer size. |
| **`net.core.rmem_max`** | `212992` | `16777216` | Socket Core | Maximum OS receive buffer size for all socket types (TCP, UDP, raw). |
| **`net.core.wmem_max`** | `212992` | `16777216` | Socket Core | Maximum OS send buffer size for all socket types. |
| **`vm.swappiness`** | `60` | `10` or `1` | Memory Manager | Controls tendency of kernel to reclaim anonymous pages vs page cache. Lower values prevent disk I/O latency spikes. |
| **`vm.vfs_cache_pressure`** | `100` | `50` | VFS Cache | Tendency of kernel to reclaim memory used for directory and inode caching. Lower values retain filesystem cache. |
| **`vm.max_map_count`** | `65530` | `262144` | Memory Manager | Maximum number of memory map areas (`mmap`) a process may have. Essential for Elasticsearch, Redis, and PostgreSQL. |
| **`fs.file-max`** | `~100000` | `2097152` | Filesystem | System-wide maximum open file descriptors. Prevents `Too many open files` errors under heavy load. |

---

### 3. Bandwidth-Delay Product (BDP) & Buffer Sizing Formula

To maximize network throughput over high-latency or high-bandwidth links, the TCP socket buffer must be at least equal to the **Bandwidth-Delay Product (BDP)**:

$$\text{BDP} = \text{Bandwidth (bytes/sec)} \times \text{Round-Trip Time (seconds)}$$

#### Example Calculation

For a **10 Gbps** link across regions with a **20 ms ($0.02\text{ s}$)** round-trip time:

$$\text{Bandwidth} = \frac{10 \times 10^9 \text{ bits/sec}}{8} = 1.25 \times 10^9 \text{ bytes/sec} = 1250 \text{ MB/s}$$

$$\text{BDP} = 1,250,000,000 \times 0.02 = 25,000,000 \text{ bytes} \approx 25 \text{ MB}$$

If `net.core.rmem_max` is left at the default `212 KB`, TCP can only utilize a tiny fraction ($\approx 0.8\%$) of the available 10 Gbps bandwidth. Setting buffer maximums to `33554432` ($32\text{ MB}$) allows TCP to utilize the entire pipe.

---

## 📂 Project Structure

```text
01-linux-scripting/09-kernel-sysctl-performance-tuner/
├── sysctl_tuner.sh              # Production-grade Bash kernel parameter auditor, tuner & rollback manager
├── sysctl_tuner.py              # Companion Python utility (CLI tables, JSON, Prometheus OpenMetrics)
├── benchmark_network.sh         # Network socket throughput and concurrency benchmark before/after tuning
├── profiles/                    # Tuning profile definitions
│   ├── web.conf                 # Profile optimized for high-concurrency HTTP/Reverse Proxy (Nginx/HAProxy)
│   ├── db.conf                  # Profile optimized for Database workloads (PostgreSQL/Redis/MySQL)
│   └── hpc.conf                 # Profile optimized for High-Performance Computing & 10G+ throughput
├── backups/                     # Dedicated directory for automated parameter snapshot backups
│   └── .gitkeep
├── test_sysctl_tuner.sh         # Automated test suite (15 assertions)
├── Dockerfile                   # Privileged Linux container definition with sysctl and networking tools
├── docker-compose.yml           # Automated sandbox orchestration for tuning, benchmarking & rollback
├── .markdownlint.json           # Linter configuration (MD013/MD033 disabled)
└── README.md                    # Educational guide, kernel tuning internals & cleanup instructions
```

---

## 🚀 Quickstart & Hands-On Usage

### Step 1: Make Scripts Executable

```bash
chmod +x sysctl_tuner.sh sysctl_tuner.py benchmark_network.sh test_sysctl_tuner.sh
```

---

### Step 2: Audit Current Kernel Parameters (`--audit`)

Run a read-only audit against the default `web.conf` profile:

```bash
./sysctl_tuner.sh --audit --profile web --no-fail
```

Sample audit output:

```text
========================================================================================================
                       LINUX KERNEL SYSCTL PERFORMANCE AUDITOR                                          
========================================================================================================
Profile  : /app/profiles/web.conf
Timestamp: 2026-08-25 07:14:58 UTC

KERNEL PARAMETER                     CURRENT VALUE           TARGET VALUE            STATUS      
--------------------------------------------------------------------------------------------------------
net.core.somaxconn                   4096                    65535                   [SUBOPTIMAL]
net.ipv4.tcp_max_syn_backlog         512                     65535                   [SUBOPTIMAL]
net.core.netdev_max_backlog          1000                    65535                   [SUBOPTIMAL]
net.ipv4.tcp_tw_reuse                2                       1                       [SUBOPTIMAL]
net.ipv4.tcp_fin_timeout             60                      15                      [SUBOPTIMAL]
net.ipv4.ip_local_port_range         32768 60999             10240 65535             [SUBOPTIMAL]
net.ipv4.tcp_syncookies              1                       1                       [ OPTIMAL ]
net.ipv4.tcp_slow_start_after_idle   1                       0                       [SUBOPTIMAL]
net.ipv4.tcp_rmem                    4096 131072 33554432    4096 87380 16777216     [SUBOPTIMAL]
net.ipv4.tcp_wmem                    4096 16384 4194304      4096 65536 16777216     [SUBOPTIMAL]
net.core.rmem_max                    7500000                 16777216                [SUBOPTIMAL]
net.core.wmem_max                    7500000                 16777216                [SUBOPTIMAL]
vm.swappiness                        20                      10                      [SUBOPTIMAL]
vm.vfs_cache_pressure                100                     50                      [SUBOPTIMAL]
fs.file-max                          9223372036854775807     2097152                 [ OPTIMAL ]
fs.inotify.max_user_watches          1048576                 524288                  [ OPTIMAL ]
--------------------------------------------------------------------------------------------------------

AUDIT SUMMARY & COMPLIANCE:
  Total Checked   : 16
  ✔ Optimal       : 3
  ▲ Suboptimal    : 13
  ○ Unavailable   : 0
  Compliance Score: 18% (3/16 parameters aligned)
```

---

### Step 3: Run Pre-Tuning Socket Benchmark

Measure socket connection throughput and latency under concurrent load:

```bash
./benchmark_network.sh -n 300 -c 30
```

Sample benchmark output:

```text
========================================================================================================
                       TCP SOCKET CONCURRENCY & LATENCY BENCHMARK                                       
========================================================================================================

  Total Requests    : 300
  Concurrency Level : 30 simultaneous workers
  Completed Duration: 0.0210 seconds

  ✔ Successful Connections : 300
  ✖ Failed / Dropped Sockets: 0
  ⚡ Connection Throughput : 14285.71 req/sec

LATENCY PROFILING (Milliseconds):
  - Average Handshake: 1.48 ms
  - 50th Percentile  : 1.45 ms
  - 95th Percentile  : 2.30 ms
  - 99th Percentile  : 2.80 ms

========================================================================================================
```

---

### Step 4: Apply Performance Profile (`--apply`)

Apply tuned settings with automatic snapshot backup creation:

```bash
./sysctl_tuner.sh --apply --profile web
```

Sample apply output:

```text
========================================================================================================
                       APPLYING SYSCTL PERFORMANCE PROFILE (web)                             
========================================================================================================

[1/4] Taking snapshot backup of current kernel parameters...
  ✔ Saved backup to: ./backups/sysctl_backup_20260825_071458.conf

[2/4] Generating sysctl configuration file...
  ✔ Wrote target configuration to: /etc/sysctl.d/99-performance.conf

[3/4] Applying parameters to active Linux kernel...
  - [APPLIED] net.core.somaxconn = 65535
  - [APPLIED] net.ipv4.tcp_max_syn_backlog = 65535
  - [APPLIED] net.ipv4.tcp_tw_reuse = 1
  - [APPLIED] net.ipv4.tcp_fin_timeout = 15
  - [APPLIED] net.ipv4.ip_local_port_range = 10240 65535
  - [APPLIED] vm.swappiness = 10
  ...

[4/4] Verifying kernel state...

APPLICATION SUMMARY:
  Total Target Parameters: 16
  ✔ Successfully Applied  : 15
  ✔ Verified in Kernel    : 15
  ✖ Failed / Skipped      : 1
  Rollback File Created   : ./backups/sysctl_backup_20260825_071458.conf
```

---

### Step 5: Rollback to Pre-Tuning State (`--rollback`)

Instantly restore kernel parameters to the exact values recorded in the snapshot:

```bash
# Rollback to latest snapshot
./sysctl_tuner.sh --rollback

# Or specify a specific snapshot file
./sysctl_tuner.sh --rollback backups/sysctl_backup_20260825_071458.conf
```

---

### Step 6: Python Tuner with JSON & Prometheus Exports

```bash
# Audit via Python with formatted CLI table
./sysctl_tuner.py --audit --profile db

# Machine-readable JSON output (pipe to jq)
./sysctl_tuner.py --audit --profile web --json | jq '.summary'

# Prometheus / OpenMetrics text exposition format
./sysctl_tuner.py --prometheus --profile web
```

Sample Prometheus metrics output:

```text
# HELP sysctl_compliance_percent SRE compliance percentage against target kernel profile
# TYPE sysctl_compliance_percent gauge
sysctl_compliance_percent 100.0

# HELP sysctl_parameters_total Total kernel parameters evaluated in profile
# TYPE sysctl_parameters_total gauge
sysctl_parameters_total 16

# HELP sysctl_parameters_optimal Parameters matching target values
# TYPE sysctl_parameters_optimal gauge
sysctl_parameters_optimal 15

# HELP sysctl_parameters_suboptimal Parameters requiring performance tuning
# TYPE sysctl_parameters_suboptimal gauge
sysctl_parameters_suboptimal 0
```

---

### Step 7: Run in Privileged Container Sandbox (Docker Compose)

Run the full end-to-end audit, benchmark, apply, post-benchmark, and rollback automated sequence in an isolated privileged Debian container:

```bash
docker compose up --build
```

---

## 📊 SRE Observability & Prometheus Monitoring Integration

### Node Exporter Textfile Collector Integration

Schedule periodic kernel parameter compliance scans to export metrics to Prometheus Node Exporter:

```bash
# Audit kernel parameters every 15 minutes and export to Node Exporter
*/15 * * * * /opt/tuner/sysctl_tuner.py --prometheus --profile web --no-fail > /var/lib/node_exporter/textfile_collector/sysctl_compliance.prom
```

### Prometheus Alertmanager Rules

Add the following alert rules to `alerts.yml`:

```yaml
groups:
  - name: kernel_sysctl_alerts
    rules:
      # Alert when kernel parameters deviate from approved production baselines
      - alert: KernelSysctlComplianceLow
        expr: sysctl_compliance_percent < 80
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Kernel sysctl compliance is {{ $value }}% on {{ $labels.instance }}"
          description: "System parameters deviate from production baseline. Check for missing /etc/sysctl.d/ configuration."

      # Critical alert when suboptimal parameters are detected on production servers
      - alert: SuboptimalKernelParametersDetected
        expr: sysctl_parameters_suboptimal > 5
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $value }} suboptimal kernel parameters found on {{ $labels.instance }}"
          description: "Risk of connection drops or paging latency under load."
```

---

## 🔄 CI/CD Quality Gates & Exit Codes

`sysctl_tuner.sh` and `sysctl_tuner.py` return standard exit codes for automated infrastructure validation:

| Exit Code | Meaning | Condition |
| :---: | :--- | :--- |
| **`0`** | Compliant / Success | 100% of available parameters match the target baseline profile, or `--no-fail` was supplied. |
| **`1`** | Suboptimal | One or more parameters deviate from the target profile in audit mode. |
| **`3`** | Error | Missing profile file, invalid backup file, or unhandled runtime failure. |

---

## 🧪 Automated Testing Suite

The project includes an automated test runner (`test_sysctl_tuner.sh`) covering 15 test assertions:

```bash
./test_sysctl_tuner.sh
```

### Test Coverage Highlights

1. **CLI Flag Verification**: Tests `--help` flags and error handling for missing profiles.
2. **Profile Schema Validation**: Confirms parameters in `web.conf`, `db.conf`, and `hpc.conf`.
3. **Audit Calculation & JSON Schema**: Validates parameter parsing and summary metrics.
4. **Prometheus Metrics**: Validates OpenMetrics schema compliance.
5. **Snapshot Backups**: Asserts that timestamped snapshots are created before applying changes.
6. **Rollback Mechanics**: Verifies parsing and restoration of snapshot backups.
7. **Socket Benchmark**: Asserts 150 parallel socket connections complete with zero drops.
8. **Output File Isolation**: Asserts that all reports and backups are written strictly inside the project directory.

---

## 🧹 Teardown & Resource Cleanup

To remove all Docker containers, networks, images, and backup files created during testing:

### 1. Remove Docker Container Lab Resources

```bash
# Stop and remove all Docker Compose lab resources
docker compose down -v --rmi all
```

### 2. Clean Snapshot Backups and Temporary Reports

```bash
# Remove temporary test reports and generated snapshot backups
rm -f .test_sysctl.json .test_prom.txt backups/sysctl_backup_*.conf
```

### 3. Verify Clean State

```bash
# Confirm no lingering lab containers
docker ps -a | grep "sysctl_performance_lab" || echo "✔ No lingering lab containers"

# Confirm no lingering Docker images
docker images | grep "sysctl-performance-lab" || echo "✔ No lingering Docker images"
```

---

## 📚 Key Takeaways & Production Best Practices

1. **Always Back Up Before Applying**: Kernel parameters take effect instantly. Automated snapshot backups make rollbacks safe and trivial.
2. **Tailor Parameters to Workloads**: Database servers require large `vm.max_map_count` and minimal `vm.swappiness`; web proxies require high `somaxconn` and large ephemeral port ranges.
3. **Calculate BDP for High-Speed Networks**: Standard socket buffer ceilings choke 10G/40G interfaces. Calculate BDP to size `rmem_max` and `wmem_max` appropriately.
4. **Make Settings Persistent**: Live modifications via `sysctl -w` are lost on reboot. Always persist approved settings in `/etc/sysctl.d/99-performance.conf`.
