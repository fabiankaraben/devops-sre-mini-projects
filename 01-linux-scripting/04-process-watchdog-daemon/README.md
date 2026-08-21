# Mini-Project 04: Process Watchdog Daemon

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Docker / macOS)  

---

## 🎯 Overview & Context

In production Site Reliability Engineering (SRE), services crash. Hardware hiccups, out-of-memory errors (OOMs), unhandled exceptions, and memory leaks are inevitable realities of distributed systems. Without an automated supervisor, a crashed service leaves an outage until human intervention occurs.

Modern operating systems and container orchestrators rely on process supervisors (such as `systemd`, `supervisord`, `runit`, and Kubernetes `kubelet`) to continuously monitor service vitality and restart failed daemons automatically.

This mini-project teaches how to build a **production-grade process supervisor & watchdog daemon** in Python 3 and Bash that:

1. Supervises child processes using both **L1 (PID/OS process state)** and **L7 (HTTP health check endpoint)** probing.
2. Detects sudden process termination (`SIGKILL`/`SIGSEGV`) and recovers service within seconds.
3. Detects silent deadlocks (where the process is running at OS level, but unresponsive to HTTP traffic).
4. Implements **Crash Flapping Prevention** using sliding-window rate limiting to prevent infinite restart loops and CPU starvation.
5. Emits real-time structured JSON status reports and fires alert notifications.
6. Includes a companion failure simulator (`flaky_service.py`) and an automated end-to-end test suite.

---

## 🧠 Linux Process Supervision Internals

### 1. L1 vs. L7 Health Probing

```text
+-------------------------------------------------------------------------+
|                         Process Watchdog Daemon                         |
+-------------------------------------------------------------------------+
         |                                                 |
         | [L1 Probe: OS Level]                           | [L7 Probe: App Level]
         v                                                 v
  kill -0 <PID>                                     GET http://127.0.0.1:8080/healthz
  Checks if process exists in /proc table           Checks if event loop is unblocked
```

- **L1 (OS Process Probing)**:
  - Uses `process.poll()` or `kill -0 <PID>`.
  - Catches hard crashes, panics, `kill -9`, and OOM kills.
  - *Limitation*: A process can be completely deadlocked or hanging in an infinite loop while its PID remains alive!
- **L7 (Application HTTP Probing)**:
  - Sends active HTTP GET requests to `/healthz` with a strict timeout (e.g. 2.0s).
  - Validates that the application server, worker threads, and database connection pools are actually healthy and serving traffic.

---

### 2. The Danger of Crash Flapping

When a service has a catastrophic misconfiguration (e.g. invalid database credentials or missing config file), it crashes immediately upon startup:

```text
Start -> Crash -> Start -> Crash -> Start -> Crash ... (100% CPU Consumption)
```

Without rate limiting, the supervisor enters an infinite loop, burning 100% CPU and flooding logs.

**Sliding-Window Flapping Detection Algorithm:**

1. Maintain a list of recent restart timestamps: $[t_1, t_2, \dots, t_n]$.
2. Discard timestamps older than the sliding window ($W = 60\text{s}$).
3. If $\text{Count}(\text{Restarts in } W) > \text{MaxRestarts}$:
   - Transition state to **`FLAPPING`**.
   - Pause restarts to avoid CPU exhaustion.
   - Fire a critical alert webhook to page on-call engineers.

```text
+----------+      Probe Pass      +---------+
| STARTING | -------------------> | HEALTHY |
+----------+                      +---------+
     |                                 |
     | Crash / Timeout                 | Crash / Timeout
     v                                 v
+------------+   Rate Exceeded    +----------+
| RESTARTING | -----------------> | FLAPPING | (Alert & Pause)
+------------+                    +----------+
```

---

## 📂 Project Structure

```text
04-process-watchdog-daemon/
├── watchdog.py            # Core process supervisor & health probe daemon
├── watchdog.sh            # POSIX CLI shell wrapper (start, status, stop)
├── flaky_service.py       # Mock HTTP server with failure injection endpoints
├── test_watchdog.sh       # Automated test suite (crashes, hangs, flapping)
├── Dockerfile             # Multi-arch Linux container environment
├── docker-compose.yml     # Zero-setup Docker Compose supervisor definition
└── README.md              # Educational guide and cleanup procedures
```

---

## 🚀 Quickstart & Usage

### 1. Direct Execution (Linux / macOS)

Make scripts executable:

```bash
chmod +x watchdog.py watchdog.sh flaky_service.py test_watchdog.sh
```

Start the watchdog in foreground mode:

```bash
./watchdog.sh start --http-check http://127.0.0.1:8080/healthz
```

Or start as a background daemon:

```bash
./watchdog.sh start --daemon --http-check http://127.0.0.1:8080/healthz
```

---

### 2. Inspecting Supervisor Status

Inspect live supervisor status in structured JSON format:

```bash
./watchdog.sh status
```

**Example JSON output:**

```json
{
  "watchdog_pid": 14205,
  "state": "HEALTHY",
  "command": "python3 flaky_service.py --port 8080",
  "child_pid": 14210,
  "service_uptime_seconds": 45.2,
  "total_restarts": 1,
  "restarts_in_window": 1,
  "max_restarts_allowed": 3,
  "window_seconds": 60,
  "flapping": false,
  "last_error": "",
  "updated_at": "2026-08-21T11:20:00Z"
}
```

---

### 3. CLI Options Reference

| Option | Description | Default |
| :--- | :--- | :---: |
| `--command <cmd>` | Command string to execute and supervise | `python3 flaky_service.py` |
| `--http-check <url>` | HTTP health probe URL | `None` |
| `--interval <sec>` | Health check polling frequency in seconds | `2.0` |
| `--timeout <sec>` | HTTP health probe timeout in seconds | `2.0` |
| `--max-restarts <n>` | Max restarts allowed in window before flapping | `3` |
| `--window <sec>` | Sliding time window for flapping detection | `60` |
| `--webhook-url <url>` | Webhook URL for alert notifications | `None` |
| `--daemon` | Run watchdog detached in background | `false` |
| `--status` | Print current supervisor status JSON and exit | - |
| `--stop` | Stop running watchdog and child processes | - |
| `-h, --help` | Display usage instructions and exit | - |

---

## 🧪 Testing & Failure Injection Walkthrough

### Scenario A: Test Sudden Process Termination (`kill -9`)

```bash
# 1. Start watchdog in background
./watchdog.sh start --daemon --http-check http://127.0.0.1:8080/healthz

# 2. Query initial child PID
./watchdog.sh status | grep child_pid

# 3. Simulate sudden OS-level crash (e.g. Out of Memory killer)
kill -9 <child_pid>

# 4. Wait 3 seconds and check status
sleep 3
./watchdog.sh status
# Observe: Watchdog detected PID exit, restarted the service, and assigned a new PID!
```

---

### Scenario B: Trigger Fatal Application Panic via `/crash`

```bash
# Trigger unhandled fatal crash via HTTP endpoint
curl -X POST http://127.0.0.1:8080/crash

# Check status after 3 seconds
sleep 3
curl http://127.0.0.1:8080/healthz
# Observe: Service recovered automatically with HTTP 200 OK!
```

---

### Scenario C: Simulate Deadlock & Unresponsive Hang via `/hang`

```bash
# Put service into silent deadlock (process stays alive, but HTTP times out)
curl -X POST http://127.0.0.1:8080/hang

# Watchdog detects L7 HTTP probe timeout, terminates hanging PID, and restarts service
sleep 5
curl http://127.0.0.1:8080/healthz
# Expected: Service is responsive again!
```

---

### Scenario D: Flapping Protection Trigger

```bash
# Trigger 4 rapid crashes within 10 seconds to exceed max_restarts (3)
for i in {1..4}; do
  curl -s -X POST http://127.0.0.1:8080/crash || true
  sleep 1
done

# Inspect status
./watchdog.sh status
# Observe: state is "FLAPPING", restarts paused to protect CPU resources!
```

---

## 🤖 Running Automated Tests

An automated test suite (`test_watchdog.sh`) validates CLI arguments, normal startup, `kill -9` recovery, `/crash` recovery, `/hang` deadlock recovery, flapping rate limiting, and graceful shutdown:

```bash
./test_watchdog.sh
```

**Expected output:**

```text
======================================================
     Process Watchdog Daemon - Automated Tests        
======================================================

Suite 1: CLI Arguments & Help Handling
  [PASS] --help displays usage and exits 0
  [PASS] --status reports STOPPED when daemon is offline

Suite 2: Healthy Startup & L1/L7 Supervision
  [PASS] Flaky service spawned and responding 200 on /healthz
  [PASS] Watchdog state transitioned to HEALTHY

Suite 3: Hard Process Crash Recovery (kill -9)
  [PASS] Watchdog detected PID exit and restarted service (New PID: 14890)
  [PASS] Recovered service responding normally to HTTP traffic

Suite 4: Application-Level Endpoint Crash (/crash)
  [PASS] Watchdog recovered service following /crash trigger

Suite 5: Unresponsive Service / Deadlock Detection (/hang)
  [PASS] Watchdog detected L7 HTTP probe timeout and recovered deadlocked process

Suite 6: Crash Flapping Protection & Rate Limiting
  [PASS] Watchdog detected rapid crash cycle and entered FLAPPING state

Suite 7: Graceful Shutdown
  [PASS] Watchdog shutdown cleanly terminated supervised child process

======================================================
  Test Results: 9/9 Passed
  Status: ALL TESTS PASSED
======================================================
```

---

## 🐳 Running with Docker / Docker Compose

### Using Docker Compose

```bash
# Run watchdog and flaky service inside container
docker compose up -d

# Check service logs in real-time
docker compose logs -f

# Trigger crash inside container
curl -X POST http://localhost:8080/crash

# Run automated tests inside container
docker compose run --rm watchdog ./test_watchdog.sh
```

### Using Docker CLI

```bash
# Build image
docker build -t process-watchdog .

# Run container
docker run --rm -it -p 8080:8080 process-watchdog ./test_watchdog.sh
```

---

## 💡 Key SRE & Supervisor Best Practices Applied

1. **Dual-Layer Health Probing**:
   - L1 (PID polling) catches instant process terminations; L7 (HTTP probing) catches silent deadlocks.
2. **Crash Flapping Rate Limiting**:
   - Sliding-window timestamp tracking prevents runaway restart loops.
3. **Process Group Signal Isolation**:
   - Uses `os.killpg(os.getpgid(pid), signal.SIGTERM)` to ensure child process trees are terminated completely without leaving orphaned processes.
4. **Graceful Escalation**:
   - Sends `SIGTERM` first, waits up to 3 seconds for clean exit, and escalates to `SIGKILL` only if the process is unresponsive.
5. **Observability & Webhook Integration**:
   - Emits structured JSON status files and sends event alerts on state transitions.

---

## 🧹 Cleanup & Teardown

To ensure your local workstation or VM remains clean and ready for the next mini-project, follow these cleanup steps:

### 1. Stop Local Daemon & Clean Local Files

If you ran the watchdog locally on your host:

```bash
# Stop running watchdog and child services
./watchdog.sh stop 2>/dev/null || true

# Force kill any lingering mock service processes
pkill -f "flaky_service.py" 2>/dev/null || true

# Remove generated PID, status, and log files
rm -f watchdog.pid flaky_service.pid watchdog_status.json watchdog.log 2>/dev/null || true
```

### 2. Remove Docker Compose Resources

If you used `docker compose`:

```bash
# Stop and remove containers, networks, volumes, and locally built images
docker compose down --volumes --rmi local
```

### 3. Remove Standalone Docker Images and Containers

```bash
# Remove test container
docker rm -f process-watchdog-service 2>/dev/null || true

# Remove built Docker image
docker rmi process-watchdog 2>/dev/null || true
```

### 4. Verify Clean State

Confirm that no leftover processes, Docker resources, or ports remain open:

```bash
# Verify no lingering Python services are running
pgrep -fl "watchdog.py|flaky_service.py" || echo "No watchdog processes active"

# Verify port 8080 is released
lsof -i :8080 2>/dev/null || echo "Port 8080 is free"

# Verify no leftover containers exist
docker ps -a --filter "name=process-watchdog"

# Verify no leftover images exist
docker images "process-watchdog"
```
