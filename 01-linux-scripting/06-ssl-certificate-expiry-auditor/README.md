# Mini-Project 06: SSL/TLS Certificate Expiry Auditor

> **Domain**: 01. Linux Scripting  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Linux VM / OrbStack / Docker / macOS)  

---

## 🎯 Overview & Context

In Site Reliability Engineering (SRE) and Production Infrastructure, **SSL/TLS certificate expirations are among the most preventable yet catastrophic causes of global service outages**. When an HTTPS certificate expires, modern browsers and HTTP clients immediately terminate connections with severe security warnings (`ERR_CERT_DATE_INVALID` or `SSL_ERROR_EXPIRED_CERTIFICATE`), breaking web traffic, APIs, and mobile applications.

### Real-World Outages Caused by Expired Certificates

- **Spotify (2020)**: An expired TLS certificate took down Spotify's music streaming and podcast platform for over an hour.
- **Microsoft Teams (2020)**: An internal authentication certificate expired, locking millions of remote workers out of Teams worldwide.
- **Ericsson / O2 UK (2018)**: An expired software management certificate grounded 32 million smartphone connections across the UK and Japan for over 24 hours.
- **GitHub (2018)**: A key intermediate certificate expired, causing webhook and API delivery interruptions across hundreds of thousands of developer repositories.

### What This Mini-Project Implements

This project delivers a **production-ready, concurrent SSL/TLS certificate auditing engine** implemented in both Python 3 (standard library, zero third-party dependencies) and pure POSIX/Bash (using native `openssl` utilities).

Key capabilities:

1. **High-Performance Concurrent Scanning**: Asynchronously probes dozens of endpoints in parallel using thread pools.
2. **Deep X.509 Metadata Extraction**: Performs non-blocking TLS handshakes, extracts Subject Common Name (CN), Subject Alternative Names (SANs), Issuer Organization, Serial Number, Signature Algorithm, TLS Protocol version (TLS 1.2 / TLS 1.3), and Cipher Suite.
3. **Smart Expiration & Threshold Evaluation**: Computes precise remaining lifespan down to the hour and classifies endpoints into `OK`, `WARNING`, `CRITICAL`, `EXPIRED`, or `ERROR` states.
4. **Multi-Format Reporting**: Renders colorized ANSI CLI tables, machine-readable JSON for automation pipelines, and OpenMetrics / Prometheus exposition text for Grafana dashboards.
5. **Self-Contained Mock TLS Environment**: Includes a Docker Compose setup with Nginx serving 3 distinct certificate lifespans (valid 90 days, expiring in 10 days, and expired) to test edge cases safely offline.
6. **SRE-Standard Exit Codes**: Emits deterministic process exit codes (`0`, `1`, `2`, `3`) for integration into CI/CD quality gates and cron alert loops.
7. **Webhook Notifications**: Dispatches automated JSON alert payloads to Slack, Discord, Mattermost, or custom incident management webhooks.

---

## 🧠 TLS/SSL Cryptography & Network Deep-Dive

### 1. X.509 Certificate Chain of Trust

Public Key Infrastructure (PKI) relies on a hierarchical trust model defined by standard **ITU-T X.509**:

```text
  +-------------------------------------------------------------+
  |              Root Certificate Authority (Root CA)           |
  |  Self-signed, trusted root pre-installed in OS trust store  |
  +-------------------------------------------------------------+
                                 | (Signs intermediate key)
                                 v
  +-------------------------------------------------------------+
  |             Intermediate Certificate Authority              |
  |  Issued by Root CA to isolate root private key from risks   |
  +-------------------------------------------------------------+
                                 | (Signs domain leaf key)
                                 v
  +-------------------------------------------------------------+
  |               Leaf (End-Entity) Certificate                 |
  |  Bound to domain (e.g., example.com) and public key         |
  +-------------------------------------------------------------+
```

- **Root CA**: Stored locally in `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu), `/etc/pki/tls/certs/ca-bundle.crt` (RHEL/CentOS), or the macOS Keychain.
- **Leaf Certificate**: Contains the server's public key, the valid dates (`notBefore` and `notAfter`), and domain names in the **Subject Alternative Name (SAN)** extension.

---

### 2. The TLS 1.3 Handshake Protocol

When `cert_auditor.py` connects to an endpoint on port 443, the following network exchange occurs:

```text
Client (cert_auditor)                                Server (Nginx / API)
         |                                                   |
         | -------- 1. ClientHello (SNI: example.com) -----> |
         |                                                   |
         | <------- 2. ServerHello (Selected Cipher) ------- |
         | <------- 3. EncryptedExtensions ----------------- |
         | <------- 4. Certificate (X.509 Chain) ----------- |
         | <------- 5. CertificateVerify ------------------- |
         | <------- 6. Finished ---------------------------- |
         |                                                   |
         | -------- 7. Finished ---------------------------> |
         |                                                   |
[Extracts notAfter, SANs, Issuer]                 [Handshake Completed]
```

#### Why Server Name Indication (SNI) is Essential

In modern cloud environments, a single IP address often hosts hundreds of different HTTPS domains on Kubernetes ingress controllers, AWS ALBs, or Cloudflare edge nodes.

During Step 1 (`ClientHello`), the client transmits the **SNI extension** specifying the target hostname. If SNI is omitted, the server cannot know which certificate to return and responds with a default certificate or terminates the TLS handshake.

---

### 3. Expiration Calculation Arithmetic

The certificate's validity dates are encoded in ASN.1 GeneralizedTime or UTCTime format within the X.509 certificate:

```text
notBefore = Aug 25 02:58:20 2026 GMT
notAfter  = Nov 23 02:58:20 2026 GMT
```

To calculate the remaining lifespan in days:

$$\Delta t_{\text{seconds}} = \text{Timestamp}(\text{notAfter}) - \text{Timestamp}(\text{now}_{\text{UTC}})$$

$$\text{Days Remaining} = \frac{\Delta t_{\text{seconds}}}{86400}$$

#### Status Classification Matrix

| Status | Condition | Exit Code | Action Required |
| :--- | :--- | :--- | :--- |
| `[  OK   ]` | $\text{Days Remaining} > \text{Warning Threshold}$ (default: $> 30\text{d}$) | `0` | None. Certificate is healthy. |
| `[ WARN  ]` | $\text{Critical} < \text{Days Remaining} \le \text{Warning}$ ($7\text{d} < d \le 30\text{d}$) | `1` | Trigger renewal ticket / check ACME bot. |
| `[ CRIT  ]` | $0 < \text{Days Remaining} \le \text{Critical}$ ($0\text{d} < d \le 7\text{d}$) | `2` | Urgent page on-call SRE. Imminent outage. |
| `[EXPIRED]` | $\text{Days Remaining} \le 0$ | `2` | Outage active! Immediate emergency rotation. |
| `[ ERROR ]` | Connection timeout, DNS failure, or port closed | `3` | Check DNS record, firewall, or endpoint health. |

---

## 📂 Project Structure

```text
01-linux-scripting/06-ssl-certificate-expiry-auditor/
├── cert_auditor.py              # Production-grade Python auditor (zero-dependency, JSON, Prometheus)
├── cert_auditor.sh              # POSIX / Bash auditor companion script using openssl CLI
├── targets.txt                  # Sample target manifest with mixed mock and reference endpoints
├── test_cert_auditor.sh         # Automated test suite (17 assertions, 9 test suites)
├── Dockerfile                   # Isolated Alpine Python container for auditing
├── docker-compose.yml           # Root orchestration (auditor + mock TLS environment)
├── .markdownlint.json           # Linter configuration (MD013/MD033 disabled)
├── README.md                    # Beginner-friendly documentation and cleanup guide
└── mock_tls_environment/
    ├── generate_certs.sh        # Generates Root CA and 3 certificates (valid, expiring, expired)
    ├── nginx.conf               # Nginx server configuration hosting ports 8443, 8444, 8445
    ├── entrypoint.sh            # Container startup script ensuring cert availability
    ├── Dockerfile               # Alpine Nginx image bundling mock certificates
    └── docker-compose.yml       # Standalone compose file for mock TLS server
```

---

## 🚀 Quickstart & Hands-On Usage

### Step 1: Start the Local Mock TLS Environment

Start the multi-port Nginx mock environment using Docker Compose:

```bash
cd mock_tls_environment
docker compose up -d --build
cd ..
```

Verify that the 3 mock endpoints are listening:

- Port `8443`: `valid.local` (Valid for 90 days)
- Port `8444`: `expiring.local` (Expiring soon, 10 days left)
- Port `8445`: `expired.local` (Expired certificate)

Test with `curl`:

```bash
curl -k https://localhost:8443
curl -k https://localhost:8444
curl -k https://localhost:8445
```

---

### Step 2: Run the Python Auditor (`cert_auditor.py`)

Make the auditor executable:

```bash
chmod +x cert_auditor.py cert_auditor.sh test_cert_auditor.sh
```

#### 1. Audit Mock Endpoints (Table Format)

```bash
./cert_auditor.py -k -t localhost:8443 -t localhost:8444 -t localhost:8445
```

Sample output:

```text
========================================================================================================
                               SSL/TLS CERTIFICATE EXPIRY AUDIT REPORT                                  
========================================================================================================
Audit Time : 2026-08-25 03:01:15 UTC
Thresholds : Warning <= 30 days | Critical <= 7 days

STATUS     TARGET ENDPOINT             ISSUER                VALID UNTIL (UTC)    DAYS LEFT   PROTOCOL      
--------------------------------------------------------------------------------------------------------
[  OK   ]  localhost:8443              DevOps SRE            2026-11-23           90.0 d      TLSv1.3       
[ WARN  ]  localhost:8444              DevOps SRE            2026-09-04           10.0 d      TLSv1.3       
[EXPIRED]  localhost:8445              DevOps SRE            2022-01-15           -1683.1 d   TLSv1.3       
--------------------------------------------------------------------------------------------------------

SUMMARY STATISTICS:
  Total Audited : 3
  ✔ Healthy (OK)   : 1
  ▲ Expiring Soon : 1
  ✖ Critical/Exp  : 1 (Critical: 0, Expired: 1)
  ⚠ Errors/Unreach: 0
  Execution Time: 0.02s
```

#### 2. Audit from Targets File (`targets.txt`)

```bash
./cert_auditor.py -k -f targets.txt
```

#### 3. Export Machine-Readable JSON

```bash
./cert_auditor.py -k -f targets.txt --json
```

Pipe directly to `jq` to extract expiring domains:

```bash
./cert_auditor.py -k -f targets.txt --json --no-fail | jq '.results[] | select(.status != "OK") | {target, status, days_remaining}'
```

#### 4. Export Prometheus / OpenMetrics Text Format

```bash
./cert_auditor.py -k -f targets.txt --prometheus --no-fail
```

Sample Prometheus metrics output:

```text
# HELP ssl_cert_days_until_expiry Number of days remaining before SSL/TLS certificate expires
# TYPE ssl_cert_days_until_expiry gauge
ssl_cert_days_until_expiry{target="localhost:8443",host="localhost",port="8443",cn="valid.local",issuer="DevOps SRE",status="OK"} 90.0
ssl_cert_days_until_expiry{target="localhost:8444",host="localhost",port="8444",cn="expiring.local",issuer="DevOps SRE",status="WARNING"} 10.0
ssl_cert_days_until_expiry{target="localhost:8445",host="localhost",port="8445",cn="expired.local",issuer="DevOps SRE",status="EXPIRED"} -1683.1

# HELP ssl_cert_valid Binary flag indicating whether the certificate is valid and unexpired (1=valid, 0=invalid/expired/error)
# TYPE ssl_cert_valid gauge
ssl_cert_valid{target="localhost:8443",host="localhost",port="8443"} 1
ssl_cert_valid{target="localhost:8444",host="localhost",port="8444"} 1
ssl_cert_valid{target="localhost:8445",host="localhost",port="8445"} 0

# HELP ssl_audit_targets_total Total number of endpoints scanned in this audit batch
# TYPE ssl_audit_targets_total gauge
ssl_audit_targets_total 3
```

#### 5. Custom Warning & Critical Thresholds

Customize thresholds for environments requiring longer rotation lead times (e.g. 60 days warning, 15 days critical):

```bash
./cert_auditor.py -k -t localhost:8443 --warning-days 100 --critical-days 15
```

---

### Step 3: Run the POSIX/Bash Companion Auditor (`cert_auditor.sh`)

In minimal Linux environments, jump boxes, or embedded appliances without Python 3, run the native Bash auditor:

```bash
./cert_auditor.sh -t localhost:8443 -t localhost:8444 -t localhost:8445
```

JSON summary mode in Bash:

```bash
./cert_auditor.sh -f targets.txt --json
```

---

### Step 4: Run with Docker Compose (Containerized Auditor)

Run the entire audit pipeline inside Docker with one command:

```bash
docker compose up --build --abort-on-container-exit
```

---

## 📊 SRE Observability & Prometheus Monitoring Integration

### Prometheus Scrape Configuration

To integrate the auditor into your existing Prometheus server, run the auditor via cron or an exporter script that writes to the Prometheus Node Exporter Textfile Collector (`/var/lib/node_exporter/textfile_collector/ssl_certs.prom`):

```bash
# Periodic cron task generating metrics
*/15 * * * * /opt/cert_auditor/cert_auditor.py -f /opt/cert_auditor/targets.txt -p --no-fail > /var/lib/node_exporter/textfile_collector/ssl_certs.prom
```

Or configure Prometheus blackbox scraping in `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'ssl_certificate_auditor'
    static_configs:
      - targets: ['localhost:9100'] # Node Exporter Textfile Collector
```

### Prometheus Alertmanager Rules

Add the following alerting rules to `alerts.yml`:

```yaml
groups:
  - name: ssl_certificate_alerts
    rules:
      # Alert when a certificate has 30 or fewer days remaining
      - alert: SSLCertificateExpiringSoon
        expr: ssl_cert_days_until_expiry < 30 and ssl_cert_days_until_expiry > 7
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "SSL Certificate for {{ $labels.target }} is expiring soon"
          description: "Certificate expires in {{ $value }} days (Issuer: {{ $labels.issuer }})."

      # Critical alert when a certificate has 7 or fewer days remaining or is expired
      - alert: SSLCertificateCriticalOrExpired
        expr: ssl_cert_days_until_expiry <= 7
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "CRITICAL: SSL Certificate for {{ $labels.target }} requires immediate renewal"
          description: "Only {{ $value }} days remaining before complete TLS outage."

      # Alert when TLS target is completely unreachable or handshake failed
      - alert: SSLCertificateAuditFailure
        expr: ssl_cert_valid == 0
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "SSL/TLS handshake failed for {{ $labels.target }}"
          description: "Endpoint returned invalid certificate or connection error."
```

---

## 🔄 CI/CD Pipeline & Cron Automation

### Automated Quality Gate in GitHub Actions

Integrate `cert_auditor.py` into your deployment pipeline to verify staging and production endpoints before and after releases:

```yaml
name: "SSL/TLS Certificate Expiry Audit"

on:
  schedule:
    - cron: "0 8 * * *" # Daily at 08:00 UTC
  workflow_dispatch:

jobs:
  audit-certificates:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Run SSL Certificate Audit
        run: |
          python3 01-linux-scripting/06-ssl-certificate-expiry-auditor/cert_auditor.py \
            -t "api.mycompany.com:443" \
            -t "auth.mycompany.com:443" \
            --warning-days 30 \
            --critical-days 7
```

---

## 🧪 Automated Testing Suite

The project includes an automated end-to-end test suite (`test_cert_auditor.sh`) covering 17 test assertions across 9 distinct test suites:

```bash
./test_cert_auditor.sh
```

### Test Suite Coverage

1. **CLI Flags & Help Handling**: Tests `--help`, argument omission, missing file paths, and exit code 3.
2. **Network Error & Unreachable Host Handling**: Validates proper exception handling on closed ports and unresolvable DNS domains.
3. **TLS Status & Expiry Logic**: Asserts that `localhost:8443` is classified as `OK` (exit 0), `localhost:8444` as `WARNING` (exit 1), and `localhost:8445` as `EXPIRED` (exit 2).
4. **Batch Scanning**: Tests multi-target reading from `targets.txt`.
5. **Prometheus Metrics**: Validates OpenMetrics schema compliance.
6. **Output File Isolation**: Verifies report writing within the project boundary.
7. **Custom Thresholds**: Asserts that `--warning-days 100` correctly shifts a 90-day certificate into warning status.
8. **`--no-fail` Flag**: Verifies exit code override.
9. **Bash Script Parity**: Confirms that `cert_auditor.sh` yields identical status results to `cert_auditor.py`.

---

## 🧹 Teardown & Resource Cleanup

To ensure a clean environment with zero leftover Docker containers, networks, images, volumes, or temporary certificate artifacts, execute the following teardown commands:

### 1. Stop and Remove All Docker Containers, Images, and Networks

```bash
# Stop and remove the mock TLS server container, image, and network
docker compose -f mock_tls_environment/docker-compose.yml down -v --rmi all

# Stop and remove root compose auditor resources (if used)
docker compose down -v --rmi all
```

### 2. Clean Generated Mock Certificates & Local Test Files

```bash
# Clean generated certificate files inside mock_tls_environment
./mock_tls_environment/generate_certs.sh --clean

# Remove any temporary test files
rm -f .test_audit_output.json .test_prom.txt
rm -rf .tmp_decode mock_tls_environment/certs
```

### 3. Verify Clean State

```bash
# Confirm no lingering containers
docker ps -a | grep -E "mock_tls_server|ssl_cert_auditor" || echo "✔ No lingering containers found"

# Confirm no lingering images
docker images | grep -E "mock-tls-server|ssl-cert-auditor" || echo "✔ No lingering images found"
```

---

## 📚 Key Takeaways & Best Practices

1. **Automate Certificate Issuance**: Use ACME clients like `certbot` or Kubernetes `cert-manager` with Let's Encrypt or HashiCorp Vault.
2. **Dual-Layer Observability**: Combine **white-box monitoring** (internal certificate renewal daemons) with **black-box monitoring** (external network auditors like `cert_auditor.py` checking the actual live TLS port).
3. **Set Alerting Windows Early**: Alert at **30 days remaining** for routine renewal and escalate to **page on-call at 7 days remaining**.
4. **Monitor Intermediate Certificates**: Outages often occur when intermediate CAs expire even if the leaf certificate is valid. Always audit the entire presented chain.
