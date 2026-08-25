# Mini-Project 08: Zombie and Orphan Process Reaper

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Docker / macOS)  

---

## 🎯 Overview & Context

In Unix and Linux operating systems, process creation, execution, and termination follow a strict hierarchy governed by the kernel. When a child process terminates, its virtual memory space, CPU registers, and open file descriptors are immediately freed by the kernel.

However, the process entry itself in the kernel process table (`struct task_struct`) **cannot be completely removed until its parent reads its termination status** (via the `wait()`, `waitpid()`, or `wait4()` system calls).

This mechanism creates two critical system conditions that Site Reliability Engineers (SREs) and DevOps engineers regularly encounter:

1. **Zombie Processes (`Z` / `defunct`)**: A terminated process whose parent process is still alive but has failed to call `waitpid()`.
2. **Orphan Processes**: A running process whose parent terminated unexpectedly, leaving the child process detached and inherited by **PID 1 (`init` / `systemd` / subreaper)**.

### Why Zombies and Orphans are Dangerous in Production

- **PID Table Exhaustion (`EAGAIN` / `fork: Resource temporarily unavailable`)**: The Linux kernel has a fixed maximum PID limit defined in `/proc/sys/kernel/pid_max` (typically `32768` or `4194304`). If a buggy microservice continuously spawns child tasks without reaping them, the process table fills up with zombie slots. Once PIDs are exhausted, **no new processes can be created** on the entire host: SSH logins fail, monitoring agents crash, cron jobs fail, and containers stop starting.
- **The Zombie Killing Fallacy**: You **cannot kill a zombie with `kill -9 <pid>`**. A zombie process is already dead; there is no executable code or signal handler remaining in memory to receive the signal.
- **How Reaping Works**:
  1. **Gentle Reaping**: Send `SIGCHLD` (signal 17) to the negligent parent process, prompting it to invoke its `waitpid()` handler.
  2. **Forceful Parent Re-Parenting**: Terminate the negligent parent process (`SIGTERM` / `SIGKILL`). When a parent terminates, the Linux kernel automatically re-parents all of its orphaned and zombie children to **PID 1 (`init` / `systemd`)**, which immediately purges the zombies from the process table.

### What This Mini-Project Implements

1. **Direct `/proc` Virtual Filesystem Inspector**: Parses `/proc/[pid]/stat`, `/proc/[pid]/status`, and `/proc/[pid]/cmdline` on Linux (with automatic POSIX `ps` fallback on macOS/BSD).
2. **Process Hierarchy & Ancestry Tracer**: Reconstructs the full parent-child-ancestor tree (`Child -> Parent -> Grandparent -> PID 1`).
3. **Progressive Auto-Remediation Engine**: Implements staged progressive cleanup (`SIGCHLD` $\rightarrow$ wait $\rightarrow$ `SIGTERM` parent $\rightarrow$ `SIGKILL` parent $\rightarrow$ PID 1 adoption).
4. **Controlled Process Lifecycle Simulators**:
   - `zombie_spawner.c`: Low-level C simulator utilizing POSIX `fork()`, `exit()`, `sleep()`, and `signal(SIGCHLD)`.
   - `zombie_spawner.py`: Companion Python workload generator.
5. **Multi-Format Reporting**: ANSI colorized hierarchy tree tables, machine-readable JSON (`--json`), and Prometheus / OpenMetrics metrics (`--prometheus`).
6. **Continuous Watchdog Daemon**: Background polling mode (`--daemon --interval 5`) for continuous process health monitoring.
7. **POSIX / Bash Companion Script**: Pure shell implementation (`process_reaper.sh`).

---

## 🧠 Kernel Process Internals & Lifecycles Deep-Dive

### 1. Process State Machine in Linux

Every process in Linux exists in one of several states managed by the kernel scheduler:

```text
               +-----------------------------------+
               |                                   |
               v                                   |
        +-------------+  fork() / exec()    +-------------+
        |   CREATED   | ------------------> |  RUNNING /  | <---+
        +-------------+                     |  RUNNABLE   |     |
                                            |     (R)     |     |
                                            +-------------+     |
                                               |       ^        | Event occurs
                                 Waiting on IO |       |        | (e.g. socket data)
                                               v       |        |
                                       +-------------------+    |
                                       |  SLEEPING (S / D) | ---+
                                       +-------------------+
                                               |
                                     exit() or | killed
                                               v
                                       +-------------------+
                                       |   ZOMBIE / DEFUNCT|
                                       |        (Z)        |
                                       +-------------------+
                                               |
                               Parent calls    | or Parent killed
                               waitpid()       | (re-parented to PID 1)
                                               v
                                       +-------------------+
                                       |    REAPED / GONE  |
                                       +-------------------+
```

### 2. State Indicators Reference

| State Code | Description | Kernel Behavior |
| :--- | :--- | :--- |
| **`R`** | Running or Runnable | Process is actively executing on a CPU core or queued in the run queue. |
| **`S`** | Interruptible Sleep | Process is waiting for an event (e.g. socket read, timer, keyboard input). Can be awakened by signals. |
| **`D`** | Uninterruptible Sleep | Process is waiting for hardware I/O (e.g. disk read or NFS lock). Cannot be killed by `SIGKILL`. |
| **`T`** | Stopped / Traced | Process was paused by a signal (`SIGSTOP`, `SIGTSTP`, `Ctrl+Z`) or debugger (`ptrace`). |
| **`Z`** | Zombie / Defunct | Process has terminated (`exit()`), but its exit code has not been read by its parent via `waitpid()`. |

---

### 3. Anatomies of Zombie and Orphan Processes

```text
[ SCENARIO A: ZOMBIE PROCESS CREATION ]
Parent (PID 100) -- fork() --> Child (PID 101)
     |                              |
     |                              | exits (exit(0))
     |                              v
     |                        Child becomes [ZOMBIE] (PID 101)
     |                        (Occupies PID slot in process table)
     |
  Parent ignores SIGCHLD
  and sleeps in loop
  ==> Zombie remains indefinitely!

[ SCENARIO B: ORPHAN PROCESS CREATION ]
Parent (PID 200) -- fork() --> Child (PID 201)
     |                              |
Parent exits (exit(0))              | Child continues running
     v                              v
Parent terminates             Kernel re-parents Child to PID 1 (init)
                              New PPID of Child 201 becomes: 1
```

---

### 4. PID 1, Subreapers, and Container Inits

In modern Linux systems, **PID 1 (`systemd` or `init`)** acts as the universal ancestor and default subreaper:

- Whenever any process terminates, if it left behind children, the Linux kernel reassigns those children's `PPID` to `1`.
- When those children subsequently exit, PID 1 automatically calls `waitpid()` in a loop, cleaning them up instantly.

#### The Docker Container PID 1 Problem

When running an application (like Node.js, Python, or Java) directly as the container `ENTRYPOINT`:

- The application runs as **PID 1** inside the container namespace.
- Standard application runtimes **do not include a `SIGCHLD` reaping loop** for orphaned child processes.
- Any background worker spawned by the app that exits becomes an unreaped zombie inside the container.
- **Solution**: Always use `init: true` in Docker Compose or use container init binaries such as `dumb-init` or `tini`.

---

## 📂 Project Structure

```text
01-linux-scripting/08-zombie-orphan-process-reaper/
├── process_reaper.py            # High-level process diagnostic & remediation tool (CLI, JSON, Prometheus, Daemon)
├── process_reaper.sh            # Pure POSIX / Bash process inspector companion script
├── zombie_spawner.c             # Educational C simulator creating deliberate zombies & orphans via fork()
├── zombie_spawner.py            # Companion Python workload generator for controlled simulations
├── test_process_reaper.sh       # Comprehensive automated test suite (13+ assertions)
├── Dockerfile                   # Isolated Debian Linux container definition with GCC and Python
├── docker-compose.yml           # Automated demonstration container composition
├── .markdownlint.json           # Linter configuration (MD013/MD033 disabled)
└── README.md                    # Educational guide, kernel internals, and cleanup instructions
```

---

## 🚀 Quickstart & Hands-On Usage

### Step 1: Compile and Run the Workload Simulators

Make all scripts executable and compile the C simulator:

```bash
chmod +x process_reaper.py process_reaper.sh zombie_spawner.py test_process_reaper.sh
gcc -Wall -Wextra -O2 zombie_spawner.c -o zombie_spawner
```

#### 1. Spawn Defective Zombie Processes

Spawn 3 zombie processes whose parent will sleep for 30 seconds without calling `waitpid()`:

```bash
./zombie_spawner --zombies 3 --duration 30 &
```

Sample simulator output:

```text
======================================================
       Zombie & Orphan Simulator (PID: 50030)
======================================================

[INFO] Ignoring SIGCHLD (simulating a negligent parent).
[SPAWNER] Spawning 3 zombie processes...
  -> Child #1 (PID 50031) exiting immediately to become a Zombie...
  -> Parent (PID 50030) created child PID 50031 (unreaped)
  -> Child #2 (PID 50032) exiting immediately to become a Zombie...
  -> Parent (PID 50030) created child PID 50032 (unreaped)
  -> Child #3 (PID 50033) exiting immediately to become a Zombie...
  -> Parent (PID 50030) created child PID 50033 (unreaped)

[PARENT] Parent PID 50030 sleeping for 30 seconds. Check 'ps aux | grep Z'
```

---

### Step 2: Diagnose Processes with `process_reaper.py`

#### 1. Run Diagnostic Scan (CLI Table View)

```bash
./process_reaper.py --scan
```

Sample output:

```text
========================================================================================================
                         ZOMBIE & ORPHAN PROCESS DIAGNOSTIC REPORT                                      
========================================================================================================
Timestamp : 2026-08-25 03:16:44 UTC
PID Table : 625 active / 32768 max (Utilization: 1.91%)

1. ZOMBIE (DEFUNCT) PROCESSES (3 found):
  PID      PPID     PARENT NAME            PROCESS NAME             ANCESTRY TREE                 
  --------------------------------------------------------------------------------------------------
  50031    50030    ./zombie_spawner       <defunct>                ...awner(50030) -> <defunct>(50031)
  50032    50030    ./zombie_spawner       <defunct>                ...awner(50030) -> <defunct>(50032)
  50033    50030    ./zombie_spawner       <defunct>                ...awner(50030) -> <defunct>(50033)

2. NEGLIGENT PARENT PROCESSES (1 found):
  PPID     PARENT NAME               ZOMBIE CHILDREN PIDs           REMEDIATION HINT
  --------------------------------------------------------------------------------------------------
  50030    ./zombie_spawner          50031, 50032, 50033            Send SIGCHLD: 'kill -17 50030' or Kill: 'kill -9 50030'

3. UNTRACKED ORPHAN PROCESSES (0 detected):
  ✔ No untracked orphan processes detected.

========================================================================================================
```

---

### Step 3: Test Remediation Strategies

#### Strategy A: Gentle Reaping via `SIGCHLD`

If the parent process has a signal handler registered (e.g. `zombie_spawner -s`), send `SIGCHLD` to wake up its `waitpid()` handler:

```bash
./process_reaper.py --reap-sigchld
```

#### Strategy B: Forceful Reaping via Parent Termination (`--kill-parents`)

If the parent process is hung, frozen, or does not implement a `SIGCHLD` handler, terminate the parent. The kernel re-parents the zombies to PID 1, which purges them immediately:

```bash
./process_reaper.py --kill-parents
```

#### Strategy C: Progressive Auto-Remediation (`--auto-reap`)

Executes staged remediation: attempts `SIGCHLD` first; if zombies remain after 0.5s, sends `SIGTERM` to the parent; if still unresponsive, sends `SIGKILL`:

```bash
./process_reaper.py --auto-reap
```

---

### Step 4: Machine-Readable JSON & Prometheus Metrics

#### JSON Output (Pipe to `jq`)

```bash
./process_reaper.py --json | jq '.metadata, .zombies'
```

Sample JSON structure:

```json
{
  "metadata": {
    "timestamp": "2026-08-25T03:16:44.120450+00:00",
    "total_processes": 625,
    "pid_max": 32768,
    "pid_utilization_percent": 1.91,
    "zombie_count": 3,
    "orphan_count": 0,
    "negligent_parent_count": 1,
    "status": "WARNING"
  },
  "zombies": [
    {
      "pid": 50031,
      "ppid": 50030,
      "name": "zombie_spawner",
      "parent_name": "zombie_spawner",
      "ancestry": [
        { "pid": 50031, "name": "zombie_spawner", "state": "Z" },
        { "pid": 50030, "name": "zombie_spawner", "state": "S" }
      ]
    }
  ]
}
```

#### Prometheus / OpenMetrics Format

```bash
./process_reaper.py --prometheus
```

Sample output:

```text
# HELP zombie_processes_total Current count of defunct zombie processes in kernel process table
# TYPE zombie_processes_total gauge
zombie_processes_total 3

# HELP orphan_processes_total Current count of untracked orphaned processes re-parented to init
# TYPE orphan_processes_total gauge
orphan_processes_total 0

# HELP negligent_parents_total Current count of parent processes with unreaped zombie children
# TYPE negligent_parents_total gauge
negligent_parents_total 1

# HELP process_table_active_processes Total number of active processes in process table
# TYPE process_table_active_processes gauge
process_table_active_processes 625

# HELP process_table_max_pids Kernel maximum process ID capacity (pid_max)
# TYPE process_table_max_pids gauge
process_table_max_pids 32768

# HELP process_table_utilization_percent Percentage of total PID table capacity in use
# TYPE process_table_utilization_percent gauge
process_table_utilization_percent 1.91
```

---

### Step 5: Continuous Watchdog Daemon Mode

Run the reaper as a background watchdog monitoring process tables every 5 seconds:

```bash
./process_reaper.py --daemon --interval 5 --auto-reap
```

---

### Step 6: Pure POSIX / Bash Companion Script

In lightweight bastion hosts or recovery environments without Python installed:

```bash
# Scan processes
./process_reaper.sh --scan

# Re-parent by terminating negligent parents
./process_reaper.sh --kill-parents
```

---

### Step 7: Run in Isolated Linux Container (Docker Compose)

Execute the full automated demonstration lab inside an isolated Debian container with real `/proc` virtual filesystem bindings:

```bash
docker compose up --build
```

---

## 📊 SRE Observability & Prometheus Monitoring Integration

### Node Exporter Textfile Collector Integration

Schedule a periodic cron job to write process health metrics to Node Exporter:

```bash
# Export process table metrics every minute
* * * * * /opt/reaper/process_reaper.py --prometheus --no-fail > /var/lib/node_exporter/textfile_collector/process_table.prom
```

### Alertmanager Production Rules

Add the following alert rules to your Prometheus `alerts.yml`:

```yaml
groups:
  - name: process_lifecycle_alerts
    rules:
      # Alert when zombie processes are detected
      - alert: ZombieProcessesDetected
        expr: zombie_processes_total > 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "{{ $value }} zombie processes detected on {{ $labels.instance }}"
          description: "Defunct processes found. Parent process is failing to call waitpid()."

      # Critical alert when zombie count is dangerously high
      - alert: HighZombieCountCritical
        expr: zombie_processes_total > 50
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Critical zombie count: {{ $value }} on {{ $labels.instance }}"
          description: "Potential process leak. Risk of kernel PID exhaustion (EAGAIN)."

      # Alert on high PID table utilization
      - alert: PIDTableUtilizationHigh
        expr: process_table_utilization_percent > 80
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "PID table is {{ $value }}% full on {{ $labels.instance }}"
          description: "System approaching /proc/sys/kernel/pid_max capacity."
```

---

## 🔄 CI/CD Quality Gates & Exit Codes

`process_reaper.py` returns standard exit codes for integration into CI/CD pipelines and deployment health checks:

| Exit Code | Meaning | Condition |
| :---: | :--- | :--- |
| **`0`** | Clean / Healthy | Zero zombie processes detected. |
| **`1`** | Warning | 1 or more zombie processes detected in scan mode. |
| **`2`** | Critical | Zombie count exceeds `--critical-threshold` (default: 10). |
| **`3`** | Error | Runtime or permission failure. |

---

## 🧪 Automated Testing Suite

The project includes an end-to-end automated test suite (`test_process_reaper.sh`):

```bash
./test_process_reaper.sh
```

### Test Coverage Highlights

1. **Compilation & CLI Flags**: Asserts clean GCC compilation of `zombie_spawner.c` and `--help` flags.
2. **Zombie Detection & Flagging**: Spawns 3 zombies and verifies that the reaper flags the negligent parent PID.
3. **Gentle Reaping via `SIGCHLD`**: Asserts that `kill -17` triggers parent `waitpid()` and cleans up zombies.
4. **Forceful Parent Re-Parenting**: Asserts that killing a parent process causes the Linux kernel to adopt zombies under PID 1 and reap them.
5. **Auto-Reap Progressive Flow**: Asserts `--auto-reap` resolves all zombies automatically.
6. **Orphan Process Detection**: Spawns detached orphan processes and verifies detection.
7. **JSON & Prometheus Exporters**: Verifies schema validity against OpenMetrics.
8. **Bash Companion Parity**: Confirms that `process_reaper.sh` correctly diagnoses and reaps processes.
9. **Critical Threshold Exit Codes**: Verifies exit codes `0`, `1`, and `2`.

---

## 🧹 Teardown & Resource Cleanup

To remove all Docker containers, networks, images, compiled binaries, and temporary files generated during testing:

### 1. Terminate Lingering Simulator Processes

```bash
# Terminate any running spawner background processes
pkill -f "zombie_spawner" 2>/dev/null || true
```

### 2. Remove Docker Containers, Networks, and Images

```bash
# Stop and remove all Docker Compose lab resources
docker compose down -v --rmi all
```

### 3. Remove Compiled Binaries and Test Reports

```bash
# Remove compiled C binary and temporary JSON reports
rm -f zombie_spawner .test_reaper.json .test_prom.txt
```

### 4. Verify Clean State

```bash
# Verify no zombie_spawner processes remain
ps aux | grep "[z]ombie_spawner" || echo "✔ No lingering spawner processes"

# Verify no lingering Docker images
docker images | grep "process-reaper-lab" || echo "✔ No lingering Docker images"
```

---

## 📚 Key Takeaways & Best Practices

1. **Never Try to `kill -9` a Zombie**: A zombie is already dead; the only solution is to make the parent reap it or kill the parent so PID 1 reaps it.
2. **Always Use an Init System in Containers**: When containerizing apps, enable `init: true` in Docker Compose or use `dumb-init` to ensure PID 1 reaps orphaned processes.
3. **Handle `SIGCHLD` in Multi-Process Daemons**: In custom daemons, register a `SIGCHLD` handler calling `waitpid(-1, NULL, WNOHANG)` in a loop to prevent zombie leaks.
4. **Monitor PID Table Utilization**: Monitor `process_table_utilization_percent` alongside CPU and RAM to prevent unexpected `fork: EAGAIN` outages.
