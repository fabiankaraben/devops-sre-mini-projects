# Mini-Project 02: Log File Rotation and Archiver

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Docker / macOS)  

---

## 🎯 Overview & Context

In production environments, services generate gigabytes of operational and access logs every day. If left unmanaged, log files quickly consume available filesystem space, leading to system degradation or total service outages (e.g. disk-full `ENOSPC` errors).

However, rotating log files on a live Linux server is not as simple as running `mv app.log app.log.1`. When a background process opens a log file, the Linux kernel assigns an **open file descriptor (FD)** referencing an **inode** on the storage device. If you rename or move the file, the running process continues writing to the exact same inode (now under the new name), failing to free up active log space.

This mini-project teaches foundational Linux file descriptor mechanics, atomic log rotation techniques, non-destructive archiving with `gzip`, ISO-8601 timestamping, and automatic retention policy enforcement.

---

## 🧠 Linux Internals Deep-Dive

### 1. Inodes vs. Filenames

On POSIX filesystems (ext4, XFS, APFS), a directory is simply a table that maps human-readable filenames to metadata pointers called **inodes**:

```text
+-------------------+        +--------------------+        +--------------------+
|  Directory Entry  | =====> |       Inode        | =====> |    Data Blocks     |
|   "app.log"       |        | (ID: 419201, size) |        | (Actual log bytes) |
+-------------------+        +--------------------+        +--------------------+
```

When a process executes `open("logs/app.log", O_WRONLY | O_APPEND)`, the kernel resolves the inode and assigns a numeric **File Descriptor (FD)** (e.g., `FD 3`). All subsequent `write()` system calls write directly to that inode, regardless of what happens to the directory entry.

```text
[Running Daemon] ---> FD 3 ---> Inode 419201 (app.log)
```

If you execute `mv app.log app_backup.log`:

- The inode number (`419201`) does not change.
- The process continues writing to Inode `419201`.
- **Result**: No new `app.log` is created, and all new logs end up in `app_backup.log`!

---

### 2. Solving the Inode Problem: Two Strategies

#### Strategy A: `copytruncate` (Default in this project)

1. **Copy**: Copy the contents of the active log file to a temporary archive location (`cp -p app.log /tmp/archive_copy`).
2. **Truncate**: Empty the active file in-place (`: > app.log` or `truncate -s 0 app.log`).
3. **Compress**: Compress the copied file using `gzip` and move it to the archive directory.

```text
Step 1: cp -p app.log temp.log
Step 2: : > app.log          (Inode remains unchanged; file length reset to 0)
Step 3: gzip temp.log -> app_2026-08-21T10-00-00Z.log.gz
```

*Advantage*: Zero configuration required on the running service; works with any application.

---

#### Strategy B: Rename and Signal (`SIGHUP` / `SIGUSR1`)

1. **Rename**: Move `app.log` to `app.log.1`.
2. **Signal**: Send a POSIX signal (`kill -USR1 <PID>` or `kill -HUP <PID>`) instructing the daemon's signal handler to close its current file descriptor and re-open `logs/app.log`.
3. **Compress**: Compress `app.log.1` into the archive directory.

```text
Step 1: mv app.log app.log.1
Step 2: kill -USR1 <PID>    (Daemon closes old FD and calls open("app.log"))
Step 3: gzip app.log.1 -> archive/app_2026-08-21T10-00-00Z.log.gz
```

*Advantage*: Eliminates the small race-condition window between copying and truncating.

---

## 📂 Project Structure

```text
02-log-file-rotation-archiver/
├── log_rotate.sh          # Main rotation, compression, and retention engine
├── mock_log_producer.py   # Background daemon simulating active web server logs
├── test_log_rotate.sh     # Automated 12-point end-to-end test suite
├── Dockerfile             # Multi-arch Linux environment with python3 and gzip
├── docker-compose.yml     # Zero-setup Docker Compose definition
└── README.md              # Educational guide and cleanup procedures
```

---

## 🚀 Quickstart & Usage

### 1. Direct Execution (Linux / macOS)

Make scripts executable:

```bash
chmod +x log_rotate.sh mock_log_producer.py test_log_rotate.sh
```

Inspect available CLI options:

```bash
./log_rotate.sh --help
```

---

### 2. CLI Options Reference

| Option | Description | Default |
| :--- | :--- | :---: |
| `--log-dir <path>` | Directory containing active logs to rotate | `./logs` |
| `--archive-dir <path>` | Target directory for compressed archives | `./archive` |
| `--pattern <glob>` | File matching glob pattern | `*.log` |
| `--max-size <size>` | Rotate if file size exceeds threshold (e.g. `500K`, `10M`, `1G`) | `0` (off) |
| `--max-age-days <days>` | Rotate files modified more than $N$ days ago | `0` (off) |
| `--max-age-mins <mins>` | Rotate files modified more than $N$ minutes ago | `0` (off) |
| `--retention-days <days>` | Delete archive files older than $N$ days from archive directory | `0` (off) |
| `--retention-count <count>` | Keep only the most recent $N$ archives per log pattern | `0` (off) |
| `--no-compress` | Keep uncompressed archive files (skip gzip) | `false` |
| `--method <method>` | Rotation strategy: `copytruncate` or `signal` | `copytruncate` |
| `--pid <pid>` | Target daemon PID (required when method is `signal`) | - |
| `--signal <signal>` | Signal sent to daemon after rename (e.g. `USR1`, `HUP`) | `USR1` |
| `--dry-run` | Preview rotations and show actions without altering files | `false` |
| `--json` | Output execution summary report in JSON format | `false` |
| `--pretty` | Format JSON output with indentation | `false` |
| `-h, --help` | Display usage instructions and exit | - |
| `-v, --version` | Display version information | - |

---

## 📋 JSON Output Schema

When executed with `--json` and `--pretty`, `log_rotate.sh` emits a machine-parseable execution report:

```json
{
  "timestamp": "2026-08-21T11:06:50Z",
  "log_dir": "./logs",
  "archive_dir": "./archive",
  "method": "copytruncate",
  "compressed": true,
  "dry_run": false,
  "summary": {
    "files_rotated": 1,
    "archives_pruned": 0,
    "total_original_bytes": 1048576,
    "total_compressed_bytes": 84210,
    "bytes_saved": 964366
  },
  "rotated_files": [
    {
      "file": "./logs/app.log",
      "archive": "./archive/app_2026-08-21T11-06-50Z.log.gz",
      "original_bytes": 1048576,
      "compressed_bytes": 84210
    }
  ],
  "pruned_archives": []
}
```

---

## 🧪 Testing & Verification Scenarios

### Scenario A: Test with Live Background Log Producer

Follow these steps to observe non-destructive log rotation in action:

#### Step 1: Start Mock Log Producer in Background

Generate 10 logs per second writing to `./logs/app.log`:

```bash
python3 mock_log_producer.py --log-file ./logs/app.log --rate 10 &
PRODUCER_PID=$!
echo "Producer running with PID: $PRODUCER_PID"
```

#### Step 2: Inspect Open File Descriptors

Check that the producer holds an active open write handle:

```bash
# On Linux:
ls -l /proc/$PRODUCER_PID/fd 2>/dev/null || true

# On macOS / Linux (using lsof):
lsof -p $PRODUCER_PID | grep "app.log"
```

#### Step 3: Trigger Log Rotation

Rotate active logs using `copytruncate` and compress with `gzip`:

```bash
./log_rotate.sh --log-dir ./logs --archive-dir ./archive --json --pretty
```

#### Step 4: Verify Active Logging Continues Uninterrupted

Check that `./logs/app.log` continues receiving new lines:

```bash
tail -f ./logs/app.log
```

#### Step 5: Verify Compressed Archive

Inspect the created gzip archive without uncompressing:

```bash
gzip -dc ./archive/app_*.log.gz | head -n 5
```

#### Step 6: Stop Background Producer

```bash
kill -INT $PRODUCER_PID
```

---

### Scenario B: Dry Run Simulation

Preview rotations without creating or modifying files:

```bash
./log_rotate.sh --log-dir ./logs --archive-dir ./archive --dry-run
```

---

### Scenario C: Enforcing Archive Retention

Automatically delete old archives to enforce storage quotas:

```bash
# Keep only the 5 most recent archive files
./log_rotate.sh --retention-count 5

# Purge archives older than 30 days
./log_rotate.sh --retention-days 30
```

---

## 🤖 Running Automated Tests

The repository includes a comprehensive 12-point test suite (`test_log_rotate.sh`) that validates flag parsing, dry-run simulation, size/age rotations, gzip integrity, retention policies, and live background daemon integration:

```bash
./test_log_rotate.sh
```

**Expected output:**

```text
======================================================
  Log File Rotation and Archiver - Automated Tests   
======================================================

Suite 1: CLI Arguments & Help Handling
  [PASS] --help displays usage and exits 0
  [PASS] Unknown flag triggers exit code 2 (ERROR)
  [PASS] Non-existent log directory triggers exit code 2

Suite 2: Dry Run Mode Simulation
  [PASS] Dry-run completes successfully with exit code 0
  [PASS] Dry-run did not alter active files or write archives

Suite 3: Size-Based Rotation & Compression
  [PASS] Size-based rotation executes with exit code 0
  [PASS] large.log truncated in-place while small.log preserved
  [PASS] Rotated gzip archive is valid and uncorrupted

Suite 4: Retention Policy & Archive Pruning
  [PASS] --retention-count 2 pruned older archives down to 2

Suite 5: Active Background Daemon Non-Destructive Rotation
  [PASS] mock_log_producer actively writing entries (15 lines)
  [PASS] Active log rotation succeeded with uninterrupted logging (19 post-rotation lines)
  [PASS] Rotation summary outputs valid JSON schema

======================================================
  Test Results: 12/12 Passed
  Status: ALL TESTS PASSED
======================================================
```

---

## 🐳 Running with Docker / Docker Compose

If you want to execute inside an isolated Ubuntu Linux container:

### Using Docker Compose

```bash
# Run rotation check inside container
docker compose run --rm log-archiver

# Run automated test suite inside container
docker compose run --rm log-archiver ./test_log_rotate.sh

# Open an interactive shell inside container
docker compose run --rm --entrypoint bash log-archiver
```

### Using Docker CLI

```bash
# Build image
docker build -t log-archiver .

# Run tests
docker run --rm -it log-archiver ./test_log_rotate.sh
```

---

## 💡 Key SRE & Bash Best Practices Applied

1. **`set -euo pipefail`**:
   - Eliminates silent failures in pipelines and uninitialized variables.
2. **In-Place Atomic Truncation**:
   - Using `: > "$log_file"` safely resets the file size to 0 bytes without destroying the open inode handle.
3. **ISO-8601 Timestamp Standard**:
   - Formats archives as `YYYY-MM-DDTHH-MM-SSZ` to ensure chronological filename sorting.
4. **Non-Destructive Signal Handling**:
   - `mock_log_producer.py` implements handlers for `SIGUSR1` and `SIGHUP` to demonstrate dynamic file descriptor re-opening.
5. **Gzip Integrity Verification**:
   - Validates compression streams with `gzip -t` during testing to prevent corrupted archive files.

---

## 🧹 Cleanup & Teardown

To ensure your local workstation or VM remains clean and ready for the next mini-project, follow these cleanup steps to remove all generated logs, archives, Docker containers, and images:

### 1. Remove Docker Compose Resources

If you used `docker compose`, stop and remove all associated containers, networks, volumes, and locally built images:

```bash
# Stop and remove containers, networks, volumes, and local images
docker compose down --volumes --rmi local
```

### 2. Remove Standalone Docker Images and Containers

If you used the standalone `docker build` / `docker run` commands:

```bash
# Remove any test containers
docker rm -f log-archiver-service 2>/dev/null || true

# Remove the built Docker image
docker rmi log-archiver 2>/dev/null || true
```

### 3. Clean Local Test Logs & Archives

If you ran tests or the log producer directly on your host:

```bash
# Remove local logs and archive directories created during testing
rm -rf ./logs ./archive 2>/dev/null || true

# Remove temporary test sandboxes from /tmp
rm -rf /tmp/log_rotate_* /tmp/rotate_* 2>/dev/null || true
```

### 4. Verify Clean State

Confirm that no leftover Docker resources, background producer processes, or temporary files remain:

```bash
# Verify no leftover log producer processes are running
pgrep -fl mock_log_producer || echo "No mock producer processes active"

# Verify no leftover containers exist
docker ps -a --filter "name=log-archiver"

# Verify no leftover images exist
docker images "log-archiver"
```
