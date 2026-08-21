# Mini-Project 03: User and Group Batch Provisioner

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Disposable Docker Container / Linux VM / OrbStack) or Cloud (AWS EC2)  

---

## 🎯 Overview & Context

In production server fleets, managing user access, group memberships, SSH authentication keys, and administrative `sudo` privileges manually is error-prone and insecure. Automation tools like Ansible, Puppet, and cloud IAM agents all build upon foundational Linux user administration commands (`useradd`, `usermod`, `groupadd`, `visudo`).

This mini-project teaches how to build an **idempotent, declarative batch provisioning system** in Bash that:

1. Reads user specifications from a declarative CSV manifest.
2. Idempotently provisions primary and secondary Linux groups.
3. Creates or updates user accounts with custom login shells and home directories.
4. Enforces strict OpenSSH cryptographic key permissions (`0700` directory / `0600` `authorized_keys`).
5. Configures granular `sudo` privileges via `/etc/sudoers.d/` with automated syntax validation via `visudo -c`.
6. Handles secure account deactivation (nologin shells and locked passwords).
7. Provides an automated rollback utility (`cleanup_users.sh`) and an end-to-end verification test suite.

---

## 🧠 Linux Identity & Access Internals Deep-Dive

### 1. The Core Linux User Databases

Linux systems track identities across three primary flat files in `/etc`:

- **`/etc/passwd`**: Maps usernames to UID, Primary GID, Home Directory, and Login Shell.

  ```text
  alice:x:1001:1001:Alice DevOps:/home/alice:/bin/bash
  ```

- **`/etc/shadow`**: Stores cryptographic password hashes and account expiration metadata. A leading `!` or `*` locks the account from password authentication.
- **`/etc/group`**: Defines group names, GIDs, and comma-separated supplementary members.

  ```text
  developers:x:1001:alice,bob
  docker:x:999:alice
  ```

---

### 2. OpenSSH Strict Permission Requirements

OpenSSH enforces a security policy called **`StrictModes`** (enabled by default in `/etc/ssh/sshd_config`). If permissions on a user's home directory or `.ssh` folder are too permissive, the SSH daemon silently refuses public key authentication to protect against unauthorized modifications by other local users:

```text
/home/<user>/                    Mode: 0750 or 0700 (drwx------)
  └── .ssh/                      Mode: 0700         (drwx------)  Owner: <user>:<group>
       └── authorized_keys       Mode: 0600         (-rw-------)  Owner: <user>:<group>
```

> [!IMPORTANT]
> If `authorized_keys` has permissions `0644` (world-readable) or `0666` (world-writable), or if `.ssh` is group-writable (`0770`), OpenSSH will reject the key and fail with `Permission denied (publickey)`.

---

### 3. Safe Privilege Escalation with `/etc/sudoers.d/`

Rather than editing the monolithic `/etc/sudoers` file directly, modern Linux distributions support modular drop-in files in `/etc/sudoers.d/`:

```text
/etc/sudoers.d/99-user-alice
Content: alice ALL=(ALL) NOPASSWD:ALL
Mode: 0440 (Read-only for root/group)
```

**Syntax Validation with `visudo`:**  
A syntax error in `/etc/sudoers` can lock administrators out of root access. `provision_users.sh` automatically executes `visudo -c -f /etc/sudoers.d/99-user-<user>` to validate syntax before leaving any drop-in active on disk.

---

### 4. What is Idempotency?

An operation is **idempotent** if executing it once has the same effect as executing it multiple times:

$$\text{Apply}(\text{State}) = \text{Apply}(\text{Apply}(\text{State}))$$

- If user `alice` does not exist $\rightarrow$ Create account.
- If user `alice` already exists $\rightarrow$ Update group memberships and SSH keys without returning an error or corrupting existing data.

---

## 📂 Project Structure

```text
03-user-group-batch-provisioner/
├── provision_users.sh        # Main declarative batch provisioning script
├── users_manifest.csv        # Declarative CSV dataset defining user access
├── cleanup_users.sh          # Rollback script to reset environment cleanly
├── test_provision_users.sh   # Automated test suite with idempotency checks
├── Dockerfile                # Disposable Ubuntu container with sudo & ssh-client
├── docker-compose.yml        # Docker Compose definition for safe local testing
└── README.md                 # Educational guide and cleanup procedures
```

---

## 📋 CSV Manifest Specification

The `users_manifest.csv` file defines the desired state of all system users:

```csv
username,primary_group,secondary_groups,shell,sudo_access,status,ssh_public_key
alice,developers,"docker,adm",/bin/bash,yes,active,"ssh-ed25519 AAAAC3NzaC... alice@company.internal"
bob,developers,"docker",/bin/bash,no,active,"ssh-ed25519 AAAAC3NzaC... bob@company.internal"
charlie,qa,"",/bin/sh,no,active,"ssh-ed25519 AAAAC3NzaC... charlie@company.internal"
dave,contractors,"",/bin/bash,no,inactive,"ssh-ed25519 AAAAC3NzaC... dave@company.internal"
```

| Field | Description | Example |
| :--- | :--- | :--- |
| `username` | Unique POSIX-compliant username | `alice` |
| `primary_group` | Primary Linux group (created automatically if missing) | `developers` |
| `secondary_groups` | Comma-separated supplementary groups (in quotes) | `"docker,adm"` |
| `shell` | Login shell path | `/bin/bash` |
| `sudo_access` | Administrative privileges (`yes` or `no`) | `yes` |
| `status` | Account state (`active` or `inactive`) | `active` |
| `ssh_public_key` | OpenSSH public key for `.ssh/authorized_keys` | `ssh-ed25519 AAAAC3...` |

---

## 🚀 Quickstart & Usage

### 1. Direct Execution

Make scripts executable:

```bash
chmod +x provision_users.sh cleanup_users.sh test_provision_users.sh
```

Preview actions with `--dry-run` (does not require root privileges):

```bash
./provision_users.sh --manifest users_manifest.csv --dry-run --json --pretty
```

Execute live provisioning (requires root/sudo privileges):

```bash
sudo ./provision_users.sh --manifest users_manifest.csv --json --pretty
```

---

### 2. CLI Options Reference

| Flag | Description | Default |
| :--- | :--- | :---: |
| `-m, --manifest <file>` | Path to the user manifest CSV | `users_manifest.csv` |
| `--dry-run` | Simulate actions without modifying `/etc/passwd` or files | `false` |
| `--json` | Output execution report in structured JSON format | `false` |
| `--pretty` | Format JSON output with 2-space indentation | `false` |
| `-h, --help` | Display usage instructions and exit | - |
| `-v, --version` | Display version information and exit | - |

---

## 📋 JSON Output Schema

```json
{
  "timestamp": "2026-08-21T11:10:00Z",
  "manifest": "users_manifest.csv",
  "dry_run": false,
  "summary": {
    "created": 3,
    "updated": 0,
    "deactivated": 1,
    "errors": 0
  },
  "created_users": [
    {
      "username": "alice",
      "action": "created",
      "primary_group": "developers"
    },
    {
      "username": "bob",
      "action": "created",
      "primary_group": "developers"
    },
    {
      "username": "charlie",
      "action": "created",
      "primary_group": "qa"
    }
  ],
  "updated_users": [],
  "deactivated_users": [
    {
      "username": "dave",
      "action": "deactivated",
      "shell": "/usr/sbin/nologin"
    }
  ],
  "errors": []
}
```

---

## 🧪 Testing & Verification Scenarios

### Scenario A: Dry Run Simulation (Zero Risk)

Verify manifest parsing without making system modifications:

```bash
./provision_users.sh --manifest users_manifest.csv --dry-run
```

---

### Scenario B: Live Provisioning Inside Disposable Docker Container

To avoid modifying your local workstation user database, use the included Docker Compose setup:

```bash
# Execute provisioning inside disposable container
docker compose run --rm provisioner --manifest users_manifest.csv --json --pretty
```

---

### Scenario C: Inspect Provisioned System State

Verify created accounts, group memberships, and file permissions:

```bash
# 1. Verify user accounts in /etc/passwd
id alice
id bob

# 2. Verify secondary group memberships
id -Gn alice
# Expected: developers docker adm

# 3. Verify strict SSH permissions
ls -ld /home/alice/.ssh
# Expected: drwx------ (0700) owner: alice developers

ls -l /home/alice/.ssh/authorized_keys
# Expected: -rw------- (0600) owner: alice developers

# 4. Verify inactive user has nologin shell
getent passwd dave
# Expected: /usr/sbin/nologin or /sbin/nologin
```

---

### Scenario D: Idempotency Verification

Run the provisioner a second time against the same manifest:

```bash
docker compose run --rm provisioner --manifest users_manifest.csv
```

*Expected behavior*: The script completes with exit code 0 without creating duplicate users or generating errors.

---

### Scenario E: Rollback with `cleanup_users.sh`

Cleanly remove all provisioned users, home directories, and sudoers drop-in files:

```bash
# Inside Docker or with sudo on host:
./cleanup_users.sh --manifest users_manifest.csv
```

---

## 🤖 Running Automated Tests

An automated test suite (`test_provision_users.sh`) validates CLI arguments, dry-run simulation, user/group creation, SSH key permissions (`0700`/`0600`), sudoers syntax via `visudo -c`, deactivation handling, idempotency, and rollback:

### Run Tests in Docker (Recommended)

```bash
docker compose run --rm provisioner ./test_provision_users.sh
```

**Expected output:**

```text
======================================================
  User & Group Batch Provisioner - Automated Tests   
======================================================

Suite 1: CLI Arguments & Help Handling
  [PASS] --help displays usage and exits 0
  [PASS] Missing manifest file triggers exit code 2

Suite 2: Dry Run Mode Simulation
  [PASS] Dry-run completes successfully without root requirement
  [PASS] Dry-run outputs valid JSON schema
  [PASS] JSON payload confirms dry_run flag and simulated actions

Suite 3: Live Provisioning & Security Enforcement
  [PASS] Live batch provisioning executed with exit code 0
  [PASS] Users alice, bob, and charlie created in system
  [PASS] Primary/Secondary groups assigned correctly to alice (developers docker adm)
  [PASS] SSH permissions strictly enforced (dir: 0700, keys: 0600)
  [PASS] Sudoers drop-in file validated via visudo -c
  [PASS] Inactive user dave assigned nologin shell (/usr/sbin/nologin)

Suite 4: Idempotency Verification
  [PASS] Second provisioning run succeeds idempotently without errors

Suite 5: Rollback & Environment Cleanup
  [PASS] cleanup_users.sh executes rollback with exit code 0
  [PASS] Provisioned users, home dirs, and sudoers cleanly purged

======================================================
  Test Results: 13/13 Passed
  Status: ALL TESTS PASSED
======================================================
```

---

## 🐳 Running with Docker / Docker Compose

### Using Docker Compose

```bash
# Run dry run
docker compose run --rm provisioner

# Run live provisioning
docker compose run --rm provisioner --manifest users_manifest.csv

# Run automated tests
docker compose run --rm provisioner ./test_provision_users.sh

# Open interactive root shell
docker compose run --rm --entrypoint bash provisioner
```

### Using Docker CLI

```bash
# Build image
docker build -t user-provisioner .

# Run test suite
docker run --rm -it user-provisioner ./test_provision_users.sh
```

---

## 💡 Key SRE & Security Best Practices Applied

1. **Idempotency by Design**:
   - Checks `getent group` and `id -u` before invoking creation commands, ensuring repeat runs never fail.
2. **Strict OpenSSH Permissions**:
   - Automatically applies `0700` to `.ssh` directories and `0600` to `authorized_keys`, preventing SSH authorization lockouts.
3. **Automated `visudo` Syntax Checks**:
   - Executes `visudo -c -f <file>` before saving sudoers drop-in files to prevent syntax corruption.
4. **Graceful Deactivation**:
   - Disables accounts by locking password hashes and pointing login shells to `/usr/sbin/nologin` rather than deleting accounts abruptly.
5. **Disposable Sandbox Testing**:
   - Provides containerized Docker setup so engineers can experiment with identity and access management safely without risking their host operating systems.

---

## 🧹 Cleanup & Teardown

To ensure your local workstation or VM remains clean and ready for the next mini-project, follow these cleanup steps:

### 1. Remove Docker Compose Resources

If you used `docker compose`, stop and delete all containers, networks, volumes, and locally built images:

```bash
# Stop and remove containers, networks, volumes, and local images
docker compose down --volumes --rmi local
```

### 2. Remove Standalone Docker Images and Containers

If you used the standalone `docker build` / `docker run` commands:

```bash
# Remove test container if running
docker rm -f user-provisioner-service 2>/dev/null || true

# Remove built image
docker rmi user-provisioner 2>/dev/null || true
```

### 3. Clean Host Test Accounts (If Run Directly on Linux VM / Host)

If you executed live provisioning directly on your Linux host with `sudo`:

```bash
# Run the automated rollback script
sudo ./cleanup_users.sh --manifest users_manifest.csv
```

### 4. Verify Clean State

Confirm that no leftover Docker resources or provisioned accounts remain:

```bash
# Verify no leftover test containers exist
docker ps -a --filter "name=user-provisioner"

# Verify no leftover test images exist
docker images "user-provisioner"

# Verify test accounts are removed from host
id alice 2>/dev/null || echo "User alice cleanly removed"
```
