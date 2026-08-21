# Mini-Project 05: Automated Backup with S3 Upload

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Docker / MinIO S3 / macOS)  

---

## 🎯 Overview & Context

In Site Reliability Engineering (SRE), an untested backup is not a backup—it is merely a wish. Catastrophic data loss occurs due to ransomware, accidental `DROP TABLE` executions, disk failures, or compromised cloud credentials.

Industry standard disaster recovery adheres to the **3-2-1 Backup Rule**:

- **3** total copies of your data.
- **2** different storage media formats (e.g., local NVMe disk and object storage).
- **1** offsite copy located in a separate cloud failure domain or geographic region.

This mini-project teaches how to engineer an **end-to-end automated backup and disaster recovery pipeline** in Bash and Python that:

1. Generates consistent, non-blocking **atomic database snapshots** from an active SQLite database.
2. Bundles static filesystem uploads and metadata into compressed tar archives.
3. Applies **GPG / OpenSSL symmetric AES-256 encryption** to protect sensitive data at rest.
4. Computes cryptographic **SHA-256 manifests** to detect bit-rot and unauthorized tampering.
5. Uploads encrypted artifacts to **S3 Object Storage** (supporting local MinIO, AWS S3, and offline mock storage).
6. Provides an automated **Disaster Recovery verification engine** (`verify_restore.sh`) that tests archive decryption, extraction, and database table row-count validation.

---

## 🧠 Backup Engineering & Security Deep-Dive

### 1. Atomic Database Backups vs. "Dirty Reads"

Directly copying an active database file (`cp app.db backup.db`) while transactions are writing leads to corrupt, torn pages:

```text
Process A writes page 4 ---> [ Database File ] <--- cp reads page 4 (Half-written, CORRUPT!)
```

To prevent corruption, modern database engines provide safe snapshot APIs. SQLite provides the **`.backup` online backup API** (or `VACUUM INTO`), which locks WAL (Write-Ahead Log) pages cleanly and guarantees transactional consistency:

```bash
sqlite3 "$DB_PATH" ".backup '${STAGING_DIR}/database.sqlite'"
```

---

### 2. Symmetric Encryption (AES-256) & Zero-Knowledge Storage

Unencrypted backups stored in object storage are severe compliance risks. We apply **AES-256 symmetric encryption** using GPG or OpenSSL:

```text
[ Raw Archive: .tar.gz ]
          |
          v  (Key derived via PBKDF2 with salt)
    [ AES-256 Cipher ]
          |
          v
[ Encrypted Blob: .tar.gz.enc ]
```

```bash
gpg --batch --yes --passphrase "$PASS" --symmetric --cipher-algo AES256 -o "$ENC" "$RAW"
```

---

### 3. Cryptographic Tamper Detection (SHA-256)

Before attempting decryption, `verify_restore.sh` computes the SHA-256 hash of the received `.enc` file and compares it to the `.sha256` manifest. If a single bit was modified or corrupted in transit, the restore process immediately aborts:

$$\text{SHA-256}(\text{EncryptedFile}) \stackrel{?}{=} \text{ManifestHash}$$

---

## 📂 Project Structure

```text
05-automated-backup-s3-upload/
├── backup_s3.sh           # Main backup, compression, encryption, and S3 upload script
├── verify_restore.sh      # Disaster recovery decryption and SQLite validation script
├── mock_db_seeder.py      # Seeds realistic SQLite database tables and static assets
├── test_backup_restore.sh # Automated end-to-end test suite (13 test points)
├── Dockerfile             # Ubuntu container with SQLite3, GPG, OpenSSL, AWS CLI, and jq
├── docker-compose.yml     # Multi-container setup with local MinIO S3 server
└── README.md              # Educational documentation and cleanup instructions
```

---

## 🚀 Quickstart & Usage

### 1. Seed Sample Production Database & Assets

Make scripts executable and generate a sample database with 50 users and 120 orders:

```bash
chmod +x mock_db_seeder.py backup_s3.sh verify_restore.sh test_backup_restore.sh

python3 mock_db_seeder.py --users 50 --orders 120
```

---

### 2. Execute Backup & Encryption Pipeline

Run `backup_s3.sh` to generate an atomic dump, encrypt it with AES-256, and upload it to the local mock S3 storage:

```bash
./backup_s3.sh --json --pretty
```

**Example JSON execution output:**

```json
{
  "timestamp": "2026-08-21T11:25:00Z",
  "status": "SUCCESS",
  "backup_name": "backup_2026-08-21T11-25-00Z",
  "source_db": "./data/app_production.db",
  "source_data_dir": "./data/uploads",
  "encryption": {
    "tool": "GPG (AES-256)",
    "cipher": "AES-256"
  },
  "artifacts": {
    "encrypted_archive": "backup_2026-08-21T11-25-00Z.tar.gz.enc",
    "sha256_manifest": "backup_2026-08-21T11-25-00Z.tar.gz.enc.sha256",
    "raw_size_bytes": 14592,
    "encrypted_size_bytes": 14640,
    "post_encryption_sha256": "4b68e987c98b67f1b2123d..."
  },
  "destination": "mock://./mock_s3_bucket/backup_2026-08-21T11-25-00Z.tar.gz.enc"
}
```

---

### 3. Verify Restoration & Disaster Recovery

Execute `verify_restore.sh` to download the latest backup, verify SHA-256 integrity, decrypt, and validate database tables:

```bash
./verify_restore.sh --json --pretty
```

**Example JSON restoration report:**

```json
{
  "timestamp": "2026-08-21T11:25:05Z",
  "status": "VERIFIED_SUCCESS",
  "backup_artifact": "backup_2026-08-21T11-25-00Z.tar.gz.enc",
  "integrity_check": {
    "sha256_verified": true,
    "sha256_hash": "4b68e987c98b67f1b2123d...",
    "decryption_status": "SUCCESS",
    "sqlite_integrity": "ok"
  },
  "restored_data": {
    "destination": "./restored_data",
    "total_files_restored": 5,
    "database": {
      "table_users_count": 50,
      "table_orders_count": 120
    }
  }
}
```

---

### 4. CLI Options Reference

#### `backup_s3.sh` Options

| Option | Description | Default |
| :--- | :--- | :---: |
| `--db-path <path>` | Path to SQLite database | `./data/app_production.db` |
| `--data-dir <path>` | Directory of static assets | `./data/uploads` |
| `--s3-bucket <bucket>` | S3 bucket name | `production-backups` |
| `--s3-endpoint <url>` | Optional MinIO/LocalStack URL | `""` |
| `--mock-s3-dir <path>` | Local directory simulating S3 bucket | `./mock_s3_bucket` |
| `--passphrase <pass>` | Encryption passphrase | `DevOpsSecretPassphrase2026!` |
| `--json` | Emit report in JSON format | `false` |
| `--pretty` | Format JSON with 2-space indentation | `false` |

#### `verify_restore.sh` Options

| Option | Description | Default |
| :--- | :--- | :---: |
| `--backup-key <key>` | Specific backup artifact to restore | Latest in bucket |
| `--restore-dir <path>` | Destination directory for restored files | `./restored_data` |
| `--passphrase <pass>` | Decryption passphrase | `DevOpsSecretPassphrase2026!` |
| `--mock-s3-dir <path>` | Local directory simulating S3 bucket | `./mock_s3_bucket` |
| `--json` | Emit report in JSON format | `false` |

---

## 🧪 Disaster Recovery Failure Scenarios

### Scenario A: Total Database Deletion & Recovery

```bash
# 1. Take fresh backup
./backup_s3.sh

# 2. Simulate catastrophic incident: delete live database
rm -rf ./data/app_production.db

# 3. Execute Disaster Recovery
./verify_restore.sh --restore-dir ./data_recovered

# 4. Verify database recovered 100% of records
sqlite3 ./data_recovered/database.sqlite "SELECT count(*) FROM users;"
# Expected: 50
```

---

### Scenario B: Tampered Backup / Corrupted Checksum Rejection

```bash
# 1. Modify the SHA-256 manifest to simulate tampering
echo "0000000000000000000000000000000000000000000000000000000000000000" > ./mock_s3_bucket/*.sha256

# 2. Attempt restoration
./verify_restore.sh
# Expected: Aborts immediately with error:
# [ERROR] SHA-256 CHECKSUM MISMATCH! Tampering or bit-rot detected.
```

---

## 🤖 Running Automated Tests

An automated test suite (`test_backup_restore.sh`) validates CLI arguments, seeding, backup generation, AES-256 encryption, checksum manifests, tamper detection, and SQLite table recovery:

```bash
./test_backup_restore.sh
```

**Expected output:**

```text
======================================================
  Automated Backup & Disaster Recovery - Tests       
======================================================

Suite 1: CLI Arguments & Help Handling
  [PASS] backup_s3.sh --help displays usage and exits 0
  [PASS] verify_restore.sh --help displays usage and exits 0
  [PASS] Missing source database triggers exit code 2 (ERROR)

Suite 2: Database & Asset Seeding
  [PASS] mock_db_seeder.py successfully seeded database and uploads

Suite 3: Backup Generation, AES-256 Encryption & Checksums
  [PASS] backup_s3.sh executed backup pipeline with exit code 0
  [PASS] Backup execution report conforms to valid JSON schema
  [PASS] Encrypted backup archive (.enc) uploaded to object storage
  [PASS] SHA-256 manifest file generated and uploaded

Suite 4: Tamper Detection & Security Check
  [PASS] Tampered checksum detected and restore rejected (Exit 2)

Suite 5: Disaster Recovery & SQLite Table Restoration
  [PASS] verify_restore.sh executed decryption and extraction with exit code 0
  [PASS] Restore verification report conforms to valid JSON schema
  [PASS] Restored SQLite tables contain 100% of original records (50 users, 120 orders)
  [PASS] Static filesystem assets restored cleanly

======================================================
  Test Results: 13/13 Passed
  Status: ALL TESTS PASSED
======================================================
```

---

## 🐳 Running with Docker & Local MinIO S3

Run a full local S3 object storage server (MinIO) and backup worker using Docker Compose:

```bash
# 1. Start MinIO S3 and execute test suite inside container
docker compose up --build

# 2. Access MinIO Web Console (Optional)
# Open browser at: http://localhost:9001
# Username: minioadmin | Password: minioadmin
```

---

## 🧹 Cleanup & Teardown

To ensure your environment is clean and free of leftover files or Docker resources:

### 1. Remove Local Artifacts & Test Databases

```bash
# Remove seeded data, mock S3 bucket, restored data, and temporary files
rm -rf data restored_data data_recovered mock_s3_bucket /tmp/backup_* /tmp/restore_*
```

### 2. Remove Docker & MinIO Containers, Volumes, and Images

```bash
# Stop and remove MinIO container, backup worker, networks, and volumes
docker compose down --volumes --rmi local
```

### 3. Verify Clean State

Confirm that no lingering containers, images, or files remain:

```bash
# Verify no test directories remain
ls -ld data mock_s3_bucket restored_data 2>/dev/null || echo "Local directories clean"

# Verify MinIO / backup containers are removed
docker ps -a --filter "name=minio-s3-server" --filter "name=backup-s3-worker"

# Verify port 9000 is released
lsof -i :9000 2>/dev/null || echo "Port 9000 is free"
```
