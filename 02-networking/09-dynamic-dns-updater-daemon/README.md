# Mini-Project 09: Dynamic DNS (DDNS) Updater Daemon

> **Domain**: 02. Networking & Traffic Routing  
> **Level**: Beginner to Intermediate  
> **Infrastructure**: Local (Docker Compose / OrbStack) or Cloud (Cloudflare Free API / AWS Route 53)  

---

## 🎯 Overview & Context

In edge computing, branch office infrastructure, remote home labs, and hybrid cloud environments, Internet Service Providers (ISPs) assign dynamic public WAN IPv4 and IPv6 addresses that rotate periodically (e.g., during router reboots, ISP lease renewals, or network maintenance).

If inbound services (such as WireGuard VPN tunnels, reverse proxy gateways, SSH bastions, or webhook receivers) rely on fixed fully qualified domain names (FQDNs like `home.example.com` or `vpn.example.com`), an unannounced WAN IP rotation breaks all inbound connectivity until the DNS `A` or `AAAA` record is updated.

A production-grade **Dynamic DNS (DDNS) Updater Daemon** continuously monitors the external WAN IP, detects transitions, and updates authoritative cloud DNS providers (such as Cloudflare or AWS Route 53) automatically.

```mermaid
flowchart TD
    subgraph LocalEdge ["Local Edge / Homelab / Branch Network"]
        Daemon["⚙️ DDNS Updater Daemon\n(ddns_daemon.py)"]
        Cache[("💾 Local State Cache\n(/data/ddns_cache.json)")]
        
        Daemon <-->|Read / Write Cached IP| Cache
        Daemon -->|1. Periodic IP Discovery Query| Discovery["Multi-Source WAN IP Discovery\n(/ip, api.ipify.org, icanhazip.com)"]
    end
    
    Discovery -->|2. Returns Public WAN IP: 198.51.100.42| Daemon
    
    subgraph DecisionEngine ["Change Detection & Cache Engine"]
        Daemon --> Eval{"Discovered IP == Cached IP?"}
        Eval -->|YES: No Change| Sleep["Skip Cloud API Call\n(Save API Quota & Prevent Rate Limits)"]
        Eval -->|NO: IP Changed!| Sync["Trigger Resilient DNS Sync"]
    end
    
    subgraph CloudDNS ["Cloud Authoritative DNS Provider (Cloudflare / Route 53)"]
        Sync -->|3. PUT /client/v4/zones/.../dns_records\n(Bearer Auth + Exponential Backoff)| CloudAPI["Cloudflare v4 REST API\n(Updates DNS A-Record TTL: 120s)"]
        CloudAPI -->|4. Propagates Worldwide| AuthoritativeDNS[("Authoritative Name Servers\n(home.example.com -> 198.51.100.42)")]
    end
```

### What This Project Delivers

1. **Multi-Source WAN IP Discovery with Fallback**: Queries multiple independent HTTP IP discovery endpoints to prevent a single point of failure (SPOF).
2. **Local State Caching & Quota Protection**: Maintains `/data/ddns_cache.json` so that regular polling cycles never make redundant cloud API calls when the WAN IP is stable.
3. **Cloudflare v4 & AWS Route 53 API Compatibility**: Implements standard Bearer-authenticated REST updates matching real Cloudflare v4 and Route 53 schemas.
4. **SRE Fault Resilience & Exponential Backoff**: Implements exponential backoff with random jitter on HTTP 429 (Rate Limited) or HTTP 5xx (Cloud Outages), preventing API stampedes.
5. **Mock Cloud DNS Server & WAN IP Simulator**: Standalone local mock server (`mock_dns_api.py`) for offline testing, fault injection, and dynamic IP rotation.
6. **Interactive Web Dashboard**: Sleek dark-mode dashboard on port 8080 visualizing real-time WAN IP state, active DNS records, sync indicators, and one-click simulation buttons.
7. **Automated Test Suite (`test_ddns_daemon.sh`)**: 10 automated assertions validating health, initial sync, cache deduplication, dynamic IP transitions (< 5s), multi-step transitions, and fault recovery.

---

## 🧠 Deep-Dive Architecture & DDNS Protocols

### 1. Multi-Source IP Discovery & Validation

Relying on a single IP check provider (e.g. `api.ipify.org`) introduces risk: if that third-party service experiences downtime, the DDNS daemon fails.

Our daemon implements ordered fallback queries:

```python
IP_DISCOVERY_URLS = [
    "http://mock-dns-server:8080/ip",
    "https://api.ipify.org",
    "https://icanhazip.com",
    "https://checkip.amazonaws.com"
]
```

Before accepting any discovered IP, the daemon parses and validates the string with standard `ipaddress.IPv4Address` checks to ensure corrupt HTML or error pages are never submitted as DNS records.

---

### 2. Local State Caching vs Redundant Cloud API Calls

Cloud DNS providers enforce strict API rate limits (e.g., Cloudflare allows 1,200 requests per 5 minutes). Polling the cloud API every 10 seconds would quickly exhaust rate quotas and cause unnecessary DNS zone serial increments.

The daemon persists state to `/data/ddns_cache.json`:

```json
{
  "last_ip": "198.51.100.42",
  "updated_at": "2026-08-25T10:15:00Z"
}
```

- **If Discovered IP == Cached IP**: Polling skips the cloud API entirely and increments `redundant_calls_avoided`.
- **If Discovered IP != Cached IP**: The daemon initiates the DNS update transaction and writes the new IP to cache only upon verified API success.

---

### 3. Cloudflare v4 REST API Architecture

When an IP transition occurs, the daemon issues a `PUT` request to update the target `A` record:

```http
PUT /client/v4/zones/zone_1234567890abcdef/dns_records/rec_home_01 HTTP/1.1
Host: api.cloudflare.com
Authorization: Bearer <api_token>
Content-Type: application/json

{
  "type": "A",
  "name": "home.example.com",
  "content": "198.51.100.42",
  "ttl": 120,
  "proxied": false
}
```

- **`ttl: 120`**: A low Time-To-Live (120 seconds / 2 minutes) ensures that worldwide recursive resolvers purge stale cached IPs quickly when a dynamic WAN IP change occurs.
- **`proxied: false`**: Direct DNS resolution (ideal for VPN tunnels and SSH). If CDN proxying is desired, setting `proxied: true` routes HTTP traffic through Cloudflare's edge.

---

### 4. Exponential Backoff with Jitter

During transient network failures or cloud API rate limits (HTTP 429), naive daemons poll aggressively, exacerbating the outage. Our daemon calculates retry intervals using exponential backoff:

$$\text{Delay} = \text{base\_delay} \times 2^{\text{attempt}} + \text{jitter}$$

```text
Attempt 1: 1.0s + 0.2s jitter = 1.2s
Attempt 2: 2.0s + 0.4s jitter = 2.4s
Attempt 3: 4.0s + 0.3s jitter = 4.3s
Attempt 4: 8.0s + 0.5s jitter = 8.5s
```

---

## 📂 Project Structure

```text
02-networking/09-dynamic-dns-updater-daemon/
├── Dockerfile.mock             # Python image hosting Mock Cloud DNS API & Web Dashboard
├── Dockerfile.daemon           # Python image for the DDNS background daemon
├── docker-compose.yml          # Multi-container orchestration (mock-dns-server + ddns-daemon)
├── Makefile                    # Automation task runner (up, down, status, trigger-ip-change, test, clean)
├── test_ddns_daemon.sh         # 7-phase automated end-to-end test suite
├── .markdownlint.json          # Markdown linting rule overrides
├── README.md                   # Comprehensive educational guide
├── daemon/
│   └── ddns_daemon.py          # Core background daemon (cache, discovery, backoff, health endpoint)
├── mock_api/
│   └── mock_dns_api.py         # Mock Cloudflare v4 REST API & dynamic WAN IP discovery server
└── web/
    └── index.html              # Interactive dark-mode SRE dashboard and WAN simulator
```

---

## ⚙️ Configuration Walkthrough

### 1. Daemon Configuration ([daemon/ddns_daemon.py](file:///Users/fabian/Documents/CodeProjects/github.com/fabiankaraben/devops-sre-mini-projects/02-networking/09-dynamic-dns-updater-daemon/daemon/ddns_daemon.py))

Key environment variables:

- **`API_BASE_URL`**: Base URL of Cloudflare API (`http://mock-dns-server:8080` for testing, `https://api.cloudflare.com` for production).
- **`API_TOKEN`**: Cloudflare API Bearer token with `Zone:DNS:Edit` permissions.
- **`ZONE_ID`**: 32-character hexadecimal zone identifier.
- **`DOMAINS`**: Comma-separated list of hostnames to keep in sync (`home.example.com,vpn.example.com`).
- **`CHECK_INTERVAL`**: Polling frequency in seconds (default: `3.0s` for testing, `30.0s` for production).
- **`CACHE_FILE`**: Path to local state file (`/data/ddns_cache.json`).

---

## 🚀 Execution & Quick Start

### 1. Build and Start the Environment

Start the Mock Cloud DNS Server and DDNS Daemon:

```bash
make up
```

*Or using Docker Compose directly:*

```bash
docker compose up -d --build
```

---

### 2. Inspect Live Status & Metrics

View live WAN IP, DNS records, and daemon caching metrics:

```bash
make status
```

Example output:

```text
=== Mock Cloudflare DNS Status ===
  "current_wan_ip": "203.0.113.10",
  "name": "home.example.com",
  "content": "203.0.113.10",
  "name": "vpn.example.com",
  "content": "203.0.113.10",

=== DDNS Daemon Observability Metrics ===
  "status": "ACTIVE",
  "last_discovered_ip": "203.0.113.10",
  "last_synced_ip": "203.0.113.10",
  "redundant_calls_avoided": 12,
  "total_checks": 13
```

---

### 3. Simulate an ISP Dynamic WAN IP Change

Trigger a simulated public WAN IP transition:

```bash
make trigger-ip-change
```

The daemon detects the new IP within its polling interval and updates both `home.example.com` and `vpn.example.com` automatically.

---

### 4. Open the Interactive Visual Dashboard

Navigate to [http://localhost:8080](http://localhost:8080) in your browser:

- **WAN IP vs DNS IP**: Real-time side-by-side indicator of external WAN IP vs authoritative DNS record.
- **Sync Status**: Live status badge (`SYNCED ✓`, `SYNCING... ⏳`, `ERROR_RETRYING ❌`).
- **One-Click Simulator**: Rotate ISP WAN IP with a single click and observe real-time propagation in under 3 seconds.
- **Fault Injection Studio**: Toggle Cloudflare API 500/429 errors to inspect exponential backoff retry behavior.
- **Audit Timeline**: Live audit log of all DNS transactions and IP rotation events.

---

## 🧪 Comprehensive Testing & Validation

### 1. Run the Automated Test Suite

Execute the 7-phase automated verification suite:

```bash
make test
```

For verbose diagnostic output:

```bash
make test-verbose
```

#### Expected Test Output

```text
======================================================================
  🌐 Dynamic DNS (DDNS) Updater Daemon Automated Test Suite
======================================================================

Mock DNS API     : http://localhost:8080
Daemon Status    : http://localhost:8000

▶ 1. Mock DNS API & Daemon Health Checks
----------------------------------------------------------------------
  [ PASS ] Mock Cloudflare / Route53 API (:8080/health) healthy
  [ PASS ] DDNS Background Daemon (:8000/health) healthy

▶ 2. Initial DNS Record Sync on Daemon Startup
----------------------------------------------------------------------
  [ PASS ] Discovered initial WAN IP: 203.0.113.10

▶ 3. Redundant Polling & Cache Verification
----------------------------------------------------------------------
Observing daemon over 5 seconds while WAN IP is stable...
  [ PASS ] Local Cache Active: Avoided redundant API calls (2 -> 3)

▶ 4. Dynamic WAN IP Change Detection & Auto-Sync (< 5s)
----------------------------------------------------------------------
Rotating simulated ISP WAN IP to 198.51.100.42...
  [ PASS ] Dynamic IP Transition: home.example.com updated to 198.51.100.42 in < 4s

▶ 5. Consecutive Rapid Multi-IP Transitions
----------------------------------------------------------------------
Rotating WAN IP to 192.0.2.88...
  [ PASS ] Multi-Domain Sync to 192.0.2.88 (home & vpn verified)
Rotating WAN IP to 203.0.113.199...
  [ PASS ] Multi-Domain Sync to 203.0.113.199 (home & vpn verified)

▶ 6. Cloud API Fault Tolerance & Exponential Backoff Retries
----------------------------------------------------------------------
Simulating 2 consecutive Cloudflare API 500 errors...
Rotating WAN IP to 198.51.100.123 during outage...
  [ PASS ] Fault Resilience: Daemon retried with exponential backoff and updated to 198.51.100.123

▶ 7. Full Zone Record Integrity Verification
----------------------------------------------------------------------
  [ PASS ] Domain [home.example.com] accurately matches WAN IP (198.51.100.123)
  [ PASS ] Domain [vpn.example.com] accurately matches WAN IP (198.51.100.123)

======================================================================
                         TEST SUMMARY REPORT                          
======================================================================
  Total Tests Executed : 10
  Passed Tests         : 10
  Failed Tests         : 0
  Total Duration       : 19s

  🎉 ALL DYNAMIC DNS DAEMON CHECKS PASSED!
```

---

### 2. Manual Verification Commands

#### A. Query Current Discovered WAN IP

```bash
curl http://localhost:8080/ip
```

#### B. Query Live Cloudflare DNS Records

```bash
curl -s http://localhost:8080/client/v4/zones/zone_1234567890abcdef/dns_records | jq .result
```

#### C. Rotate WAN IP and Observe Propagation

```bash
curl -X POST http://localhost:8080/api/wan/simulate-ip-change \
  -H "Content-Type: application/json" \
  -d '{"ip": "198.51.100.77"}'
```

Inspect daemon sync in real time:

```bash
curl -s http://localhost:8000/status | jq .
```

---

## 🛠️ SRE Troubleshooting & Diagnostic Playbook

```text
+------------------------------------+---------------------------------------------------------------+
| Issue / Symptom                    | Root Cause & Remediation Steps                                |
+------------------------------------+---------------------------------------------------------------+
| Cloudflare API returns HTTP 403    | API Token lacks Zone.DNS edit permissions. Ensure the token  |
| Forbidden                          | has 'Zone - DNS - Edit' permissions for the target zone.      |
+------------------------------------+---------------------------------------------------------------+
| Record not updating after IP shift | Check local cache file permissions (/data/ddns_cache.json).  |
|                                    | Verify that IP discovery endpoint is returning a valid IPv4.  |
+------------------------------------+---------------------------------------------------------------+
| HTTP 429 Rate Limit Errors         | Polling interval is set too aggressively without caching.     |
|                                    | Increase CHECK_INTERVAL to >= 30s in production.              |
+------------------------------------+---------------------------------------------------------------+
| DNS propagation delay on clients   | Target record TTL is too high. Ensure TTL is set to 120s      |
|                                    | (or 'Auto' / 1 for Cloudflare proxied records).               |
+------------------------------------+---------------------------------------------------------------+
```

---

## 🧹 Teardown & Environment Cleanup

To ensure a clean environment for subsequent mini-projects and remove all Docker resources:

### 1. Complete Resource Teardown

Execute the `clean` target in the `Makefile`:

```bash
make clean
```

*Or using Docker Compose directly:*

```bash
docker compose down --rmi all --volumes --remove-orphans
```

### What This Command Removes

- **Containers**: Stops and deletes `ddns-mock-dns` and `ddns-daemon`.
- **Networks**: Removes the virtual bridge network `ddns-internal-net`.
- **Images**: Deletes locally built images (`09-dynamic-dns-updater-daemon-mock-dns-server`, `09-dynamic-dns-updater-daemon-ddns-daemon`).
- **Volumes**: Cleans up temporary Docker volumes and build artifacts.

### 2. Verify Environment Is Clean

Run these verification commands to ensure zero residual resources:

```bash
docker ps -a --filter "name=ddns-"
docker network ls --filter "name=ddns-internal-net"
docker images --filter "reference=*dynamic-dns-updater*"
```

All three commands should return empty lists, confirming your workstation is clean.
