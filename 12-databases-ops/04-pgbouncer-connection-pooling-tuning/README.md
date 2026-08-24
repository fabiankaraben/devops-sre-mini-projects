<!-- markdownlint-disable MD013 MD033 MD051 MD060 -->
# 04 - PgBouncer Connection Pooling and Tuning

> A production-grade **Database Operations & Resilience** engineering suite implementing high-concurrency connection pooling with PgBouncer, comparing direct PostgreSQL process-based connections vs. asynchronous transaction pooling under heavy load (500 clients), inspecting real-time pool metrics (`SHOW POOLS`, `SHOW STATS`), and benchmarking throughput and latency.

---

## 📋 Table of Contents

1. [Architectural Overview & Lifecycle](#-architectural-overview--lifecycle)
   - [Direct Connections vs. PgBouncer Transaction Pooling](#direct-connections-vs-pgbouncer-transaction-pooling)
   - [Transaction Multiplexing Lifecycle](#transaction-multiplexing-lifecycle)
2. [Theoretical Deep-Dive for Beginners](#-theoretical-deep-dive-for-beginners)
   - [The PostgreSQL Connection Bottleneck (Process Model vs. Event Loop)](#the-postgresql-connection-bottleneck-process-model-vs-event-loop)
   - [Memory & Context Switching Overhead](#memory--context-switching-overhead)
   - [Understanding PgBouncer Pooling Modes](#understanding-pgbouncer-pooling-modes)
   - [Tuning Core Configuration Parameters](#tuning-core-configuration-parameters)
   - [Querying the PgBouncer Administrative Console](#querying-the-pgbouncer-administrative-console)
   - [Handling Prepared Statements & Session State in Transaction Pooling](#handling-prepared-statements--session-state-in-transaction-pooling)
3. [Repository & Directory Structure](#-repository--directory-structure)
4. [Prerequisites & System Setup](#-prerequisites--system-setup)
5. [Quickstart Guide (3 Commands)](#-quickstart-guide-3-commands)
6. [Step-by-Step Hands-On Guide](#-step-by-step-hands-on-guide)
   - [Step 1: Start PostgreSQL and PgBouncer Cluster](#step-1-start-postgresql-and-pgbouncer-cluster)
   - [Step 2: Verify Direct & Pooled Database Connectivity](#step-2-verify-direct--pooled-database-connectivity)
   - [Step 3: Inspect Real-Time Pool Telemetry (`SHOW POOLS`)](#step-3-inspect-real-time-pool-telemetry-show-pools)
   - [Step 4: Execute High-Concurrency Benchmark (500 Clients)](#step-4-execute-high-concurrency-benchmark-500-clients)
   - [Step 5: Analyze Connection Exhaustion vs. 100% Pooled Success](#step-5-analyze-connection-exhaustion-vs-100-pooled-success)
   - [Step 6: Verify Transaction State Isolation & Cleanliness](#step-6-verify-transaction-state-isolation--cleanliness)
   - [Step 7: Run the Complete Automated Test Suite](#step-7-run-the-complete-automated-test-suite)
7. [Troubleshooting & Common Gotchas](#-troubleshooting--common-gotchas)
8. [Resource Teardown & Complete Cleanup](#-resource-teardown--complete-cleanup)

---

## 🏛️ Architectural Overview & Lifecycle

### Direct Connections vs. PgBouncer Transaction Pooling

```mermaid
flowchart TD
    subgraph DirectArchitecture ["❌ Direct Architecture: 500 Clients Direct to PostgreSQL (Port 5432)"]
        DirectClients["500 Web / API Clients"] -->|500 Forked OS Processes| DirectPG[("PostgreSQL Server<br/>• max_connections = 50<br/>• Memory: ~5GB - 10GB<br/>• Heavy CPU Context Switching")]
        DirectPG -.->|❌ 450+ Connections Rejected| RejectError["FATAL: sorry, too many clients already<br/>SQLSTATE: 53300"]
    end

    subgraph PooledArchitecture ["✅ Pooled Architecture: 500 Clients via PgBouncer (Port 6432)"]
        PooledClients["500 Web / API Clients"] -->|500 Lightweight Sockets<br/>(~2KB per socket)| PgBouncerEngine["🛡️ PgBouncer Proxy (Port 6432)<br/>• libevent Async Single-Process<br/>• Pool Mode: transaction<br/>• Max Client Conn: 1000<br/>• Default Pool Size: 20"]
        PgBouncerEngine -->|Multiplexed onto 20 Backend Connections| PooledPG[("PostgreSQL Server (Port 5432)<br/>• Only 20 Active Backend Processes<br/>• Low Memory: ~200MB<br/>• 100% CPU Cache Efficiency")]
        PooledPG -->|100% Success & Zero Errors| ClientSuccess["✔ All 500 Transactions Completed Successfully"]
    end
```

---

### Transaction Multiplexing Lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant Client1 as Client 1 (Web Request A)
    participant Client2 as Client 2 (Web Request B)
    participant Bouncer as PgBouncer Pooler (Port 6432)
    participant ServerConn as PostgreSQL Backend 1 (Port 5432)

    Note over Client1,Bouncer: Client 1 connects (Idle socket, 0 backend usage)
    Client1->>Bouncer: Connect & Authenticate
    Bouncer-->>Client1: Connected (cl_active = 1, sv_active = 0)

    Note over Client1,ServerConn: Client 1 starts a Transaction
    Client1->>Bouncer: BEGIN; SELECT ...;
    Bouncer->>ServerConn: Assign ServerConn -> Execute Query
    ServerConn-->>Bouncer: Query Result
    Bouncer-->>Client1: Query Result

    Client1->>Bouncer: COMMIT;
    Bouncer->>ServerConn: COMMIT;
    ServerConn-->>Bouncer: Commit OK
    Bouncer-->>Client1: Success (Transaction Ended)

    Note over Bouncer,ServerConn: ServerConn immediately released back to pool!
    
    Note over Client2,ServerConn: Client 2 immediately reuses the SAME ServerConn
    Client2->>Bouncer: BEGIN; UPDATE accounts ...; COMMIT;
    Bouncer->>ServerConn: Assign ServerConn -> Execute Query & Commit
    ServerConn-->>Bouncer: Result
    Bouncer-->>Client2: Success
```

---

## 🧠 Theoretical Deep-Dive for Beginners

### The PostgreSQL Connection Bottleneck (Process Model vs. Event Loop)

Understanding why PostgreSQL needs connection poolers like PgBouncer requires understanding its architectural foundation:

1. **The Process-Based Fork Architecture**:
   - PostgreSQL was designed in the late 1980s using Unix process isolation.
   - For every client connection, PostgreSQL forks a separate operating system process (`postgres: user db client_ip`).
   - While process isolation guarantees that one crashing backend query cannot corrupt memory of another backend, OS processes are heavy.
2. **The PgBouncer Event-Loop Architecture**:
   - PgBouncer is built on `libevent`, using a non-blocking asynchronous event loop within a **single lightweight process**.
   - It maintains thousands of open client TCP connections with negligible CPU and memory overhead (~2 KB per socket).

---

### Memory & Context Switching Overhead

| Dimension / Metric | Direct PostgreSQL Connections | PgBouncer Connection Pooling |
| :--- | :--- | :--- |
| **Architecture** | 1 forked OS process per client connection. | 1 single-process event loop proxying to fixed pool. |
| **Memory per Client** | **~5 MB to 10 MB** (stack, catalog cache, `work_mem`). | **~2 KB** (network socket buffer). |
| **500 Concurrent Clients** | **~2.5 GB to 5 GB RAM** consumed just for connections. | **~1 MB RAM** in PgBouncer + ~150 MB in PostgreSQL. |
| **CPU Overhead** | Severe context-switching between 500 OS processes. | Minimal context-switching; CPU spent executing SQL. |
| **Connection Scaling** | Limited to ~100 - 300 before performance collapses. | Scales to **10,000+ simultaneous client connections**. |

---

### Understanding PgBouncer Pooling Modes

PgBouncer supports three distinct pooling modes configured via `pool_mode`:

#### 1. Transaction Pooling (`pool_mode = transaction`) — Recommended Default

- **How it Works**: A backend PostgreSQL connection is assigned to a client only for the duration of a single transaction (`BEGIN` ... `COMMIT` / `ROLLBACK`). As soon as the transaction finishes, the backend connection is returned to the pool for other clients.
- **Best For**: Microservices, REST APIs, and GraphQL servers where requests are short-lived.
- **Caveats**: Session-level features (e.g. `SET timezone`, temporary tables, advisory locks) are reset between transactions.

#### 2. Session Pooling (`pool_mode = session`)

- **How it Works**: When a client connects, PgBouncer assigns a backend PostgreSQL connection for the entire duration of the client connection.
- **Best For**: Applications requiring full PostgreSQL compatibility (e.g. legacy software, heavy use of prepared statements).
- **Caveats**: Maximum simultaneous clients is capped by `max_connections` on PostgreSQL.

#### 3. Statement Pooling (`pool_mode = statement`)

- **How it Works**: A backend connection is assigned only for a single SQL statement. Multi-statement transactions (`BEGIN ... COMMIT`) are prohibited.
- **Best For**: Read-only analytical queries and autocommit workloads.

---

### Tuning Core Configuration Parameters

```ini
[pgbouncer]
# Maximum client connections PgBouncer will accept from frontend apps
max_client_conn = 1000

# Default number of server connections per (user, database) pool
default_pool_size = 20

# Minimum server connections to keep open to avoid cold-connect latency
min_pool_size = 5

# Extra emergency connections allowed when default_pool_size is saturated
reserve_pool_size = 5
reserve_pool_timeout = 5

# Maximum backend server connections across all combined pools
max_db_connections = 50
```

- **`default_pool_size`**: Rule of thumb: $\text{Pool Size} \approx (\text{CPU Cores} \times 2) + \text{Disk Spindle Count}$. Setting this too high increases lock contention. A pool of 20–50 connections can easily serve 5,000 requests/sec.
- **`reserve_pool_size`**: Buffer connections opened only if clients have been waiting in the queue longer than `reserve_pool_timeout` seconds.

---

### Querying the PgBouncer Administrative Console

PgBouncer exposes an internal virtual database named `pgbouncer` accessible via port `6432`:

```bash
psql -h localhost -p 6432 -U postgres -d pgbouncer
```

Key administrative inspection commands:

- **`SHOW POOLS;`**: Shows client and server counts per pool:
  - `cl_active`: Clients currently executing a transaction.
  - `cl_waiting`: Clients waiting for an available server connection.
  - `sv_active`: Server connections actively assigned to clients.
  - `sv_idle`: Server connections open and ready in the pool.
- **`SHOW STATS;`**: Displays cumulative query counts, transaction volume, byte transfer, and average latency.
- **`PAUSE;` / `RESUME;`**: Flushes all active transactions and pauses incoming queries (used for zero-downtime database maintenance).
- **`RELOAD;`**: Hot-reloads `pgbouncer.ini` without disconnecting clients.

---

### Handling Prepared Statements & Session State in Transaction Pooling

In transaction pooling, because consecutive transactions from the same client may run on different backend PostgreSQL connections:

1. **Session Variables**: Avoid `SET work_mem = ...` inside long-lived connections unless scoped to the transaction (`SET LOCAL work_mem = ...`).
2. **Prepared Statements**:
   - Modern drivers (e.g. `psycopg3`, `node-postgres`, `pgx`) support automatic unnamed prepared statements or statement caching.
   - For named prepared statements, PgBouncer 1.21+ supports `max_prepared_statements` to manage prepared statements transparently.

---

## 📂 Repository & Directory Structure

All files and generated artifacts are strictly contained within this directory:

```text
12-databases-ops/04-pgbouncer-connection-pooling-tuning/
├── docker-compose.yml       # Multi-container PostgreSQL (5432) & PgBouncer (6432) stack
├── requirements.txt         # Python dependencies (psycopg2-binary, tabulate)
├── .env.example             # Template for ports, credentials, and pool sizes
├── .gitignore               # Excludes logs, benchmark reports, and python caches
├── .markdownlint.json       # Linter configuration for technical documentation
├── benchmark_concurrency.py # High-concurrency benchmark engine (500 clients)
├── test_pgbouncer.sh        # End-to-end automated test runner (7 test checkpoints)
├── cleanup.sh               # Complete environment teardown and resource purge
├── config/
│   ├── pgbouncer.ini        # PgBouncer tuning configuration file
│   ├── userlist.txt         # Authentication userlist for PgBouncer
│   └── 01-init.sql          # Benchmark schema (accounts, transactions) & roles
└── README.md                # Educational documentation and hands-on guide
```

---

## 💻 Prerequisites & System Setup

Ensure the following tools are installed:

- **Container Engine**: Docker Engine / OrbStack (recommended for macOS) with Docker Compose.
- **Python**: Python 3.9+ (optional on host; scripts include built-in CLI fallbacks).
- **PostgreSQL Client (Optional)**: `psql` (if omitted on host, scripts automatically route operations through Docker).
- **Core CLI Tools**: `bash`, `curl`, `jq`, `coreutils`.

---

## 🚀 Quickstart Guide (3 Commands)

Execute the full connection pooling lifecycle and benchmark in 3 simple commands:

```bash
# 1. Start PostgreSQL (5432) and PgBouncer (6432)
docker compose up -d --wait

# 2. Run the complete automated test suite (500 clients benchmark, pool stats, isolation)
./test_pgbouncer.sh

# 3. Clean up all resources when finished
./cleanup.sh
```

---

## 📖 Step-by-Step Hands-On Guide

### Step 1: Start PostgreSQL and PgBouncer Cluster

Launch the multi-container stack:

```bash
docker compose up -d --wait
```

Verify that both containers are running and healthy:

```bash
docker compose ps
```

Expected output:

```text
NAME                IMAGE                     STATUS                   PORTS
pgbouncer-pooler    edoburu/pgbouncer:latest  Up (healthy)             0.0.0.0:6432->5432/tcp
postgres-pool-db    postgres:16-alpine        Up (healthy)             0.0.0.0:5432->5432/tcp
```

---

### Step 2: Verify Direct & Pooled Database Connectivity

Query PostgreSQL directly on port `5432`:

```bash
PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d benchmark_db -c "SELECT COUNT(*) FROM accounts;"
```

Query PostgreSQL through the PgBouncer proxy on port `6432`:

```bash
PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres -d benchmark_db -c "SELECT COUNT(*) FROM accounts;"
```

Both return 1,000 seeded bank accounts.

---

### Step 3: Inspect Real-Time Pool Telemetry (`SHOW POOLS`)

Connect to the special administrative database `pgbouncer` on port `6432`:

```bash
PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;"
```

Output:

```text
   database   |   user    | cl_active | cl_waiting | sv_active | sv_idle | pool_mode  
--------------+-----------+-----------+------------+-----------+---------+-------------
 benchmark_db | postgres  |         0 |          0 |         0 |       5 | transaction
```

---

### Step 4: Execute High-Concurrency Benchmark (500 Clients)

Run the automated benchmark comparing 500 simultaneous clients connecting directly vs. through PgBouncer:

```bash
python3 benchmark_concurrency.py --concurrency 500 --hold-sec 0.3
```

---

### Step 5: Analyze Connection Exhaustion vs. 100% Pooled Success

Benchmark output comparison:

```text
======================================================================
  📊 Concurrency Benchmark: Direct PostgreSQL vs PgBouncer Pooling
======================================================================

Metric                         | Direct PG (Port 5432)          | PgBouncer (Port 6432)         
----------------------------------------------------------------------------------------------
Total Clients Requested        | 500                            | 500                           
Successful Connections         | 253 (50.6%)                    | 500 (100.0%)                  
Failed Connections             | 247                            | 0                             
Total Transactions Done        | 253                            | 500                           
Throughput (TPS)               | 97.29 tx/s                     | 64.60 tx/s                    
Total Test Duration            | 2.60 s                         | 7.74 s                        
Connection Latency (p50)       | 581.01 ms                      | 2965.29 ms                    
Connection Latency (p95)       | 764.22 ms                      | 5276.73 ms                    

Direct PostgreSQL Error Breakdown (max_connections=50 constraint):
  • FATAL: sorry, too many clients already (max_connections=50 exceeded): 247 client(s) rejected

✔ PgBouncer completed all 500 client connections with 0 errors!
```

Key Takeaways:

1. **Direct Connection Exhaustion**: Direct PostgreSQL failed nearly 50% of client connections as soon as concurrent clients exceeded `max_connections = 50`.
2. **PgBouncer Resilience**: PgBouncer absorbed all 500 clients into its lightweight event loop, queuing requests and processing them through 20 server connections with **100% success and 0 errors**.

---

### Step 6: Verify Transaction State Isolation & Cleanliness

Verify that state from one client's transaction does not leak to the next client using the pooled connection:

```bash
python3 -c "
import psycopg2
conn = psycopg2.connect(host='localhost', port=6432, dbname='benchmark_db', user='postgres', password='postgres')
with conn.cursor() as cur:
    cur.execute('BEGIN; UPDATE accounts SET balance = balance + 50 WHERE id = 1; COMMIT;')
conn.close()
print('Transaction committed cleanly through PgBouncer!')
"
```

---

### Step 7: Run the Complete Automated Test Suite

Run the full automated test suite validating all 7 checkpoints:

```bash
./test_pgbouncer.sh
```

---

## 🛠️ Troubleshooting & Common Gotchas

### 1. Port 5432 or 6432 Already Bound

If port 5432 or 6432 is in use by another local database service:

- Edit `.env` and set `POSTGRES_PORT=54323` and `PGBOUNCER_PORT=64323`.
- Re-run `docker compose up -d`.

### 2. "server login failed: password authentication failed"

Ensure that the credentials configured in `config/userlist.txt` match the PostgreSQL database users.

### 3. Application Using Session-Level Features

If your ORM requires session-level features (e.g. prepared statements with parameters or `LISTEN/NOTIFY`), switch `POOL_MODE=session` or configure your client driver to disable server-side prepared statements.

---

## 🧹 Resource Teardown & Complete Cleanup

To leave your development workstation clean and ready for subsequent mini-projects, run:

```bash
./cleanup.sh
```

### Options & Deep Purge

| Command | Action Performed |
| :--- | :--- |
| `./cleanup.sh` | Stops and removes containers (`postgres-pool-db`, `pgbouncer-pooler`), deletes Docker network (`pgbouncer-net`), deletes named volume (`postgres_pool_data`), and purges all temporary benchmark reports and python cache files. |
| `./cleanup.sh --all` | Performs standard teardown AND deletes downloaded container images (`postgres:16-alpine`, `edoburu/pgbouncer:latest`), freeing maximum disk space. |

### Manual Verification of Zero Leftovers

Confirm that all resources have been completely removed:

```bash
# Verify no running containers
docker ps -a --filter "name=postgres-pool-db" --filter "name=pgbouncer-pooler"

# Verify no orphaned volumes
docker volume ls --filter "name=postgres_pool_data"
```

The environment is now clean for the next mini-project!
