# Mini-Project 01: System Resource Health Checker

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Docker / macOS) or Cloud (AWS EC2 t2.micro)  

---

## 🎯 Overview & Context

In modern Infrastructure and Site Reliability Engineering (SRE), monitoring host health is a fundamental pillar of observability. While complex agent frameworks (like Datadog, Prometheus Node Exporter, or Telegraf) are widely used in enterprise clusters, understanding **how the Linux kernel exposes metrics** directly through the virtual filesystem (`/proc`) is essential for building custom monitoring plugins, lightweight health probes, and automation daemons.

This mini-project provides a complete, production-grade CLI utility written in Bash that:

1. Gathers real-time host metrics directly from `/proc/stat`, `/proc/meminfo`, and POSIX `df`.
2. Evaluates CPU, Memory, and Disk usage against configurable Warning and Critical thresholds.
3. Emits structured, machine-parseable JSON formatted for monitoring pipelines.
4. Adheres to standard SRE/Nagios exit codes (`0` = OK, `1` = WARNING, `2` = CRITICAL, `3` = UNKNOWN).
5. Provides a companion stress simulator (`stress_simulator.sh`) to inject controlled synthetic workloads for testing.
6. Includes an automated end-to-end test suite (`test_health_check.sh`).

---

## 🧠 Linux Internals Deep-Dive

### 1. CPU Metrics from `/proc/stat`

The Linux kernel exposes cumulative processor time since boot in `/proc/stat`. The first line begins with `cpu` followed by time counters measured in "USER_HZ" (clock ticks, typically $1/100$th of a second):

```text
cpu  user nice system idle iowait irq softirq steal guest guest_nice
```

Because these numbers are running totals since system boot, **a single snapshot cannot tell you the current CPU usage**. To measure instantaneous CPU usage, we sample `/proc/stat` twice with a time interval ($\Delta t = 1\text{s}$):

$$\text{Total Time} = \text{user} + \text{nice} + \text{system} + \text{idle} + \text{iowait} + \text{irq} + \text{softirq} + \text{steal}$$

$$\text{Idle Time} = \text{idle} + \text{iowait}$$

$$\Delta\text{Total} = \text{Total}_2 - \text{Total}_1$$

$$\Delta\text{Idle} = \text{Idle}_2 - \text{Idle}_1$$

$$\text{CPU Usage \%} = \left( 1 - \frac{\Delta\text{Idle}}{\Delta\text{Total}} \right) \times 100$$

### 2. Memory Metrics from `/proc/meminfo`

Rather than relying on unformatted text outputs from `free`, `/proc/meminfo` provides exact memory counters in kilobytes (kB):

- `MemTotal`: Total usable RAM.
- `MemFree`: Memory completely unallocated.
- `MemAvailable`: An estimate of how much memory is available for starting new applications without swapping (accounting for reclaimable page cache and buffers).
- `Buffers` & `Cached`: Disk blocks cached in RAM by the kernel.

$$\text{Used Memory} = \text{MemTotal} - \text{MemAvailable}$$

$$\text{Memory Usage \%} = \left( \frac{\text{Used Memory}}{\text{MemTotal}} \right) \times 100$$

### 3. Disk Metrics via POSIX `df -Pk`

The POSIX standard defines the `-P` (Portability) flag for `df`, ensuring consistent column order and strictly one line per filesystem without line wrapping:

- `df -Pk <mount_point>` outputs total 1024-byte blocks, used blocks, available blocks, and capacity percentage.

---

## 📊 Exit Code Conventions

Standard monitoring systems (Nagios, Zabbix, Sensu, Consul health checks, Kubernetes custom probes) rely on shell exit codes to trigger alerts and schedule self-healing actions:

| Exit Code | Status | Meaning |
| :---: | :---: | :--- |
| **`0`** | `OK` | All monitored metrics are below the configured warning thresholds. |
| **`1`** | `WARNING` | At least one metric exceeded its warning threshold, but none breached critical. |
| **`2`** | `CRITICAL` | At least one metric exceeded its critical threshold. Immediate escalation required. |
| **`3`** | `UNKNOWN` | Execution failed (e.g. invalid arguments, missing dependencies, or path not found). |

---

## 📂 Project Structure

```text
01-system-resource-health-checker/
├── health_check.sh       # Main monitoring script with JSON output & exit codes
├── stress_simulator.sh   # Controllable CPU, Memory, and Disk stress workload generator
├── test_health_check.sh  # Automated 14-point test suite for verification
├── Dockerfile            # Containerized Linux environment with /proc support
├── docker-compose.yml    # Docker Compose definition for zero-setup execution
└── README.md             # Educational guide and documentation
```

---

## 🚀 Quickstart & Usage

### 1. Direct Execution (Linux / macOS)

Make scripts executable:

```bash
chmod +x health_check.sh stress_simulator.sh test_health_check.sh
```

Run a standard health check:

```bash
./health_check.sh --pretty
```

Inspect exit code:

```bash
echo $?
```

### 2. CLI Options Reference

| Flag | Description | Default |
| :--- | :--- | :---: |
| `--cpu-max <pct>` | Alias for CPU warning threshold percentage | `80.0%` |
| `--cpu-warn <pct>` | CPU warning threshold percentage | `80.0%` |
| `--cpu-crit <pct>` | CPU critical threshold percentage | `95.0%` |
| `--mem-max <pct>` | Alias for Memory warning threshold percentage | `80.0%` |
| `--mem-warn <pct>` | Memory warning threshold percentage | `80.0%` |
| `--mem-crit <pct>` | Memory critical threshold percentage | `95.0%` |
| `--disk-max <pct>` | Alias for Disk warning threshold percentage | `85.0%` |
| `--disk-warn <pct>` | Disk warning threshold percentage | `85.0%` |
| `--disk-crit <pct>` | Disk critical threshold percentage | `95.0%` |
| `--disk-path <path>` | Filesystem mount point or path to check | `/` |
| `--sample-interval <sec>` | Sampling duration for CPU delta calculation | `1` |
| `--pretty` | Formats JSON output with 2-space indentation | `false` |
| `-h, --help` | Display usage instructions and exit codes | - |
| `-v, --version` | Display version information | - |

---

## 📋 JSON Output Schema

When executed, `health_check.sh` outputs a clean JSON payload:

```json
{
  "timestamp": "2026-08-21T10:54:05Z",
  "hostname": "linux-node-01",
  "status": "WARNING",
  "exit_code": 1,
  "thresholds": {
    "cpu": {
      "warning_percent": 50.0,
      "critical_percent": 95.0
    },
    "memory": {
      "warning_percent": 80.0,
      "critical_percent": 95.0
    },
    "disk": {
      "mount_point": "/",
      "warning_percent": 85.0,
      "critical_percent": 95.0
    }
  },
  "metrics": {
    "cpu": {
      "usage_percent": 68.4,
      "cores": 4,
      "status": "WARNING"
    },
    "memory": {
      "total_mb": 8192,
      "used_mb": 3420,
      "available_mb": 4772,
      "usage_percent": 41.7,
      "status": "OK"
    },
    "disk": {
      "mount_point": "/",
      "total_gb": 100.00,
      "used_gb": 42.50,
      "available_gb": 57.50,
      "usage_percent": 42.5,
      "status": "OK"
    }
  },
  "alerts": [
    "CPU usage (68.4%) exceeds warning threshold (50.0%)"
  ]
}
```

---

## 🧪 Testing & Failure Simulation

### Scenario A: Verify Normal / OK State

```bash
# Run with generous 99% thresholds
./health_check.sh --cpu-max 99 --mem-max 99 --disk-max 99 --pretty
echo "Exit Code: $?"
# Expected: Exit code 0, status "OK", empty alerts array
```

### Scenario B: Simulate Low Warning Threshold

```bash
# Set a low CPU threshold (e.g. 5%) that is easily exceeded
./health_check.sh --cpu-max 5 --pretty
echo "Exit Code: $?"
# Expected: Exit code 1, status "WARNING", alert recorded in JSON
```

### Scenario C: Live Stress Injection with `stress_simulator.sh`

The companion script `stress_simulator.sh` allows you to inject synthetic CPU spin-loops, memory allocations, and disk I/O with automatic cleanup:

```bash
# Step 1: Start 4 CPU spin workers in the background for 15 seconds
./stress_simulator.sh --cpu 4 --duration 15 &

# Step 2: Execute health check with a 50% CPU threshold
./health_check.sh --cpu-max 50 --pretty
echo "Exit Code: $?"
# Expected: Exit code 1 or 2, detecting the active workload spike
```

### Scenario D: Memory and Disk Stress Simulation

```bash
# Stress 512MB RAM and 1000MB Disk for 10 seconds
./stress_simulator.sh --memory 512 --disk 1000 --duration 10
```

> [!TIP]
> `stress_simulator.sh` uses POSIX signal trapping (`SIGINT`, `SIGTERM`, `EXIT`) to guarantee that all background worker processes and temporary stress files are cleaned up immediately when the duration ends or if cancelled with `Ctrl+C`.

---

## 🤖 Running Automated Tests

An automated test suite (`test_health_check.sh`) validates CLI arguments, normal operations, threshold violations, exit codes, JSON syntax (via `jq` or `python3`), and stress simulator integration:

```bash
./test_health_check.sh
```

**Expected output:**

```text
======================================================
  System Resource Health Checker - Automated Tests  
======================================================

Suite 1: CLI Arguments & Help Handling
  [PASS] --help displays usage and exits 0
  [PASS] --version displays version string and exits 0

Suite 2: Error Handling & Invalid Inputs
  [PASS] Unknown flag triggers exit code 3 (UNKNOWN)
  [PASS] Out-of-range percentage triggers exit code 3
  [PASS] Non-existent disk path triggers exit code 3

Suite 3: Baseline Normal Execution
  [PASS] Baseline health check returns exit code 0 (OK)
  [PASS] Baseline output produces valid JSON
  [PASS] JSON payload contains status OK and exit_code 0

Suite 4: Warning Threshold Triggers
  [PASS] Exceeded disk threshold triggers exit code 1 (WARNING)
  [PASS] JSON payload contains status WARNING and alerts entry

Suite 5: Critical Threshold Triggers
  [PASS] Exceeded critical threshold triggers exit code 2 (CRITICAL)
  [PASS] JSON payload contains status CRITICAL and critical alert

Suite 6: Stress Simulator Companion Integration
  [PASS] Synthetic CPU stress triggers WARNING/CRITICAL exit code (2)
  [PASS] Stress test output conforms to valid JSON schema

======================================================
  Test Results: 14/14 Passed
  Status: ALL TESTS PASSED
======================================================
```

---

## 🐳 Running with Docker / Docker Compose

If you are developing on macOS or Windows and want to test inside an authentic Ubuntu Linux environment with full `/proc` access:

### Using Docker Compose

```bash
# Build and run the health check
docker compose run --rm health-checker

# Run the automated test suite inside the container
docker compose run --rm health-checker ./test_health_check.sh

# Open an interactive shell inside the container
docker compose run --rm --entrypoint bash health-checker
```

### Using Docker CLI

```bash
# Build image
docker build -t health-checker .

# Run container
docker run --rm -it health-checker --pretty
```

---

## 💡 Key SRE & Bash Best Practices Applied

1. **`set -euo pipefail`**:
   - `-e`: Exits immediately if a pipeline returns a non-zero status.
   - `-u`: Treats unset variables as an error.
   - `-o pipefail`: Propagates pipeline errors rather than only returning the exit code of the last command.
2. **Subshell & Process Isolation**:
   - Stress simulation workers run in detached subshells `(...) &` and are tracked by PID array for deterministic termination.
3. **Signal Trapping**:
   - `trap cleanup SIGINT SIGTERM EXIT` guarantees that resource spikes and temporary files in `/tmp` are never orphaned.
4. **POSIX Tooling**:
   - Uses `awk`, `df -Pk`, `date -u`, and `tr` to maximize portability across standard Linux distributions.
5. **Machine-Parseable Output**:
   - Emits valid JSON so downstream tools (`jq`, Python scripts, Prometheus Pushgateway, or Slack webhooks) can consume metrics effortlessly.

---

## 🧹 Cleanup & Teardown

To ensure your local workstation or VM remains clean and ready for the next mini-project, follow these cleanup steps to remove all containers, images, volumes, and temporary files generated during testing:

### 1. Remove Docker Compose Resources

If you used `docker compose`, stop and delete all associated containers, networks, volumes, and locally built images:

```bash
# Stop and remove containers, networks, volumes, and local images
docker compose down --volumes --rmi local
```

### 2. Remove Standalone Docker Images and Containers

If you used the standalone `docker build` / `docker run` commands:

```bash
# Remove any stopped test containers
docker rm -f system-health-checker 2>/dev/null || true

# Remove the built Docker image
docker rmi health-checker 2>/dev/null || true
```

### 3. Clean Local Temporary Test Artifacts

If you ran tests or stress simulations directly on your host or VM:

```bash
# Execute the built-in stress simulator cleanup helper
./stress_simulator.sh --cleanup

# Remove any residual temporary test directories in /tmp
rm -rf /tmp/health_check_stress_* 2>/dev/null || true
```

### 4. Verify Clean State

Confirm that no leftover Docker resources or temporary files remain:

```bash
# Verify no leftover containers exist
docker ps -a --filter "name=system-health-checker"

# Verify no leftover images exist
docker images "health-checker"
```
