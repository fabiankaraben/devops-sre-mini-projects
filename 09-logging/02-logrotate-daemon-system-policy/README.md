<!-- markdownlint-disable MD013 MD033 MD051 MD060 -->
# 02 - Logrotate Daemon System Policy & Zero-Loss SIGHUP Reloads

> A production-grade system logging policy implementing Linux logrotate, size-based and time-based rotation triggers, delayed gzip compression, retention lifecycle pruning, and non-disruptive SIGHUP daemon file descriptor reloading with zero data loss.

---

## 📋 Table of Contents

1. [Architectural Overview & Lifecycle Flow](#-architectural-overview--lifecycle-flow)
   - [Linux File Descriptor & Inode Lifecycle Diagram](#linux-file-descriptor--inode-lifecycle-diagram)
   - [The SIGHUP Rotation Sequence](#the-sighup-rotation-sequence)
2. [Theoretical Deep-Dive for Beginners](#-theoretical-deep-dive-for-beginners)
   - [The Inode & Open File Descriptor Problem in Linux](#the-inode--open-file-descriptor-problem-in-linux)
   - [Why `copytruncate` Causes Log Loss (The Race Condition)](#why-copytruncate-causes-log-loss-the-race-condition)
   - [Signal-Based Rotation (`create` + `postrotate` + `SIGHUP`)](#signal-based-rotation-create--postrotate--sighup)
   - [Why `delaycompress` is Essential for Asynchronous Buffers](#why-delaycompress-is-essential-for-asynchronous-buffers)
   - [Detailed Logrotate Directive Reference](#detailed-logrotate-directive-reference)
3. [Repository & Directory Structure](#-repository--directory-structure)
4. [Prerequisites & System Setup](#-prerequisites--system-setup)
5. [Quickstart Guide](#-quickstart-guide)
6. [Step-by-Step Hands-On Guide](#-step-by-step-hands-on-guide)
   - [Step 1: Inspect the Logrotate Policy](#step-1-inspect-the-logrotate-policy)
   - [Step 2: Build & Start the Linux Environment](#step-2-build--start-the-linux-environment)
   - [Step 3: Spawn the Background Writer Daemon](#step-3-spawn-the-background-writer-daemon)
   - [Step 4: Trigger Logrotate & Observe Inode Transitions](#step-4-trigger-logrotate--observe-inode-transitions)
   - [Step 5: Test Multi-Cycle Retention & Compression](#step-5-test-multi-cycle-retention--compression)
   - [Step 6: Run the Zero-Loss Verification Audit](#step-6-run-the-zero-loss-verification-audit)
7. [Troubleshooting & Common Gotchas](#-troubleshooting--common-gotchas)
8. [Resource Teardown & Complete Cleanup](#-resource-teardown--complete-cleanup)

---

## 🏛️ Architectural Overview & Lifecycle Flow

### Linux File Descriptor & Inode Lifecycle Diagram

```mermaid
flowchart TD
    subgraph HostLinux ["🐧 Linux Operating System / Container"]
        subgraph DaemonProcess ["⚙️ Application Daemon (PID: 42)"]
            FD["Open File Descriptor (FD 3)"]
            SignalHandler["Signal Handler: SIGHUP (kill -HUP)"]
            Buffer["I/O Buffer & Sequence Generator"]

            Buffer --> FD
            SignalHandler -. Triggers Reopen .-> FD
        end

        subgraph LogrotateSubsystem ["🔄 Logrotate Cron Engine"]
            Policy["/etc/logrotate.d/custom-app<br/>(size 50M, rotate 7, delaycompress)"]
            PostrotateHook["postrotate hook:<br/>kill -HUP $(cat /var/run/custom-app.pid)"]
            Compressor["gzip Compression Engine"]

            Policy --> PostrotateHook
            Policy --> Compressor
        end

        subgraph Filesystem ["💾 VFS File Table & Inodes (/var/log/custom-app/)"]
            InodeA["Inode #1001<br/>(Active writes)"]
            InodeB["Inode #2002<br/>(Newly created active log)"]
            ArchiveGz["Inode #3003 (app.log.2.gz)<br/>Compressed Historical Archive"]

            FD -->|Writes to Inode| InodeA
            Policy -->|1. Rename to app.log.1| InodeA
            Policy -->|2. Create new app.log| InodeB
            PostrotateHook -->|3. Send SIGHUP| SignalHandler
            FD -. 4. Switch to Inode .-> InodeB
            Compressor -->|5. Compress older .1 to .2.gz| ArchiveGz
        end
    end

    subgraph AuditTool ["🧪 Verification & Audit"]
        Verifier["verify_zero_loss.py<br/>• Decompresses .gz archives<br/>• Verifies monotonic sequence #1..N<br/>• Asserts 0 dropped logs"]
        Filesystem --> Verifier
    end
```

### The SIGHUP Rotation Sequence

1. **Active Log Generation**: The application daemon holds open file descriptor `FD 3` pointing to Inode `A` (`/var/log/custom-app/app.log`).
2. **Logrotate Triggers**: When the log exceeds `50MB` (or during scheduled daily cron), `logrotate` runs.
3. **Atomic Rename (`mv`)**: `logrotate` renames `app.log` to `app.log.1`. Crucially, Inode `A` **does not change**; the daemon continues writing to Inode `A` (now named `app.log.1`) without crashing.
4. **File Creation (`create`)**: `logrotate` creates a brand new, empty `app.log` with Inode `B` and sets permissions `0640 root root`.
5. **Signal Notification (`postrotate`)**: `logrotate` executes the `postrotate` hook, reading `/var/run/custom-app.pid` and sending `kill -HUP <PID>`.
6. **Graceful File Descriptor Reopening**: The daemon receives `SIGHUP`, flushes any in-memory buffers to disk (`fsync()`), closes `FD 3` pointing to Inode `A`, and opens the new `app.log` (Inode `B`).
7. **Delayed Compression (`delaycompress`)**: `app.log.1` remains uncompressed during this cycle so in-flight writes finish cleanly. On the *subsequent* rotation cycle, `app.log.1` is renamed to `app.log.2` and compressed to `app.log.2.gz`.
8. **Retention Cleanup (`rotate 7`)**: Older archives exceeding 7 generations (`app.log.8.gz`) are automatically unlinked and deleted.

---

## 🧠 Theoretical Deep-Dive for Beginners

### The Inode & Open File Descriptor Problem in Linux

In Linux, a filename is merely a human-readable pointer (directory entry or `dentry`) pointing to an **Inode number**. An Inode represents the actual data blocks and metadata on disk.

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                   HOW LINUX HANDLES OPEN FILE DESCRIPTORS                    │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Application opens "/var/log/app.log" -> Kernel assigns Inode 88001.      │
│ 2. Administrator or script runs: `mv /var/log/app.log /var/log/app.log.1`   │
│ 3. What happens?                                                            │
│    • Only the directory entry name changed.                                 │
│    • Inode 88001 is STILL OPEN by the application's file descriptor.        │
│    • The application continues writing to Inode 88001 (now app.log.1)!       │
│ 4. If you create a new empty "/var/log/app.log" (Inode 88002):              │
│    • The application DOES NOT know about Inode 88002.                       │
│    • The new file remains completely empty (0 bytes).                        │
│    • Rotated archives continue growing infinitely!                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

To fix this, the application process must be explicitly instructed to **close the old file descriptor and open the new file path**. This is achieved using POSIX signals.

### Why `copytruncate` Causes Log Loss (The Race Condition)

Many teams use `copytruncate` because it avoids having to configure application signal handlers. However, `copytruncate` is dangerous for high-throughput applications:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE COPYTRUNCATE LOG LOSS WINDOW                         │
├─────────────────────────────────────────────────────────────────────────────┤
│ Step 1: `logrotate` copies 50MB from app.log to app.log.1                   │
│ Step 2: `logrotate` truncates app.log to 0 bytes                            │
│                                                                             │
│ ⚠️  THE DANGER WINDOW:                                                      │
│ During the milliseconds between Step 1 (Copy) and Step 2 (Truncate),        │
│ the daemon writes 20 new log events to app.log.                             │
│ When Step 2 executes, those 20 events are PERMANENTLY DELETED!              │
│                                                                             │
│ Verdict: Never use copytruncate on critical transactional systems.         │
│          Always use `create` + `postrotate` with `SIGHUP` reload!           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Signal-Based Rotation (`create` + `postrotate` + `SIGHUP`)

POSIX signals allow out-of-band communication with running daemons:

- **`SIGHUP` (Signal 1)**: Traditionally used by Unix daemons (Nginx, Apache, Prometheus, Custom Apps) to trigger configuration reloading or log file reopening without restarting the process.
- **Zero Loss Guarantee**: Because `logrotate` creates the new file first and the daemon flushes and reopens on signal reception, not a single log entry is dropped or overwritten.

### Why `delaycompress` is Essential for Asynchronous Buffers

When `compress` is enabled in `logrotate`:

- Without `delaycompress`: `app.log.1` is immediately compressed to `app.log.1.gz` right after renaming. If a daemon has not yet finished handling its `SIGHUP` signal or is flushing buffered pages, writing to a file being actively compressed by `gzip` causes corrupted gzip archives and lost logs.
- With `delaycompress`: `app.log.1` is left as uncompressed plaintext for one full cycle. Only when the *next* rotation occurs is it compressed to `app.log.2.gz`.

### Detailed Logrotate Directive Reference

| Directive | Purpose | Best Practice Rationale |
| :--- | :--- | :--- |
| `daily` / `hourly` | Defines base rotation check frequency | Ensures logs are checked on a scheduled basis |
| `maxsize 50M` | Rotates immediately if file exceeds 50MB | Prevents runaway disk filling during unexpected spikes |
| `rotate 7` | Retains exactly 7 historical archive generations | Enforces disk quotas and legal data retention compliance |
| `missingok` | Do not emit errors if the log file is absent | Prevents cron alert noise if the service was newly created |
| `notifempty` | Do not rotate empty 0-byte log files | Avoids generating hundreds of useless empty archives |
| `compress` | Compresses historical archives with `gzip` | Reduces log storage footprint by 80%–90% |
| `delaycompress` | Postpones compression of `.1` until next cycle | Guarantees zero write collisions during daemon signal reload |
| `create 0640 root root`| Creates new empty log file with specified mode/owner | Enforces least-privilege security permissions immediately |
| `sharedscripts` | Runs `postrotate` once per cycle, not per file | Avoids sending redundant signals when multiple logs rotate |
| `postrotate ... endscript` | Shell commands executed after log rotation | Sends `kill -HUP` to notify daemon to reopen file descriptors |

---

## 📁 Repository & Directory Structure

```text
09-logging/02-logrotate-daemon-system-policy/
├── .gitignore                      # Python bytecode and temporary file exclusions
├── Dockerfile                      # Debian Linux environment with logrotate, cron, gzip
├── README.md                       # Comprehensive educational documentation & guide
├── cleanup.sh                      # Resource teardown & Docker image purger script
├── docker-compose.yml              # Service orchestration definition
├── test_logrotate.sh               # Automated end-to-end multi-cycle rotation test runner
├── verify_zero_loss.py             # Analytical zero-loss and sequence continuity auditor
├── config/
│   ├── custom-app.conf             # Production logrotate policy with SIGHUP postrotate
│   └── custom-app-copytruncate.conf # Educational reference for copytruncate comparison
└── daemon/
    ├── continuous_log_writer.py    # Resilient log daemon with monotonic indexing & SIGHUP handler
    └── requirements.txt            # Zero-dependency Python standard library declaration
```

---

## 🔧 Prerequisites & System Setup

Ensure the following tools are installed on your host machine:

- **Docker Engine** (or **OrbStack** / **Docker Desktop**): `v20.10+`
- **Docker Compose**: `v2.0+`
- **Python 3**: `v3.9+` (for optional local inspection)

Verify your local environment:

```bash
docker --version
docker compose version
python3 --version
```

---

## ⚡ Quickstart Guide

To build the Linux environment, start the high-throughput writer daemon, simulate multiple logrotate cycles, and verify 100% zero log loss with a single command:

```bash
cd 09-logging/02-logrotate-daemon-system-policy
./test_logrotate.sh
```

When finished, clean up all created containers and images:

```bash
./cleanup.sh --all
```

---

## 📖 Step-by-Step Hands-On Guide

### Step 1: Inspect the Logrotate Policy

View the production policy file located in `config/custom-app.conf`:

```bash
cat config/custom-app.conf
```

Notice the critical combination of directives:

- `maxsize 50M` and `rotate 7`: Restricts storage usage while keeping historical audit trails.
- `create 0640 root root`: Creates the replacement active log file.
- `postrotate`: Sends `kill -HUP $(cat /var/run/custom-app.pid)`.

### Step 2: Build & Start the Linux Environment

Start the container stack in detached mode:

```bash
docker compose up -d --build
```

Verify that the container is running:

```bash
docker compose ps
```

### Step 3: Spawn the Background Writer Daemon

Spawn the continuous log writer inside the container:

```bash
docker compose exec -d logrotate-env python3 /app/daemon/continuous_log_writer.py \
    --log-file /var/log/custom-app/app.log \
    --pid-file /var/run/custom-app.pid \
    --rate 50.0 \
    --verbose
```

Check the active log file and note its initial Inode number:

```bash
docker compose exec logrotate-env ls -lai /var/log/custom-app/
```

View the active stream in real time:

```bash
docker compose exec logrotate-env tail -f /var/log/custom-app/app.log
```

### Step 4: Trigger Logrotate & Observe Inode Transitions

Force a manual execution of `logrotate` in verbose mode:

```bash
docker compose exec logrotate-env logrotate -f -v /etc/logrotate.d/custom-app
```

Inspect `/var/log/custom-app/` again:

```bash
docker compose exec logrotate-env ls -lai /var/log/custom-app/
```

Notice the Inode transition:

- `app.log.1` now holds the **old Inode** where the initial log entries were written.
- `app.log` has a **brand new Inode**.
- The writer daemon received `SIGHUP`, reopened `app.log`, and logged:

```json
{"event": "log_file_reopened", "old_inode": 1001, "new_inode": 2002, "signal": "SIGHUP"}
```

### Step 5: Test Multi-Cycle Retention & Compression

Trigger several consecutive rotation cycles:

```bash
for i in {2..8}; do
    docker compose exec logrotate-env logrotate -f /etc/logrotate.d/custom-app
    sleep 1
done
```

List all files in the directory:

```bash
docker compose exec logrotate-env ls -lh /var/log/custom-app/
```

Observe the lifecycle:

- `app.log`: Current active uncompressed log.
- `app.log.1`: Most recent rotated uncompressed log (`delaycompress`).
- `app.log.2.gz` through `app.log.7.gz`: Historical gzip-compressed archives.
- Older archives beyond `rotate 7` were automatically deleted.

### Step 6: Run the Zero-Loss Verification Audit

Execute `verify_zero_loss.py` to decompress all archives and audit sequence continuity:

```bash
docker compose exec logrotate-env python3 /app/verify_zero_loss.py \
    --log-dir /var/log/custom-app \
    --base-name app.log
```

Expected output:

```text
========================================================================
  📊 LOGROTATE ZERO-LOSS SEQUENCE CONTINUITY AUDIT REPORT
========================================================================

  Target Log Directory: /var/log/custom-app
  Base Log File:        app.log
  Total Files Audited:  8
  Total Log Records:    1420
  Sequence Range:       [#1 → #1420]

  Discovered Log Archives & Inodes Breakdown:
  ┌──────────────────────┬──────────┬────────────┬──────────────┬──────────────┐
  │ File Name            │ Size (B) │ Gzip Enc?  │ Record Count │ Sequence Range│
  ├──────────────────────┼──────────┼────────────┼──────────────┼──────────────┤
  │ app.log              │     8420 │ No (plain) │           40 │ #1381 - #1420│
  │ app.log.1            │    32150 │ No (plain) │          160 │ #1221 - #1380│
  │ app.log.2.gz         │     4102 │ Yes (gzip) │          200 │ #1021 - #1220│
  │ app.log.3.gz         │     4095 │ Yes (gzip) │          200 │ # 821 - #1020│
  │ app.log.4.gz         │     4088 │ Yes (gzip) │          200 │ # 621 - # 820│
  │ app.log.5.gz         │     4091 │ Yes (gzip) │          200 │ # 421 - # 620│
  │ app.log.6.gz         │     4100 │ Yes (gzip) │          200 │ # 221 - # 420│
  │ app.log.7.gz         │     4096 │ Yes (gzip) │          220 │ #   1 - # 220│
  └──────────────────────┴──────────┴────────────┴──────────────┴──────────────┘

  Integrity Assertions:
  • Dropped / Missing Entries:  0 (Zero Loss Verified!)
  • Duplicate Sequence IDs:     0 (Unique Monotonic Indexing)
  • SIGHUP Reopen Events Logged: 7 Transitions

========================================================================

✅ VERIFICATION PASSED: Zero log entries dropped during rotation cycles!
```

---

## 🛠️ Troubleshooting & Common Gotchas

### 1. Logrotate Ignores Configuration ("Ignoring insecure permissions")

- **Symptom**: `logrotate` outputs `Ignoring /etc/logrotate.d/custom-app because of bad file mode or ownership`.
- **Cause**: On Debian/Ubuntu, `logrotate` requires configuration files to be owned by `root:root` with permissions `0644` or `0444` (must not be group-writable or world-writable).
- **Fix**: Run `chown root:root /etc/logrotate.d/custom-app && chmod 0644 /etc/logrotate.d/custom-app`.

### 2. Rotated Log Files Keep Growing While `app.log` Remains 0 Bytes

- **Symptom**: `app.log.1` continues receiving writes after rotation, while `app.log` stays at 0 bytes.
- **Cause**: The application daemon did not receive or handle `SIGHUP`. It is still holding the open file descriptor to the original Inode.
- **Fix**: Verify that the PID file exists (`/var/run/custom-app.pid`) and contains the correct PID. Ensure the application registers a `SIGHUP` signal handler that closes and reopens the file.

### 3. Logrotate Error: "parent directory has insecure permissions"

- **Symptom**: `error: skipping "/var/log/custom-app/app.log" because parent directory has insecure permissions`.
- **Cause**: The directory `/var/log/custom-app` is owned by a non-root user or has world-write permissions (`0777`).
- **Fix**: Set directory ownership to `root:root` with `chmod 0755 /var/log/custom-app` or use `su root root` inside the logrotate config.

---

## 🧹 Resource Teardown & Complete Cleanup

To clean up all created resources and return your host to a pristine state:

### Standard Teardown (Stops Containers & Removes Networks)

```bash
./cleanup.sh
```

### Complete Purge (Removes Built Docker Images & Caches)

```bash
./cleanup.sh --all
```

### Verify Clean State

```bash
docker ps -a --filter "name=logrotate-system-daemon"
docker images "mini-proj-09-02-logrotate"
docker network ls --filter "name=logrotate-stack-net"
```

Expected output: Zero remaining containers, zero dangling networks.
