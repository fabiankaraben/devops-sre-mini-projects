# DevOps & SRE mini-projects

Welcome to **DevOps & SRE mini-projects** — an educational, challenge-driven repository designed to build and sharpen practical skills across the entire DevOps, Cloud Infrastructure, and Site Reliability Engineering (SRE) lifecycle.

This repository serves as a progressive, hands-on learning roadmap and portfolio containing **130 structured mini-projects** organized into **12 technical domains** (ordered progressively from foundational concepts to advanced production-grade architectures). Rather than focusing only on theory, each challenge models real-world engineering scenarios with self-contained companion workload generators, failure simulators, and automated verification procedures.

## What you will find in this repository

- 🎯 **12 Core Engineering Domains**: Spanning Linux system internals, networking, container optimization, Kubernetes orchestration, CI/CD automation, Infrastructure as Code (IaC), cloud serverless architectures, observability, centralized logging, SRE reliability engineering, DevSecOps hardening, and database operational resilience.
- 📦 **End-to-End Deliverables**: Every challenge specifies both the primary implementation files and the auxiliary components (e.g. traffic injectors, mock APIs, data seeders, and chaos scripts) required to simulate realistic production workloads.
- 💻 **Zero-Cost & Local-First Infrastructure**: All challenges are designed to run locally using lightweight tooling ([OrbStack](https://orbstack.dev/) containers and Linux VMs, [K3s](https://k3s.io/)/[K3d](https://k3d.io/), and [LocalStack](https://localstack.cloud/)) or within the Free Tiers of AWS, GCP, and Azure without requiring paid cloud resources.
- 🧪 **Actionable Verification & Testing**: Every mini-project includes concrete testing instructions, terminal commands, and validation criteria to confirm proper behavior, error handling, and reliability.

![Featured Image](https://fabiankaraben.github.io/mini-projects/imgs/devops-sre.webp)

## Setup instructions

1. **Local Container & VM Engine**: Install [OrbStack](https://orbstack.dev/) (recommended for macOS), Docker Desktop, or Podman
2. **Local Kubernetes**: Use lightweight [K3s](https://k3s.io/), [K3d](https://k3d.io/), or OrbStack's built-in Kubernetes cluster
3. **Local Cloud Emulators**: Install [LocalStack](https://localstack.cloud/) (`localstack` / `tflocal`) for zero-cost local AWS simulation
4. **Cloud Free Tiers (Optional)**: AWS Free Tier, GCP Free Tier, or Azure Free Tier account with configured CLI credentials
5. **DevOps & IaC Tooling**: Install `terraform` (or `opentofu`), `ansible`, `kubectl`, `helm`, `python3`, `go`, `curl`, `jq`, and `openssl`
6. **Project Environment**: Copy `.env.example` to `.env` in each project directory and populate the required variables

---

## 01. Linux Scripting

1. **System Resource Health Checker**  
   🔹 **Goal & Context**: Build a local monitoring utility in Bash that inspects host/VM health (`/proc/stat`, `/proc/meminfo`, `df -h`) and emits formatted JSON metrics. This teaches foundational Linux system metrics and POSIX CLI flag parsing.  
   📦 **Deliverables & Scope**:  
   - `health_check.sh`: Main monitoring script accepting flags (`--cpu-max`, `--mem-max`, `--disk-max`) and outputting JSON status with standard Linux exit codes (`0` = OK, `1` = Warning, `2` = Critical).  
   - `stress_simulator.sh`: Companion script utilizing `dd` and CPU spin-loops to safely generate controllable resource spikes for testing.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / Ubuntu container) or Cloud (AWS EC2 t2.micro Free Tier)  
   🧪 **Testing**: Run `stress_simulator.sh` in the background, execute `health_check.sh --cpu-max 50`, and verify that the JSON output flags the CPU warning and returns exit code 1.  
   🔹 [Project directory](01-linux-scripting/01-system-resource-health-checker)

2. **Log File Rotation and Archiver**  
   🔹 **Goal & Context**: Automate log file management on a Linux filesystem by archiving older files without interrupting active services writing to those logs.  
   📦 **Deliverables & Scope**:  
   - `log_rotate.sh`: Shell script that compresses (`gzip`), timestamps (ISO-8601), moves logs older than $N$ days to `/var/archive`, and purges archives beyond retention policy.  
   - `mock_log_producer.py`: Background daemon producing continuous timestamped logs while maintaining an open file descriptor (`lsof`) to verify safe non-destructive rotation.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / Docker Ubuntu container)  
   🧪 **Testing**: Start `mock_log_producer.py`, execute `log_rotate.sh`, and verify that active logs continue receiving entries while older files are compressed and archived cleanly.  
   🔹 [Project directory](01-linux-scripting/02-log-file-rotation-archiver)

3. **User and Group Batch Provisioner**  
   🔹 **Goal & Context**: Automate user onboarding and access control on Linux servers by idempotently provisioning accounts, secondary groups, and SSH public keys from a declarative manifest.  
   📦 **Deliverables & Scope**:  
   - `provision_users.sh`: POSIX script that reads a user manifest, creates users/groups, sets home directories, configures `.ssh/authorized_keys` with `0600` permissions, and handles user deactivation.  
   - `users_manifest.csv`: Sample dataset containing usernames, primary/secondary groups, sudo privileges, and public keys.  
   - `cleanup_users.sh`: Rollback script to reset the test environment.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / disposable Docker container)  
   🧪 **Testing**: Execute `provision_users.sh` against the manifest in a container; verify `id <username>`, file permissions in `/home/<user>/.ssh`, and test simulated SSH login.  
   🔹 [Project directory](01-linux-scripting/03-user-group-batch-provisioner)

4. **Process Watchdog Daemon**  
   🔹 **Goal & Context**: Implement a resilient process supervisor that monitors critical background services, automatically restarts them upon unexpected termination, and alerts administrators.  
   📦 **Deliverables & Scope**:  
   - `watchdog.py` / `watchdog.sh`: Daemon running on a timer checking target PIDs/service names, tracking crash restart counts to prevent flapping, and firing webhook alerts.  
   - `flaky_service.py`: Mock HTTP service programmed to crash on demand or at random intervals.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM with systemd / Docker container with supervisor)  
   🧪 **Testing**: Start the flaky service and watchdog; trigger an intentional crash with `kill -9` or via HTTP endpoint, and verify the watchdog restarts the service within 5 seconds and logs the incident.  
   🔹 [Project directory](01-linux-scripting/04-process-watchdog-daemon)

5. **Automated Backup with S3 Upload**  
   🔹 **Goal & Context**: Create a robust backup pipeline that dumps target directories and databases, applies GPG symmetric encryption, and uploads encrypted tarballs to S3 object storage with integrity checks.  
   📦 **Deliverables & Scope**:  
   - `backup_s3.sh`: Script generating SQLite database dumps, compressing to `.tar.gz`, encrypting via `gpg --symmetric`, computing SHA256 hashes, and uploading via AWS CLI / S3 API.  
   - `mock_db_seeder.py`: Script generating a sample SQLite database and test filesystem assets.  
   - `verify_restore.sh`: Script downloading the backup from S3, decrypting, and comparing SHA256 checksums.  
   🏗️ **Infrastructure**: Local (OrbStack/Docker with MinIO) or Cloud (AWS S3 Free Tier)  
   🧪 **Testing**: Run the backup script against local MinIO; execute `verify_restore.sh` to confirm identical file contents and successful SQLite table recovery.  
   🔹 [Project directory](01-linux-scripting/05-automated-backup-s3-upload)

6. **SSL/TLS Certificate Expiry Auditor**  
   🔹 **Goal & Context**: Develop a network auditing CLI tool that scans a list of web domains or IP endpoints, establishes TLS handshakes, extracts certificate metadata, and alerts on upcoming expirations.  
   📦 **Deliverables & Scope**:  
   - `cert_auditor.py` / `cert_auditor.go`: Concurrent scanner connecting to port 443, extracting `notAfter` timestamps, calculating days until expiry, and exporting JSON/Prometheus metrics.  
   - `mock_tls_environment/`: Docker Compose setup hosting 3 local Nginx endpoints: valid cert (90 days), expiring soon (10 days), and expired.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / Host OS)  
   🧪 **Testing**: Run the auditor against the mock TLS containers; verify that endpoints expiring in <30 days are flagged with warning status in the final summary report.  
   🔹 [Project directory](01-linux-scripting/06-ssl-certificate-expiry-auditor)

7. **Network Port Scanner and Troubleshooter**  
   🔹 **Goal & Context**: Build a concurrent network troubleshooting CLI tool that scans CIDR blocks and port ranges, checks DNS resolution latency, and diagnoses firewall connectivity issues.  
   📦 **Deliverables & Scope**:  
   - `net_troubleshoot.go` / `net_troubleshoot.py`: Non-blocking scanner using goroutines/asyncio for TCP connect scans, DNS lookup timing, and outputting formatted Markdown tables.  
   - `mock_network_grid/`: Docker Compose bridge network hosting services with mixed open/closed ports (HTTP: 80, SSH: 22, DB: 5432, Filtered: 8080).  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / multi-container Docker bridge network)  
   🧪 **Testing**: Scan the mock network grid; assert scan completion time under 3 seconds and verify 100% accuracy against standard `nmap` output.  
   🔹 [Project directory](01-linux-scripting/07-network-port-scanner-troubleshooter)

8. **Zombie and Orphan Process Reaper**  
   🔹 **Goal & Context**: Understand Linux kernel process lifecycles by building a diagnostic tool that inspects `/proc`, identifies zombie (`Z`) and orphan processes, traces parent ancestry, and cleans them up.  
   📦 **Deliverables & Scope**:  
   - `process_reaper.py`: Script parsing `/proc/[pid]/stat`, identifying defunct processes whose parents failed to call `wait()`, and sending `SIGCHLD` or `SIGKILL` to parent processes.  
   - `zombie_spawner.c` / `zombie_spawner.py`: Test program that forks child processes and exits the parent or abandons children to create simulated zombies.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM with full `/proc` subsystem access)  
   🧪 **Testing**: Launch `zombie_spawner`, run `process_reaper.py`, and verify through `ps aux` and `/proc` that defunct entries are successfully reaped.  
   🔹 [Project directory](01-linux-scripting/08-zombie-orphan-process-reaper)

9. **Kernel and Sysctl Performance Tuner**  
   🔹 **Goal & Context**: Write a system tuning script that assesses current Linux kernel parameters (`sysctl`), compares them against high-performance production baselines, and applies optimized configurations.  
   📦 **Deliverables & Scope**:  
   - `sysctl_tuner.sh`: Script inspecting parameters (TCP buffer sizes, `somaxconn`, `swappiness`, `file-max`), creating backups, applying `/etc/sysctl.d/99-performance.conf`, and providing `--rollback`.  
   - `benchmark_network.sh`: Micro-benchmark script measuring socket connection throughput before and after tuning.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / privileged Docker container)  
   🧪 **Testing**: Execute `sysctl_tuner.sh` inside a test VM; verify parameter application with `sysctl -a`, run the benchmark, and test the `--rollback` option.  
   🔹 [Project directory](01-linux-scripting/09-kernel-sysctl-performance-tuner)

10. **Unified DevOps Toolkit CLI**  
    🔹 **Goal & Context**: Consolidate multiple DevOps utilities (system health, log analysis, SSH execution pools, and cloud cost estimation) into a single, production-grade CLI binary in Go or Python.  
    📦 **Deliverables & Scope**:  
    - `devops-cli` codebase (Go using Cobra or Python using Click) with structured subcommands (`sys health`, `log stats`, `ssh run`, `cost estimate`), flag parsing, and autocompletion scripts.  
    - Comprehensive unit test suite with mock interfaces for remote execution and filesystem access.  
    🏗️ **Infrastructure**: Local (Host OS / OrbStack Linux VM)  
    🧪 **Testing**: Run automated unit tests (`go test ./...` or `pytest`), test shell completion in bash/zsh, and verify command execution with `--help` and `--json` flags.  
    🔹 [Project directory](01-linux-scripting/10-unified-devops-toolkit-cli)

---

## 02. Networking & Traffic Routing

1. **Static Web Nginx Reverse Proxy**  
   🔹 **Goal & Context**: Configure Nginx as an edge reverse proxy to serve static files with aggressive client-side caching and gzip compression while proxying API requests to a dynamic backend.  
   📦 **Deliverables & Scope**:  
   - `nginx.conf`: Configuration enabling `gzip`, custom 404/50x error pages, `Cache-Control` headers for static assets, and `proxy_pass` to an upstream service.  
   - `mock_api.py`: Lightweight Python/Node HTTP backend serving dynamic JSON endpoints.  
   - Static web assets (`index.html`, `style.css`, `app.js`).  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose) or Cloud (AWS EC2 t2.micro / Lightsail Free Tier)  
   🧪 **Testing**: Execute `curl -I` against static and `/api` endpoints; verify `Content-Encoding: gzip`, `Cache-Control: max-age`, and HTTP 200 responses.  
   🔹 [Project directory](02-networking/01-static-web-nginx-reverse-proxy)

2. **Internal DNS Server with CoreDNS**  
   🔹 **Goal & Context**: Deploy CoreDNS to manage local name resolution for internal services (`.internal` zone) with split-horizon routing and upstream forwarding.  
   📦 **Deliverables & Scope**:  
   - `Corefile`: CoreDNS configuration defining local zone files, caching TTLs, health check endpoints, and fallback upstream forwarders (e.g. 1.1.1.1).  
   - Zone definition files containing A, CNAME, and TXT records for simulated internal services.  
   - `dns_test_client.sh`: Test script executing automated `dig` queries.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / Docker container running CoreDNS on port 53)  
   🧪 **Testing**: Run `dig @127.0.0.1 -p 53 app.internal A`; verify correct IP resolution, authoritative answer flags, and fast response times (<5ms).  
   🔹 [Project directory](02-networking/02-internal-dns-server-coredns)

3. **SSL/TLS Termination Reverse Proxy**  
   🔹 **Goal & Context**: Terminate TLS 1.3 at the reverse proxy layer using modern cipher suites, enforce HTTP-to-HTTPS redirection, and forward clean HTTP traffic to internal backend services.  
   📦 **Deliverables & Scope**:  
   - Nginx/Traefik configuration with strict TLS 1.3 settings, HSTS (`Strict-Transport-Security`), and SSL session caching.  
   - `generate_certs.sh`: Script generating self-signed certificates or using `mkcert` for trusted local HTTPS development.  
   - Backend web application receiving forwarded `X-Forwarded-Proto` and `X-Forwarded-For` headers.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with `mkcert`) or Cloud (AWS EC2 + Let's Encrypt Free Tier)  
   🧪 **Testing**: Run `openssl s_client -connect localhost:443 -tls1_3` to verify TLS 1.3 negotiation, and verify HTTP 301 redirection on port 80.  
   🔹 [Project directory](02-networking/03-ssl-tls-termination-reverse-proxy)

4. **Layer 4 TCP HAProxy Load Balancer**  
   🔹 **Goal & Context**: Build a Layer 4 (TCP) load balancer using HAProxy that distributes network connections across multiple backend instances with active TCP health checks.  
   📦 **Deliverables & Scope**:  
   - `haproxy.cfg`: Configuration in `mode tcp` using `roundrobin` and `leastconn` algorithms, active health checks (`check inter 2000`), and a web statistics dashboard on port 8404.  
   - 3 identical backend TCP/HTTP services returning their container hostname.  
   - `traffic_simulator.sh`: Script sending sequential TCP requests to verify load distribution.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with multi-container backend pool)  
   🧪 **Testing**: Send 100 requests via `traffic_simulator.sh`; stop one backend container and verify that HAProxy removes it from the active pool without dropping connections.  
   🔹 [Project directory](02-networking/04-layer4-haproxy-load-balancer)

5. **API Gateway with Leaky-Bucket Rate Limiting**  
   🔹 **Goal & Context**: Protect downstream APIs from traffic bursts and brute-force attacks by implementing IP-based rate limiting, request payload restrictions, and custom JSON error handling.  
   📦 **Deliverables & Scope**:  
   - Nginx / Envoy configuration implementing `limit_req_zone` (leaky bucket), burst allowances, and custom HTTP 429 JSON response payloads.  
   - Mock REST API with authentication endpoints.  
   - `burst_tester.py`: Concurrency test script sending requests exceeding the configured rate limit.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose API Gateway)  
   🧪 **Testing**: Execute `burst_tester.py`; verify that requests within limits receive HTTP 200 while excess requests receive HTTP 429 with `Retry-After` headers.  
   🔹 [Project directory](02-networking/05-api-gateway-rate-limiting)

6. **Site-to-Site WireGuard VPN Mesh**  
   🔹 **Goal & Context**: Establish a secure, high-performance encrypted VPN tunnel connecting two isolated network subnets using WireGuard.  
   📦 **Deliverables & Scope**:  
   - `wg0.conf` for Node A (Subnet 10.10.0.0/24) and Node B (Subnet 10.20.0.0/24) with cryptographic keypairs and `AllowedIPs` routing tables.  
   - Docker Compose multi-network setup creating isolated bridge subnets.  
   - `vpn_connectivity_test.sh`: Script executing cross-subnet ICMP and HTTP requests over the `wg0` interface.  
   🏗️ **Infrastructure**: Local (Two isolated OrbStack Linux VMs / Docker networks with `NET_ADMIN` capability)  
   🧪 **Testing**: Run ping and curl commands from Subnet A to an internal IP in Subnet B; inspect `tcpdump -i eth0` to confirm that all payload packets are WireGuard encrypted (UDP 51820).  
   🔹 [Project directory](02-networking/06-wireguard-vpn-mesh)

7. **Linux Firewall Hardening with nftables**  
   🔹 **Goal & Context**: Build a hardened Linux stateful firewall using `nftables` that enforces a default-drop policy, prevents IP spoofing, rate-limits ICMP, and defends against port scanning.  
   📦 **Deliverables & Scope**:  
   - `nftables.conf`: Stateful ruleset allowing established/related traffic, permitting specific ingress ports (SSH, HTTP), rate-limiting SYN floods, and dropping invalid packets.  
   - `firewall_audit.sh`: Automated security audit script using `nmap` and `hping3` to test firewall defenses.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM with kernel nftables/iptables support)  
   🧪 **Testing**: Execute `firewall_audit.sh`; verify closed ports are dropped silently, rate limits trigger on SYN floods, and legitimate SSH traffic connects uninterrupted.  
   🔹 [Project directory](02-networking/07-linux-firewall-nftables-hardening)

8. **Shadow Traffic Mirroring Proxy**  
   🔹 **Goal & Context**: Safely test new software releases against real production traffic by asynchronously duplicating and routing incoming live requests to a shadow backend without impacting client latency.  
   📦 **Deliverables & Scope**:  
   - Nginx (with `ngx_http_mirror_module`) or Envoy Proxy configuration duplicating HTTP POST/GET traffic to a shadow cluster.  
   - Primary Production API service + Shadow Experimental API service.  
   - `traffic_injector.py`: Script simulating continuous user traffic and inspecting shadow logs for exact request replication.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with primary & shadow target services)  
   🧪 **Testing**: Send 50 HTTP POST requests to the proxy; verify that the client receives immediate responses from the primary API and shadow logs reflect 100% of the mirrored payloads.  
   🔹 [Project directory](02-networking/08-shadow-traffic-mirroring-proxy)

9. **Dynamic DNS Updater Daemon**  
   🔹 **Goal & Context**: Build a resilient background daemon that monitors public WAN IP changes and dynamically updates DNS A-records via cloud DNS APIs (Cloudflare or AWS Route 53).  
   📦 **Deliverables & Scope**:  
   - `ddns_daemon.py` / `ddns_daemon.go`: Daemon performing STUN/HTTP IP lookups, evaluating IP cache to avoid redundant API calls, and updating DNS records with exponential backoff retries.  
   - `mock_dns_api.py`: Mock Cloudflare/Route53 REST API for local offline validation.  
   🏗️ **Infrastructure**: Local (OrbStack VM / Docker) + Cloud (Cloudflare Free Plan API / AWS Route 53)  
   🧪 **Testing**: Run the daemon against the mock DNS API; simulate WAN IP changes and assert that the daemon detects the transition and issues the DNS record update within 30 seconds.  
   🔹 [Project directory](02-networking/09-dynamic-dns-updater-daemon)

10. **Envoy L7 Canary Router and Circuit Breaker**  
    🔹 **Goal & Context**: Configure Envoy Proxy as an edge router performing Layer 7 canary traffic shifting (90% v1 / 10% v2), header-based canary overrides (`x-canary: true`), and automatic outlier detection circuit breaking.  
    📦 **Deliverables & Scope**:  
    - `envoy.yaml`: Advanced Envoy configuration with weighted clusters, header match routes, and circuit breaker connection pool thresholds.  
    - `service_v1` (stable backend) and `service_v2` (canary backend).  
    - `canary_verification.py`: Statistical load generator measuring traffic distribution across both versions.  
    🏗️ **Infrastructure**: Local (OrbStack / Docker Compose running Envoy + upstream backends)  
    🧪 **Testing**: Send 1000 requests; verify an approximate 90/10 traffic split, assert that requests with `x-canary: true` route 100% to v2, and confirm that injecting 500 errors into v2 trips the circuit breaker.  
    🔹 [Project directory](02-networking/10-envoy-canary-router-circuit-breaker)

---

## 03. Containers & Image Optimization

1. **Multi-Stage Minimal Dockerfile**  
   🔹 **Goal & Context**: Reduce container attack surfaces and optimize image transfer speeds by refactoring fat container builds into ultra-minimal, non-root multi-stage images (<25MB).  
   📦 **Deliverables & Scope**:  
   - Sample Go / Node.js / Python application.  
   - `Dockerfile.fat` (unoptimized single-stage baseline) vs `Dockerfile.slim` (multi-stage build using Alpine / Distroless and non-root `UID 10001`).  
   - `.dockerignore` file optimized for build context reduction.  
   - `compare_images.sh`: Script comparing image sizes, layer history, and execution security.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Engine with BuildKit)  
   🧪 **Testing**: Build both images with `compare_images.sh`; verify that the slim image is <25MB, has fewer layers, and runs as an unprivileged user (`docker exec ... whoami`).  
   🔹 [Project directory](03-containers/01-multi-stage-minimal-dockerfile)

2. **Multi-Service Docker Compose Stack**  
   🔹 **Goal & Context**: Orchestrate a multi-tier microservice architecture using Docker Compose, establishing custom bridge networks, volume persistence, and health-checked startup dependencies.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` linking Frontend (Nginx), Web API (Python/Go), Cache (Redis), Database (PostgreSQL), and Management UI (Adminer).  
   - Network segmentation (frontend-net, backend-net, db-net) and service healthcheck conditions (`condition: service_healthy`).  
   - `e2e_compose_test.sh`: End-to-end CRUD integration test.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose)  
   🧪 **Testing**: Run `docker compose up -d`, monitor startup order with `docker compose ps`, and execute `e2e_compose_test.sh` to confirm database connectivity and cache hits.  
   🔹 [Project directory](03-containers/02-multi-service-docker-compose-stack)

3. **Container Healthchecks and Autoheal Engine**  
   🔹 **Goal & Context**: Implement reliable application-level healthchecks inside Docker containers and build an auto-healing watcher daemon that detects unhealthy containers and restarts them automatically.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` with custom `HEALTHCHECK` commands probing HTTP endpoints and database connection pools.  
   - `flaky_app/`: API with an intentional `/break` endpoint to simulate silent hangs and memory leaks.  
   - `autoheal_daemon.py`: Docker socket event listener that detects `unhealthy` container events and initiates graceful restarts.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose)  
   🧪 **Testing**: Trigger the `/break` endpoint; observe Docker marking the container as `unhealthy` and confirm that `autoheal_daemon.py` triggers an automatic restart.  
   🔹 [Project directory](03-containers/03-container-healthchecks-autoheal)

4. **BuildKit Layer Caching and Secrets Mounting**  
   🔹 **Goal & Context**: Accelerate container build times in CI/CD pipelines by leveraging Docker BuildKit cache mounts (`--mount=type=cache`) and secure build-time secret injection without leaking credentials into image layers.  
   📦 **Deliverables & Scope**:  
   - `Dockerfile` using BuildKit syntax for package manager cache caching (`npm`/`pip`/`go cache`) and secret mounts (`--mount=type=secret,id=api_key`).  
   - `benchmark_builds.sh`: Script testing cold vs warm build speeds and scanning image history for secret leaks.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker BuildKit)  
   🧪 **Testing**: Run `benchmark_builds.sh`; verify that warm builds complete in <5 seconds and `docker history` reveals zero trace of build secrets.  
   🔹 [Project directory](03-containers/04-buildkit-caching-secrets)

5. **Distroless Hardened Container Runtimes**  
   🔹 **Goal & Context**: Build ultra-secure container images using Google Distroless and Chainguard Wolfi base images, completely removing shells, package managers, and unnecessary binaries.  
   📦 **Deliverables & Scope**:  
   - `Dockerfile.distroless` for compiled binaries (Go/Rust/C) and interpreted runtimes (Node.js/Python).  
   - `security_audit.sh`: Automated script scanning for CVEs and attempting interactive shell execution (`docker exec -it ... sh`).  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Engine)  
   🧪 **Testing**: Execute `security_audit.sh`; assert zero critical/high CVEs via Trivy and confirm that interactive shell execution is completely impossible.  
   🔹 [Project directory](03-containers/05-distroless-hardened-runtimes)

6. **Container Resource Constraints and OOM Profiler**  
   🔹 **Goal & Context**: Understand Linux cgroups v2 resource limits by configuring strict CPU and memory constraints on containers and profiling behavior when out-of-memory (OOM) limits are reached.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` configuring CPU quotas (`cpus: "0.5"`) and memory limits (`mem_limit: 128m`, `memswap_limit: 128m`).  
   - `memory_hog.py`: Test program that gradually allocates memory in 10MB chunks to trigger controlled OOM events.  
   - `oom_monitor.sh`: Script capturing Docker event streams and exit codes (exit code 137).  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / Docker with cgroups v2 enabled)  
   🧪 **Testing**: Run `memory_hog.py` inside the constrained container; verify that the Linux kernel OOM-killer terminates the process and Docker reports exit code 137 (`OOMKilled: true`).  
   🔹 [Project directory](03-containers/06-container-resource-constraints-oom-profiler)

7. **Docker Socket Security Proxy Gateway**  
   🔹 **Goal & Context**: Secure access to the privileged Docker daemon socket (`/var/run/docker.sock`) by deploying an API security proxy that exposes a restricted read-only subset of the API to monitoring agents.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` deploying HAProxy / Tecnativa Docker Socket Proxy with granular permission rules (`CONTAINERS=1`, `POST=0`, `VOLUMES=0`).  
   - `test_proxy_permissions.sh`: Test suite attempting permitted read requests (`GET /containers/json`) vs forbidden mutate requests (`POST /containers/create`).  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose)  
   🧪 **Testing**: Run `test_proxy_permissions.sh`; confirm that `GET` operations return 200 OK while `POST` operations receive 403 Forbidden.  
   🔹 [Project directory](03-containers/07-docker-socket-security-proxy)

8. **Multi-Architecture Image Builder with Buildx**  
   🔹 **Goal & Context**: Build, assemble, and test multi-architecture container images (`linux/amd64` and `linux/arm64`) using Docker Buildx and QEMU hardware emulation.  
   📦 **Deliverables & Scope**:  
   - Sample Go/Python application compiled across CPU architectures.  
   - `build_multiarch.sh`: Build script configuring Buildx builders, QEMU emulators, and pushing OCI multi-arch image manifests.  
   - `verify_architectures.sh`: Script verifying image execution on simulated `amd64` and `arm64` targets.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Buildx with QEMU multi-arch emulation)  
   🧪 **Testing**: Execute `verify_architectures.sh`; inspect the manifest using `docker buildx imagetools inspect` and verify correct architecture execution.  
   🔹 [Project directory](03-containers/08-multi-arch-builder-buildx)

9. **Rootless Container Execution Environment**  
   🔹 **Goal & Context**: Eliminate container-to-host root privilege escalation risks by configuring and running rootless containers using Podman or Rootless Docker with user namespaces.  
   📦 **Deliverables & Scope**:  
   - `setup_rootless.sh`: Automated setup script configuring subuid/subgid mappings (`/etc/subuid`, `/etc/subgid`) and rootless daemons.  
   - `verify_isolation.sh`: Script inspecting UID mapping inside the container namespace vs the host process table (`ps aux`).  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM running Rootless Docker or Podman)  
   🧪 **Testing**: Run a container under an unprivileged user; verify that `UID 0` inside the container maps to an unprivileged user ID (>100000) on the host operating system.  
   🔹 [Project directory](03-containers/09-rootless-container-environment)

10. **Custom Container Runtime from Scratch**  
    🔹 **Goal & Context**: Build a fundamental understanding of container technology by implementing a minimal container runtime in Go or C using Linux kernel namespaces, cgroups, and `pivot_root`.  
    📦 **Deliverables & Scope**:  
    - `my_runtime.go` / `my_runtime.c`: Program configuring `CLONE_NEWPID`, `CLONE_NEWUTS`, `CLONE_NEWNS`, mounting an isolated rootfs, and setting cgroup memory limits.  
    - Minimal Alpine rootfs archive used as the container filesystem bundle.  
    - `runtime_test_suite.sh`: Verification script asserting PID isolation, filesystem boundaries, and hostname segregation.  
    🏗️ **Infrastructure**: Local (OrbStack Linux VM with root privileges for namespace creation)  
    🧪 **Testing**: Execute a process with `my_runtime`; run `ps` inside to confirm PID 1 status, verify inability to see host files, and confirm memory constraint enforcement.  
    🔹 [Project directory](03-containers/10-custom-container-runtime-from-scratch)

---

## 04. Kubernetes & Orchestration

1. **Stateless Application Deployment and Service**  
   🔹 **Goal & Context**: Deploy a resilient, scalable stateless web application on Kubernetes using declarative manifests, multi-replica Deployments, ClusterIP Services, and HTTP health probes.  
   📦 **Deliverables & Scope**:  
   - `deployment.yaml`: Deployment with 3 replicas, rolling update strategy, resource requests/limits, and HTTP `livenessProbe` and `readinessProbe`.  
   - `service.yaml`: ClusterIP service routing traffic across healthy pods.  
   - `app/`: Simple REST API in Go/Python returning pod hostname and environment info.  
   - `rollout_test.sh`: Script performing zero-downtime rolling updates.  
   🏗️ **Infrastructure**: Local (K3s / K3d / OrbStack Kubernetes / Kind)  
   🧪 **Testing**: Apply manifests, port-forward the service, execute `rollout_test.sh` during an image update, and verify 100% request success rate with zero dropped connections.  
   🔹 [Project directory](04-orchestration/01-stateless-app-deployment-service)

2. **ConfigMaps, Secrets, and Dynamic Reloading**  
   🔹 **Goal & Context**: Decouple application configuration and credentials from container images using Kubernetes ConfigMaps and Secrets, and automate pod reloads upon config changes.  
   📦 **Deliverables & Scope**:  
   - `configmap.yaml`, `secret.yaml`: Manifests defining environment variables and mounted configuration files.  
   - `deployment.yaml`: Deployment mounting configs as volumes and environment variables.  
   - Stakater Reloader deployment or custom watcher script to trigger rolling restarts on config mutations.  
   🏗️ **Infrastructure**: Local (K3s / K3d / OrbStack Kubernetes)  
   🧪 **Testing**: Update a value in `configmap.yaml` and apply it; verify that the pods automatically undergo a rolling restart and load the new configuration value.  
   🔹 [Project directory](04-orchestration/02-configmaps-secrets-reloading)

3. **Ingress Routing with Automated TLS via cert-manager**  
   🔹 **Goal & Context**: Expose internal Kubernetes services to external traffic using Nginx Ingress Controller with host/path routing and automated TLS certificate issuance with cert-manager.  
   📦 **Deliverables & Scope**:  
   - `ingress.yaml`: Ingress rules routing `api.local.dev` and `web.local.dev` to distinct backend services.  
   - cert-manager `ClusterIssuer` and `Certificate` manifests (Self-Signed / Let's Encrypt staging).  
   - `test_ingress_tls.sh`: Script sending HTTPS requests with custom Host headers to verify routing and certificate chains.  
   🏗️ **Infrastructure**: Local (K3s / K3d with Ingress controller and cert-manager) or Cloud (AWS EKS / GCP GKE Free Tier credits)  
   🧪 **Testing**: Run `test_ingress_tls.sh`; verify that `https://api.local.dev` and `https://web.local.dev` return valid TLS certificates and route to their respective backend services.  
   🔹 [Project directory](04-orchestration/03-ingress-routing-tls-cert-manager)

4. **StatefulSet and Dynamic Persistent Volumes**  
   🔹 **Goal & Context**: Deploy stateful distributed services (e.g. Redis Cluster / PostgreSQL) requiring stable network hostnames, ordered rollouts, and persistent volume storage.  
   📦 **Deliverables & Scope**:  
   - `statefulset.yaml`: StatefulSet with 3 replicas, volumeClaimTemplates requesting dynamic PVs via `StorageClass`, and Headless Service for DNS resolution.  
   - `persistence_test.sh`: Script writing unique data to `pod-0`, deleting the pod, and verifying state recovery upon pod restart.  
   🏗️ **Infrastructure**: Local (K3s / K3d with built-in `local-path` storage provisioner)  
   🧪 **Testing**: Execute `persistence_test.sh`; verify that data written to `/data` persists across forced pod deletions (`kubectl delete pod <name>`).  
   🔹 [Project directory](04-orchestration/04-statefulset-persistent-volumes)

5. **Horizontal Pod Autoscaler with Custom Metrics**  
   🔹 **Goal & Context**: Implement dynamic horizontal pod autoscaling (HPA v2) to scale application replicas automatically under varying CPU, memory, and custom application traffic load.  
   📦 **Deliverables & Scope**:  
   - `hpa.yaml`: HPA manifest with CPU/memory targets and scale-up/scale-down stabilization windows.  
   - `load_generator.sh`: Script generating concurrent HTTP traffic bursts using `hey` or `k6`.  
   - Metrics Server / Prometheus Adapter configuration.  
   🏗️ **Infrastructure**: Local (K3s / K3d with Metrics Server enabled)  
   🧪 **Testing**: Run `load_generator.sh`; monitor `kubectl get hpa -w` and verify that the deployment scales from 2 to 10 replicas and stabilizes back to 2 replicas once load ceases.  
   🔹 [Project directory](04-orchestration/05-horizontal-pod-autoscaler)

6. **Production-Grade Helm Chart Packaging**  
   🔹 **Goal & Context**: Package a multi-tier microservice application into a reusable, parameter-driven Helm 3 chart with templates, helper functions, JSON schema validation, and conditional subcharts.  
   📦 **Deliverables & Scope**:  
   - Helm chart directory (`Chart.yaml`, `values.yaml`, `values.schema.json`, `templates/`, `_helpers.tpl`).  
   - `helm_test_pipeline.sh`: Automation script executing `helm lint`, `helm template`, `helm install`, and `helm test`.  
   🏗️ **Infrastructure**: Local (K3s / K3d / OrbStack Kubernetes + Helm 3)  
   🧪 **Testing**: Execute `helm_test_pipeline.sh`; verify that custom values override templates correctly, schema validation catches invalid values, and `helm test` succeeds.  
   🔹 [Project directory](04-orchestration/06-production-helm-chart-packaging)

7. **RBAC Least-Privilege Policies and Pod Security**  
   🔹 **Goal & Context**: Secure Kubernetes clusters by implementing least-privilege Role-Based Access Control (RBAC) and enforcing Pod Security Admission (PSA) standards across namespaces.  
   📦 **Deliverables & Scope**:  
   - RBAC manifests (`Role`, `ClusterRole`, `RoleBinding`, `ServiceAccount`) defining Developer, CI/CD, and Read-Only personas.  
   - Namespace configuration with Pod Security Admission labels (`pod-security.kubernetes.io/enforce: restricted`).  
   - `rbac_audit_test.sh`: Script using `kubectl auth can-i` to validate permission boundaries.  
   🏗️ **Infrastructure**: Local (K3s / K3d cluster)  
   🧪 **Testing**: Run `rbac_audit_test.sh`; confirm that unauthorized actions are forbidden and deploying a privileged pod into the restricted namespace is blocked by the admission controller.  
   🔹 [Project directory](04-orchestration/07-rbac-pod-security-policies)

8. **Canary and Blue-Green Deployments with Argo Rollouts**  
   🔹 **Goal & Context**: Implement progressive traffic delivery using Argo Rollouts, performing automated canary steps (20% -> 40% -> 80% -> 100%) and automatic rollback on metric threshold breaches.  
   📦 **Deliverables & Scope**:  
   - `rollout.yaml`: Argo Rollouts manifest defining canary steps and `AnalysisTemplate` monitoring HTTP 500 error rates.  
   - `sample_app_v1` and `sample_app_v2` (with synthetic error injection endpoint).  
   - `canary_test_runner.sh`: Script driving traffic and triggering automated rollouts and rollbacks.  
   🏗️ **Infrastructure**: Local (K3s / K3d with Argo Rollouts controller installed)  
   🧪 **Testing**: Trigger a canary rollout with intentional errors in v2; verify that Argo Rollout pauses, detects the error rate breach, and executes an automatic rollback to v1.  
   🔹 [Project directory](04-orchestration/08-canary-blue-green-argo-rollouts)

9. **Zero-Trust Network Policies with Cilium CNI**  
   🔹 **Goal & Context**: Implement zero-trust micro-segmentation in Kubernetes using Cilium and `CiliumNetworkPolicy` to enforce default-deny policies, L7 HTTP filtering, and egress CIDR limits.  
   📦 **Deliverables & Scope**:  
   - Network policy manifests defining default-deny ingress/egress, allowing only Frontend -> Backend (HTTP POST `/api`) and Backend -> Database (TCP 5432).  
   - 3 test microservices (Frontend, Backend, Database) across separate namespaces.  
   - `network_policy_test.sh`: Connectivity matrix verification script.  
   🏗️ **Infrastructure**: Local (K3s / Kind cluster deployed with Cilium CNI)  
   🧪 **Testing**: Execute `network_policy_test.sh`; verify that unauthorized inter-pod traffic is dropped and authorized API calls pass with L7 visibility in `cilium monitor`.  
   🔹 [Project directory](04-orchestration/09-zero-trust-network-policies-cilium)

10. **Custom Kubernetes Operator with Kubebuilder**  
    🔹 **Goal & Context**: Build a custom Kubernetes Operator in Go using Kubebuilder and Controller-Runtime to automate the lifecycle of a custom resource (e.g. `ScheduledBackup`).  
    📦 **Deliverables & Scope**:  
    - Custom Resource Definition (`ScheduledBackup` CRD) with OpenAPI v3 validation and status subresources.  
    - Go Operator controller implementing the reconciliation loop, finalizers, and event recording.  
    - `operator_test_suite.sh`: Automated integration tests using `envtest` and live cluster deployment.  
    🏗️ **Infrastructure**: Local (K3s / K3d cluster + Kubebuilder / `envtest` suite)  
    🧪 **Testing**: Apply a `ScheduledBackup` custom resource; verify that the operator creates the backing CronJob/Pod, updates the CR status conditions, and cleans up upon deletion.  
    🔹 [Project directory](04-orchestration/10-custom-kubernetes-operator-kubebuilder)

11. **Multi-Environment Manifest Management with Kustomize**  
    🔹 **Goal & Context**: Manage multi-environment Kubernetes deployments (development, staging, and production) cleanly without duplication using Kustomize overlays, secret and config generators with hash suffixes, strategic merge patches, and JSON 6902 patches.  
    📦 **Deliverables & Scope**:  
    - `base/`: Base Kubernetes manifests (`deployment.yaml`, `service.yaml`, `kustomization.yaml`).  
    - `overlays/development/`, `overlays/staging/`, `overlays/production/`: Environment-specific overlays with replica overrides, resource limits, namespace prefixing, and `configMapGenerator`/`secretGenerator`.  
    - `validate_kustomize.sh`: Automation script executing `kubectl kustomize` for each environment and validating output diffs.  
    🏗️ **Infrastructure**: Local (K3s / K3d / OrbStack Kubernetes / Kubectl)  
    🧪 **Testing**: Run `validate_kustomize.sh`; verify that the production overlay generates 5 replicas with prod secrets while dev generates 1 replica with dev configs and debug flags enabled.  
    🔹 [Project directory](04-orchestration/11-multi-environment-kustomize-overlays)

12. **Advanced Pod Scheduling: Node Affinity, Taints, and Tolerations**  
    🔹 **Goal & Context**: Control workload placement across heterogeneous Kubernetes nodes using Node Selectors, Node Affinity (`requiredDuringSchedulingIgnoredDuringExecution` vs `preferredDuringSchedulingIgnoredDuringExecution`), Pod Anti-Affinity for high-availability spread, and Taints and Tolerations for dedicated/specialized nodes (e.g. GPU, high-memory, spot instances).  
    📦 **Deliverables & Scope**:  
    - `taints_and_tolerations.yaml`: Pods configured with tolerations (`key=gpu:NoSchedule`, `key=spot:NoExecute`) matching tainted nodes.  
    - `node_affinity.yaml`: Deployment with strict and preferred node affinity rules and `podAntiAffinity` (spreading pods across topology keys like `kubernetes.io/hostname` and failure domains).  
    - `node_setup.sh`: Script labeling (`env=gpu`, `tier=frontend`) and tainting test cluster nodes.  
    - `verify_scheduling.sh`: Verification script asserting exact node placements and scheduling rejection on unmatched taints.  
    🏗️ **Infrastructure**: Local (Multi-node K3d / Kind cluster)  
    🧪 **Testing**: Execute `verify_scheduling.sh`; verify that GPU pods land exclusively on tainted GPU nodes, standard pods are rejected from tainted nodes, and frontend pods spread across distinct physical nodes.  
    🔹 [Project directory](04-orchestration/12-pod-scheduling-node-affinity-taints)

13. **DaemonSets and Node-Level System Agents**  
    🔹 **Goal & Context**: Deploy and manage node-level system agents (e.g. log collector, security auditor, node exporter) across all worker and control-plane nodes using Kubernetes DaemonSets, tolerating master/control-plane taints and configuring RollingUpdate update strategies with `maxUnavailable`.  
    📦 **Deliverables & Scope**:  
    - `daemonset.yaml`: DaemonSet definition mounting host filesystem (`/var/log`, `/proc`, `/sys`), running with appropriate security contexts, and tolerations for control-plane nodes (`node-role.kubernetes.io/control-plane:NoSchedule`).  
    - `node_agent.py` / `node_agent.sh`: Lightweight agent gathering host stats and streaming to stdout.  
    - `daemonset_rollout_test.sh`: Script testing rolling updates and verifying pod scheduling when new nodes are dynamically added or cordoned.  
    🏗️ **Infrastructure**: Local (Multi-node K3d / Kind cluster)  
    🧪 **Testing**: Apply the DaemonSet; verify that exactly one pod runs on every cluster node (including control-plane), and verify zero-downtime rolling updates when updating agent image version.  
    🔹 [Project directory](04-orchestration/13-daemonsets-node-level-agents)

14. **Static Pods and Control Plane Bootstrap Diagnostics**  
    🔹 **Goal & Context**: Understand how Kubernetes bootstraps and operates without API server reliance by configuring, managing, and troubleshooting Static Pods directly supervised by the local Kubelet via `/etc/kubernetes/manifests`, and observing mirror pods created in the API server.  
    📦 **Deliverables & Scope**:  
    - `static-web.yaml`: Static pod manifest configured directly in the kubelet manifest directory.  
    - `bootstrap_static_pods.sh`: Script provisioning static pod manifests into the kubelet search path and inspecting kubelet systemd service logs.  
    - `mirror_pod_audit.sh`: Script testing mirror pod creation in `kubectl get pods`, verifying immutability via `kubectl delete`, and testing kubelet self-healing when the process is killed.  
    🏗️ **Infrastructure**: Local (OrbStack Linux VM running K3s/Kubelet or Kind node container)  
    🧪 **Testing**: Drop `static-web.yaml` into `/etc/kubernetes/manifests`; verify that the kubelet immediately spins up the container, mirror pod appears in `kubectl`, and attempting to delete it via API server automatically recreates it.  
    🔹 [Project directory](04-orchestration/14-static-pods-control-plane-diagnostics)

15. **Pod Priority Classes, Preemption, and Resource Quotas**  
    🔹 **Goal & Context**: Guarantee service availability for critical production workloads during cluster resource starvation by implementing Kubernetes PriorityClasses (`high-priority`, `batch-low-priority`), preemption policies, and namespace-level ResourceQuotas and LimitRanges.  
    📦 **Deliverables & Scope**:  
    - `priority_classes.yaml`: `PriorityClass` resources (`critical-prod` with value 1000000 and `preemptLowerPriority`, `batch-workload` with value 1000 and `preemptionPolicy: Never`).  
    - `resource_quota.yaml` & `limit_range.yaml`: Namespace limits constraining CPU/memory allocations.  
    - `starvation_test.sh`: Script filling cluster CPU capacity with low-priority pods, then deploying a high-priority pod to trigger automated eviction and preemption.  
    🏗️ **Infrastructure**: Local (K3s / K3d / Kind cluster with resource constraints)  
    🧪 **Testing**: Run `starvation_test.sh`; observe low-priority batch pods transitioning to `Terminating`/`Evicted` and verify that the high-priority pod immediately transitions from `Pending` to `Running`.  
    🔹 [Project directory](04-orchestration/15-priority-classes-preemption-quotas)

16. **Kubernetes Cluster Logging with Fluent Bit / Vector DaemonSet**  
    🔹 **Goal & Context**: Build an end-to-end container logging architecture in Kubernetes by deploying a Fluent Bit or Vector DaemonSet that tails `/var/log/pods`, enriches log records with Kubernetes metadata (pod, namespace, labels), filters sensitive data, and ships structured JSON logs to a centralized sink.  
    📦 **Deliverables & Scope**:  
    - `fluentbit-daemonset.yaml` (or `vector-daemonset.yaml`): DaemonSet configuration with custom parser pipelines, Kubernetes filter plugin, multi-line log parsing, and output buffering.  
    - `log_generator_app/`: Application producing multi-line stack traces and JSON structured logs.  
    - `verify_log_pipeline.sh`: Script tailing sink logs and asserting full metadata enrichment and regex parsing.  
    🏗️ **Infrastructure**: Local (K3s / K3d / Kind cluster + Mock Log Sink / Elasticsearch / Loki)  
    🧪 **Testing**: Deploy the log generator; run `verify_log_pipeline.sh` and verify that logs collected from `/var/log/pods` contain enriched namespace/pod labels and multi-line Java/Python stack traces are assembled into single log events.  
    🔹 [Project directory](04-orchestration/16-cluster-logging-fluentbit-vector)

17. **Kubernetes Cluster Monitoring and Alerting with Prometheus Operator**  
    🔹 **Goal & Context**: Deploy a production-grade Kubernetes monitoring stack using the Prometheus Operator (`kube-prometheus-stack`), instrumenting applications using Custom Resource Definitions (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`), and creating automated alerts and Grafana dashboards.  
    📦 **Deliverables & Scope**:  
    - `kube-prometheus-stack` values configuration or operator manifests.  
    - `servicemonitor.yaml` & `podmonitor.yaml`: CRDs targeting application metric endpoints (`/metrics`).  
    - `prometheus_rules.yaml`: Alerting rules triggering on high error rates (HTTP 5xx > 5%) and pod crash loops (`CrashLoopBackOff`).  
    - `alert_test_generator.sh`: Script generating synthetic errors to trip alert thresholds and verifying firing alerts in Prometheus / Alertmanager.  
    🏗️ **Infrastructure**: Local (K3s / K3d / Kind cluster + Prometheus Operator)  
    🧪 **Testing**: Execute `alert_test_generator.sh`; check Prometheus UI and Alertmanager to confirm `HighHttpErrorRate` transitions from `Pending` to `Firing` and verify Grafana dashboard visualization.  
    🔹 [Project directory](04-orchestration/17-monitoring-prometheus-operator-servicemonitor)

18. **CSI Storage, Dynamic Volume Expansion, and Volume Snapshots**  
    🔹 **Goal & Context**: Implement advanced Kubernetes storage lifecycle management using the Container Storage Interface (CSI), enabling dynamic volume provisioning, online PVC expansion without pod recreation, and crash-consistent VolumeSnapshots with point-in-time restore.  
    📦 **Deliverables & Scope**:  
    - `storageclass.yaml` with `allowVolumeExpansion: true` and reclaim policies (`Delete`/`Retain`).  
    - `volume_snapshot_class.yaml` and `volumesnapshot.yaml`: CSI snapshot manifests.  
    - `data_state_app.yaml`: Stateful workload continuously appending timestamped data to `/data`.  
    - `snapshot_restore_pipeline.sh`: Script creating a snapshot, modifying live state, creating a new PVC from the snapshot dataSource, and verifying data restoration to the snapshot point.  
    🏗️ **Infrastructure**: Local (K3d / Kind with CSI HostPath or K3s local-path with snapshotter CRDs)  
    🧪 **Testing**: Run `snapshot_restore_pipeline.sh`; write data, trigger a VolumeSnapshot, modify the volume, restore to a new PVC, and assert exact point-in-time data parity.  
    🔹 [Project directory](04-orchestration/18-csi-volume-expansion-snapshots)

19. **Next-Generation Traffic Routing with Kubernetes Gateway API**  
    🔹 **Goal & Context**: Modernize Kubernetes ingress networking by implementing the Kubernetes Gateway API specification (replacing legacy Ingress) using Envoy Gateway or Traefik, configuring `GatewayClass`, `Gateway`, `HTTPRoute`, path rewriting, header routing, and weighted traffic splits.  
    📦 **Deliverables & Scope**:  
    - Gateway API CRD manifests: `gateway.yaml` and `http_routes.yaml` managing multi-service routing (`/api/v1` vs `/api/v2`), header-based routing (`x-canary: true`), and response header transformations.  
    - 2 backend microservices with distinct versions.  
    - `gateway_traffic_test.sh`: Automated test suite testing routing policies, URL rewrites, and 80/20 traffic weight splits.  
    🏗️ **Infrastructure**: Local (K3s / K3d / Kind with Gateway API CRDs and Envoy Gateway / Traefik)  
    🧪 **Testing**: Execute `gateway_traffic_test.sh`; verify that requests route according to HTTPRoute rules, header-based canary matching directs traffic cleanly, and custom response headers are injected by the Gateway.  
    🔹 [Project directory](04-orchestration/19-kubernetes-gateway-api-traffic-routing)

20. **Application Lifecycle: Init Containers, Lifecycle Hooks, and Pod Disruption Budgets**  
    🔹 **Goal & Context**: Master advanced Kubernetes pod lifecycle management by implementing `initContainers` for dependency checking and database schema migrations, `postStart` and `preStop` lifecycle hooks for graceful connection draining, and `PodDisruptionBudget` (PDB) to ensure high availability during cluster upgrades and node drains.  
    📦 **Deliverables & Scope**:  
    - `lifecycle_deployment.yaml`: Deployment featuring init containers (waiting for DB TCP availability), `preStop` hook executing `sleep 15` and graceful shutdown script, and `terminationGracePeriodSeconds: 30`.  
    - `pdb.yaml`: `PodDisruptionBudget` enforcing `minAvailable: 2` (or `maxUnavailable: 1`).  
    - `node_drain_simulation.sh`: Script initiating `kubectl drain` on worker nodes while firing continuous traffic to verify zero dropped requests during voluntary disruptions.  
    🏗️ **Infrastructure**: Local (Multi-node K3d / Kind cluster)  
    🧪 **Testing**: Execute `node_drain_simulation.sh`; verify that the init container gates pod startup until database dependency is green, the `preStop` hook drains inflight connections cleanly, and PDB prevents draining if minimum availability threshold is breached.  
    🔹 [Project directory](04-orchestration/20-app-lifecycle-hooks-pdb-graceful-shutdown)

---

## 05. CI/CD Pipelines

1. **GitHub Actions Matrix Lint and Test Workflow**  
   🔹 **Goal & Context**: Create a scalable GitHub Actions CI workflow that runs static code analysis, linting, and unit tests across multiple language runtimes and operating systems in parallel.  
   📦 **Deliverables & Scope**:  
   - `.github/workflows/ci.yml`: Workflow with build matrix (`node: [18, 20, 22]` or `go: [1.21, 1.22]`), dependency caching (`actions/cache`), and artifact upload.  
   - Sample multi-file application with linter configuration and unit test suite.  
   - `local_ci_test.sh`: Script running the workflow locally using `act`.  
   🏗️ **Infrastructure**: Cloud (GitHub Actions Free Tier - 2,000 min/month) or Local (Act CLI with OrbStack / Docker)  
   🧪 **Testing**: Push a pull request (or run `act`); verify that all matrix jobs execute in parallel, pass lint/test checks, and generate code coverage reports.  
   🔹 [Project directory](05-ci-cd/01-github-actions-lint-test-workflow)

2. **Multi-Arch Docker Build and Push Pipeline**  
   🔹 **Goal & Context**: Construct an automated CI pipeline that builds multi-architecture Docker images (`linux/amd64` and `linux/arm64`), generates semantic tags, and securely pushes images to GitHub Container Registry (GHCR) using OIDC.  
   📦 **Deliverables & Scope**:  
   - `.github/workflows/docker_publish.yml`: Workflow using `docker/setup-buildx-action` and `docker/metadata-action` with OIDC authentication.  
   - Sample containerized microservice with multi-stage Dockerfile.  
   - Image pull and signature verification script.  
   🏗️ **Infrastructure**: Cloud (GitHub Actions + GHCR Free Tier)  
   🧪 **Testing**: Push a Git tag (e.g. `v1.0.0`); verify that GHCR receives the multi-arch image digest with corresponding semantic version and commit SHA tags.  
   🔹 [Project directory](05-ci-cd/02-multi-arch-docker-build-push-pipeline)

3. **Semantic Release and Automated Changelog**  
   🔹 **Goal & Context**: Automate software release management by parsing Conventional Commits (`feat:`, `fix:`, `BREAKING CHANGE:`), calculating the next semantic version, updating `CHANGELOG.md`, and creating GitHub Releases.  
   📦 **Deliverables & Scope**:  
   - `.releaserc.json`: Semantic Release configuration defining commit analyzer plugins, changelog generator, and GitHub release publisher.  
   - `.github/workflows/release.yml`: Release automation workflow.  
   - `simulate_commits.sh`: Script generating mock commit sequences to test patch, minor, and major version increments.  
   🏗️ **Infrastructure**: Cloud (GitHub Actions Free Tier)  
   🧪 **Testing**: Execute `simulate_commits.sh`; push commits to main branch and verify that the workflow automatically creates release tags and publishes release notes.  
   🔹 [Project directory](05-ci-cd/03-semantic-release-automated-changelog)

4. **Multi-Stage Security Scanning Pipeline**  
   🔹 **Goal & Context**: Implement Shift-Left security in CI/CD by embedding automated security scanners: Trivy (container CVEs), Gitleaks (hardcoded secrets), and Semgrep (Static Application Security Testing).  
   📦 **Deliverables & Scope**:  
   - `.github/workflows/security.yml`: Workflow running security scanners and failing builds on critical vulnerabilities.  
   - `test_fixtures/`: Sample code repository containing intentional dummy vulnerabilities (leaked token, outdated package, SQL injection pattern).  
   - `security_report_parser.py`: Script aggregating scan outputs into SARIF reports.  
   🏗️ **Infrastructure**: Cloud (GitHub Actions Free Tier) or Local (OrbStack / Docker running Trivy & Semgrep)  
   🧪 **Testing**: Run the security pipeline against test fixtures; verify that Gitleaks and Trivy detect intentional flaws, block PR merge, and output actionable reports.  
   🔹 [Project directory](05-ci-cd/04-multi-stage-security-scanning-pipeline)

5. **GitLab CI Multi-Environment Delivery Pipeline**  
   🔹 **Goal & Context**: Build an enterprise delivery pipeline in GitLab CI (`.gitlab-ci.yml`) managing stages for build, automated testing, staging auto-deployment, and manual-gated production deployment.  
   📦 **Deliverables & Scope**:  
   - `.gitlab-ci.yml`: Pipeline defining stages (`build`, `test`, `deploy-staging`, `deploy-prod`), environment URL tracking, artifacts, and manual approval triggers.  
   - `deploy_mock.sh`: Deployment script simulating zero-downtime deployment to staging and production targets.  
   🏗️ **Infrastructure**: Cloud (GitLab.com Free Tier) or Local (GitLab Runner in OrbStack / Docker)  
   🧪 **Testing**: Trigger a pipeline execution; verify that staging deploys automatically, environment URLs are registered, and production deployment waits for manual operator approval.  
   🔹 [Project directory](05-ci-cd/05-gitlab-ci-multi-environment-pipeline)

6. **GitOps Continuous Delivery with ArgoCD**  
   🔹 **Goal & Context**: Establish a GitOps deployment workflow where a Kubernetes cluster automatically synchronizes its state with a Git repository using ArgoCD.  
   📦 **Deliverables & Scope**:  
   - `argocd_app.yaml`: ArgoCD Application manifest pointing to a Git repository containing Kubernetes manifests.  
   - `config_repo/`: Git repository containing Deployment, Service, and Ingress manifests.  
   - `gitops_sync_test.sh`: Script committing an image tag update to the config repository and measuring ArgoCD reconciliation speed.  
   🏗️ **Infrastructure**: Local (K3s / K3d with ArgoCD) or Cloud (GCP GKE / AWS EKS Free Tier credits)  
   🧪 **Testing**: Execute `gitops_sync_test.sh`; verify that ArgoCD detects the Git commit, marks the application as `OutOfSync`, and synchronizes the cluster within 60 seconds.  
   🔹 [Project directory](05-ci-cd/06-gitops-cd-argocd)

7. **Jenkins Declarative Pipeline with Shared Libraries**  
   🔹 **Goal & Context**: Build an enterprise Jenkins CI pipeline utilizing reusable Groovy Shared Libraries, dynamic Docker agent provisioning, and credential masking.  
   📦 **Deliverables & Scope**:  
   - `Jenkinsfile`: Declarative pipeline invoking shared library steps (`buildApp()`, `runTests()`, `notifySlack()`).  
   - `vars/standardPipeline.groovy`: Reusable Groovy Shared Library code.  
   - `docker-compose.yml`: Jenkins controller and Docker-in-Docker agent test environment.  
   🏗️ **Infrastructure**: Local (Jenkins Controller & Docker Agent running in OrbStack / Docker Compose)  
   🧪 **Testing**: Execute the pipeline in Jenkins; verify that ephemeral Docker agents spawn dynamically, shared steps execute cleanly, and credentials remain masked in console logs.  
   🔹 [Project directory](05-ci-cd/07-jenkins-declarative-pipeline-shared-libraries)

8. **Ephemeral Preview Environments per Pull Request**  
   🔹 **Goal & Context**: Automatically provision isolated preview environments on Kubernetes for every pull request with unique subdomains (`pr-123.preview.local`), and destroy them when the PR is merged or closed.  
   📦 **Deliverables & Scope**:  
   - `.github/workflows/preview_env.yml`: Workflow creating an ephemeral namespace, deploying application Helm chart, and posting preview URL to PR comments.  
   - Cleanup workflow triggered on PR close event.  
   - `test_pr_lifecycle.sh`: Script simulating PR open, update, and close events.  
   🏗️ **Infrastructure**: Local (K3s / K3d + GitHub Actions runner / webhook) or Cloud (AWS EKS / GCP GKE)  
   🧪 **Testing**: Run `test_pr_lifecycle.sh`; verify namespace creation and accessible preview URL upon PR opening, and confirm complete resource teardown upon PR close.  
   🔹 [Project directory](05-ci-cd/08-ephemeral-preview-environments-pr)

9. **ChatOps Slack Deployment Bot**  
   🔹 **Goal & Context**: Enable developers and operators to trigger deployments, check environment statuses, and perform rollbacks directly from Slack or Discord via slash commands with RBAC authorization.  
   📦 **Deliverables & Scope**:  
   - `chatops_bot.go` / `chatops_bot.py`: Webhook server handling Slack slash commands (`/deploy <app> <env>`, `/rollback <app>`), verifying user permissions, and triggering CI pipelines.  
   - `mock_chatops_client.sh`: Test script sending signed mock Slack payload requests.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker + Slack API Sandbox) or Cloud (AWS Lambda Free Tier)  
   🧪 **Testing**: Send a simulated `/deploy api staging` command via `mock_chatops_client.sh`; verify that the bot checks authorization, dispatches the deployment, and returns status updates.  
   🔹 [Project directory](05-ci-cd/09-chatops-slack-deployment-bot)

10. **Multi-Region Blue-Green Deployment Orchestrator**  
    🔹 **Goal & Context**: Build an automated zero-downtime Blue-Green deployment orchestrator that manages parallel environments across multiple clusters and switches traffic instantaneously upon passing health checks.  
    📦 **Deliverables & Scope**:  
    - `blue_green_orchestrator.py` / `blue_green_orchestrator.go`: CLI tool managing deployment to idle environment (Green), running automated smoke tests, and updating ingress/DNS pointers.  
    - Blue and Green environment manifests + automated smoke test suite.  
    - Continuous load generator measuring downtime during traffic switchover.  
    🏗️ **Infrastructure**: Local (Multi-cluster K3d / Kind setup) or Cloud (AWS / GCP multi-region Free Tier)  
    🧪 **Testing**: Execute a blue-green rollout under active load; assert zero HTTP connection drops and verify instant rollback if smoke tests fail on the green environment.  
   🔹 [Project directory](05-ci-cd/10-multi-region-blue-green-orchestrator)

---

## 06. Infrastructure as Code (IaC)

1. **Terraform Local Docker Provider Infrastructure**  
   🔹 **Goal & Context**: Master Terraform fundamentals (providers, resources, variables, outputs, and local state management) by provisioning local container networks, volumes, and services using the Docker provider.  
   📦 **Deliverables & Scope**:  
   - `main.tf`, `variables.tf`, `outputs.tf`: Terraform code defining custom Docker bridge networks, persistent volumes, and Nginx containers.  
   - `terraform_lifecycle_test.sh`: Script running `terraform init`, `plan`, `apply`, and verifying running containers.  
   🏗️ **Infrastructure**: Local (Terraform / OpenTofu + OrbStack / Docker)  
   🧪 **Testing**: Execute `terraform_lifecycle_test.sh`; verify container creation and inspect `terraform.tfstate` to understand state tracking.  
   🔹 [Project directory](06-infrastructure-as-code/01-terraform-local-docker-infrastructure)

2. **Modular High-Availability AWS VPC**  
   🔹 **Goal & Context**: Write a reusable, production-ready Terraform module provisioning a highly available AWS VPC across 3 Availability Zones with public/private subnets, Internet Gateways, NAT Gateways, and route tables.  
   📦 **Deliverables & Scope**:  
   - `modules/vpc/`: Reusable VPC module (`main.tf`, `variables.tf`, `outputs.tf`).  
   - `environments/dev/` and `environments/prod/`: Root modules consuming the VPC module.  
   - `tflint` and `terraform-docs` automated validation scripts.  
   🏗️ **Infrastructure**: Local (LocalStack Community Free / `tflocal`) or Cloud (AWS Free Tier)  
   🧪 **Testing**: Run `tflint` and `terraform plan` against LocalStack/AWS; verify output subnet CIDRs, routing table associations, and zero hardcoded parameters.  
   🔹 [Project directory](06-infrastructure-as-code/02-modular-aws-vpc-terraform)

3. **Remote State Locking with S3 and DynamoDB**  
   🔹 **Goal & Context**: Configure a team-safe Terraform remote backend using AWS S3 bucket (with versioning and encryption) and a DynamoDB state locking table to prevent concurrent execution conflicts.  
   📦 **Deliverables & Scope**:  
   - `backend_bootstrap/`: Terraform script to provision the S3 backend bucket and DynamoDB lock table.  
   - `backend.tf`: Configuration block enabling the remote S3 backend.  
   - `test_state_lock.sh`: Script attempting simultaneous `terraform apply` executions from two terminals to test lock acquisition.  
   🏗️ **Infrastructure**: Local (LocalStack S3 & DynamoDB emulators) or Cloud (AWS S3 & DynamoDB Free Tier)  
   🧪 **Testing**: Execute `test_state_lock.sh`; confirm that the second apply process is blocked by the DynamoDB lock and terminates with an error.  
   🔹 [Project directory](06-infrastructure-as-code/03-remote-state-locking-s3-dynamodb)

4. **Ansible Baseline Server Hardening Playbook**  
   🔹 **Goal & Context**: Automate Linux operating system hardening against CIS benchmarks using modular Ansible roles (SSH hardening, UFW firewall, fail2ban, automatic security updates).  
   📦 **Deliverables & Scope**:  
   - `site.yml`, `roles/hardening/` (`tasks/`, `handlers/`, `defaults/`, `templates/`).  
   - `inventory.ini`: Inventory file targeting test Linux VMs.  
   - `ansible_audit.sh`: Script testing playbook idempotency and verifying security configurations.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM / Multipass Ubuntu instance) or Cloud (AWS EC2 t2.micro Free Tier)  
   🧪 **Testing**: Run `ansible-playbook -i inventory.ini site.yml`; re-run to confirm zero changes (`changed=0`), and verify that root SSH login is disabled.  
   🔹 [Project directory](06-infrastructure-as-code/04-ansible-server-baseline-hardening)

5. **OpenTofu Multi-Environment Workspaces**  
   🔹 **Goal & Context**: Manage multi-environment infrastructure (`dev`, `staging`, `prod`) using OpenTofu workspaces and environment-specific `.tfvars` files to enforce environment isolation.  
   📦 **Deliverables & Scope**:  
   - OpenTofu infrastructure files utilizing `terraform.workspace` expressions for dynamic resource naming and sizing.  
   - `dev.tfvars`, `staging.tfvars`, and `prod.tfvars` configuration files.  
   - `workspace_deployer.sh`: Script switching workspaces and validating plans.  
   🏗️ **Infrastructure**: Local (LocalStack) or Cloud (AWS / GCP Free Tier)  
   🧪 **Testing**: Execute `workspace_deployer.sh`; switch between `dev` and `prod` workspaces, and confirm that `prod` plans allocate production-sized instances and tags.  
   🔹 [Project directory](06-infrastructure-as-code/05-opentofu-multi-environment-workspaces)

6. **Ansible Dynamic Inventory for Cloud Fleets**  
   🔹 **Goal & Context**: Automate configuration management across dynamic cloud server fleets using Ansible dynamic inventory plugins without maintaining static IP lists.  
   📦 **Deliverables & Scope**:  
   - `aws_ec2.yml` / `docker_inventory.py`: Dynamic inventory configuration grouping hosts by tags (`Environment=production`, `Role=web`).  
   - Rolling update playbook applying application patches with `serial: 1` and pre/post health checks.  
   - Mock fleet setup script.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VMs / Docker containers) or Cloud (AWS EC2 Free Tier)  
   🧪 **Testing**: Provision test instances with specific tags; run `ansible-inventory --graph` and execute the rolling update playbook targeting dynamic host groups.  
   🔹 [Project directory](06-infrastructure-as-code/06-ansible-dynamic-inventory-cloud)

7. **DRY Multi-Account Architecture with Terragrunt**  
   🔹 **Goal & Context**: Eliminate IaC code duplication across multiple AWS accounts and regions by implementing a DRY Terragrunt architecture with root inheritance and remote state generation.  
   📦 **Deliverables & Scope**:  
   - Root `terragrunt.hcl` generating backend and provider configurations.  
   - Multi-environment directory hierarchy (`prod/us-east-1/vpc`, `staging/us-east-1/vpc`).  
   - `terragrunt_run_all_test.sh`: Script executing `terragrunt run-all plan`.  
   🏗️ **Infrastructure**: Local (LocalStack) or Cloud (AWS Free Tier)  
   🧪 **Testing**: Run `terragrunt_run_all_test.sh`; verify that Terragrunt generates remote state backends dynamically and plans all modules in proper dependency order.  
   🔹 [Project directory](06-infrastructure-as-code/07-terragrunt-dry-architecture)

8. **Pulumi TypeScript Kubernetes Infrastructure**  
   🔹 **Goal & Context**: Define and provision Kubernetes and cloud infrastructure using TypeScript and Pulumi, leveraging type safety, loops, conditionals, and unit testing.  
   📦 **Deliverables & Scope**:  
   - `index.ts`, `Pulumi.yaml`, `package.json`: Pulumi TypeScript project provisioning namespaces, deployments, and configmaps.  
   - Unit test suite using Pulumi Mocks to validate infrastructure rules before deployment.  
   - `pulumi_test.sh`: Script running preview, up, and stack output tests.  
   🏗️ **Infrastructure**: Local (K3s / K3d + Pulumi Local State Backend)  
   🧪 **Testing**: Execute `npm test` to run unit tests, followed by `pulumi up --yes`; verify created resources via `kubectl` and assert stack outputs.  
   🔹 [Project directory](06-infrastructure-as-code/08-pulumi-typescript-k8s-infrastructure)

9. **Automated Terraform Drift Detection and Alerting**  
   🔹 **Goal & Context**: Detect and remediate out-of-band infrastructure changes by building an automated drift detection tool that runs on a schedule and reports diffs to Slack.  
   📦 **Deliverables & Scope**:  
   - `drift_detector.sh`: Script executing `terraform plan -detailed-exitcode` and parsing plan output JSON for unmanaged changes.  
   - `slack_notifier.py`: Webhook script formatting drift diffs into Slack alerts.  
   - `inject_drift.sh`: Script making intentional out-of-band cloud modifications to simulate drift.  
   🏗️ **Infrastructure**: Local (LocalStack + Cron in OrbStack / GitHub Actions) or Cloud (AWS Free Tier)  
   🧪 **Testing**: Run `inject_drift.sh` to modify a security group rule out-of-band; execute `drift_detector.sh` and verify that the drift is detected and alert posted.  
   🔹 [Project directory](06-infrastructure-as-code/09-terraform-drift-detection-alerting)

10. **Self-Service Cloud Sandbox Provisioning Portal**  
    🔹 **Goal & Context**: Build an internal developer platform (IDP) self-service API that allows developers to request ephemeral cloud sandboxes from IaC templates with automatic TTL expiration.  
    📦 **Deliverables & Scope**:  
    - FastAPI / Go REST API wrapping Terraform CLI (`POST /sandboxes`, `DELETE /sandboxes/{id}`).  
    - Background worker monitoring sandbox expiration timers and executing automated `terraform destroy`.  
    - `sandbox_client_test.py`: Integration test suite requesting and verifying sandbox lifecycles.  
    🏗️ **Infrastructure**: Local (FastAPI / Go backend in OrbStack + LocalStack / Docker)  
    🧪 **Testing**: Send an API request to provision a sandbox with a 2-minute TTL; verify cloud resource creation and confirm automated destruction upon TTL timeout.  
    🔹 [Project directory](06-infrastructure-as-code/10-self-service-cloud-sandbox-portal)

---

## 07. Cloud Providers & Serverless

1. **AWS IAM Least-Privilege and Role Boundaries**  
   🔹 **Goal & Context**: Architect a least-privilege IAM security model defining granular permission boundaries, MFA-enforced role assumption, and Service Control Policies (SCPs).  
   📦 **Deliverables & Scope**:  
   - IAM policy JSON documents and Terraform IAM manifests for Developer, Read-Only, and CI/CD roles.  
   - `iam_policy_evaluator.py`: Test script using AWS IAM Policy Simulator API to assert permitted vs denied actions across S3, EC2, and KMS.  
   🏗️ **Infrastructure**: Cloud (AWS Free Tier / IAM Policy Simulator) or Local (LocalStack Pro/Community)  
   🧪 **Testing**: Run `iam_policy_evaluator.py`; verify that Developer roles cannot delete S3 buckets without MFA and CI/CD roles cannot modify IAM policies.  
   🔹 [Project directory](07-cloud-providers/01-aws-iam-least-privilege-policies)

2. **Secure Static Web Hosting with S3 and CloudFront**  
   🔹 **Goal & Context**: Deploy a high-performance, secure static website on AWS using private S3 storage, CloudFront CDN, Origin Access Control (OAC), ACM TLS certificates, and security headers.  
   📦 **Deliverables & Scope**:  
   - Terraform / CloudFormation code provisioning private S3 bucket, CloudFront distribution with OAC, and CloudFront Functions injecting security headers.  
   - Sample single-page static web application.  
   - `verify_cdn_security.sh`: Automated security header and access control audit script.  
   🏗️ **Infrastructure**: Cloud (AWS Free Tier: S3 + CloudFront 1TB/month data transfer Free Tier)  
   🧪 **Testing**: Request the site via CloudFront domain; verify HTTPS certificate, security headers (`X-Frame-Options`, `CSP`), and confirm that direct S3 access returns 403 Forbidden.  
   🔹 [Project directory](07-cloud-providers/02-s3-cloudfront-static-hosting)

3. **Event-Driven Serverless Pipeline with Lambda and SQS**  
   🔹 **Goal & Context**: Build a resilient, asynchronous event processing pipeline using AWS Lambda (Python/Go), SQS FIFO queues, and Dead Letter Queues (DLQ) with automatic retries.  
   📦 **Deliverables & Scope**:  
   - Lambda handler code (`index.py` / `main.go`) processing message batches with error handling.  
   - Terraform configuration provisioning SQS FIFO queues, DLQs, CloudWatch alarms, and Lambda event source mappings.  
   - `message_producer.py`: Script publishing 100 valid and malformed messages to test processing and DLQ routing.  
   🏗️ **Infrastructure**: Local (LocalStack SQS & Lambda) or Cloud (AWS Lambda & SQS Free Tier - 1M free requests/month)  
   🧪 **Testing**: Execute `message_producer.py`; verify that valid messages process successfully while poisoned messages route to the DLQ after 3 failed attempts.  
   🔹 [Project directory](07-cloud-providers/03-serverless-pipeline-lambda-sqs)

4. **CloudWatch Alarms and SNS Incident Routing**  
   🔹 **Goal & Context**: Build a comprehensive cloud monitoring infrastructure configuring composite CloudWatch alarms, metric filters, and SNS topic routing to email and webhook endpoints.  
   📦 **Deliverables & Scope**:  
   - Terraform manifests defining CloudWatch alarms (CPU > 80%, HTTP 5xx rate, disk space) and SNS topic subscriptions.  
   - `simulate_cloud_incident.sh`: Script using AWS CLI `put-metric-data` to inject synthetic metric anomalies.  
   🏗️ **Infrastructure**: Local (LocalStack CloudWatch & SNS) or Cloud (AWS CloudWatch & SNS Free Tier)  
   🧪 **Testing**: Run `simulate_cloud_incident.sh`; observe alarm transition from `OK` to `ALARM` and verify notification payload delivery to the SNS webhook.  
   🔹 [Project directory](07-cloud-providers/04-cloudwatch-alarms-sns-routing)

5. **Multi-VPC Networking with Transit Gateway**  
   🔹 **Goal & Context**: Connect multiple isolated AWS VPCs (Production, Staging, Shared Services) using AWS Transit Gateway or VPC Peering with non-overlapping CIDRs and strict routing tables.  
   📦 **Deliverables & Scope**:  
   - IaC manifests provisioning 3 distinct VPCs, route tables, and Transit Gateway attachments.  
   - `vpc_reachability_test.sh`: Script verifying network connectivity between authorized subnets and confirming complete packet drops between isolated environments.  
   🏗️ **Infrastructure**: Cloud (AWS Free Tier - VPC Peering without NAT Gateway charges) or Local (LocalStack)  
   🧪 **Testing**: Run `vpc_reachability_test.sh`; confirm successful communication between Staging and Shared Services, and assert that Production cannot communicate with Staging.  
   🔹 [Project directory](07-cloud-providers/05-multi-vpc-transit-gateway)

6. **High-Availability Auto Scaling EC2 Fleet behind ALB**  
   🔹 **Goal & Context**: Deploy a resilient, auto-scaling web application fleet on AWS EC2 across multiple Availability Zones behind an Application Load Balancer with dynamic scaling policies.  
   📦 **Deliverables & Scope**:  
   - Terraform code provisioning Launch Template, Auto Scaling Group (ASG), target groups, dynamic CPU scaling policies, and ALB.  
   - User data initialization script bootstrapping a web server.  
   - `load_test_asg.sh`: Stress testing script driving traffic to trigger scale-out events.  
   🏗️ **Infrastructure**: Cloud (AWS Free Tier: 750 hrs/month t2.micro / t3.micro ASG + ALB)  
   🧪 **Testing**: Run `load_test_asg.sh`; observe ASG scaling from 1 to 3 instances and verify traffic distribution across all active instances.  
   🔹 [Project directory](07-cloud-providers/06-auto-scaling-ec2-alb-fleet)

7. **GCP Cloud Run Scalable Microservice**  
   🔹 **Goal & Context**: Deploy containerized microservices to Google Cloud Run with fine-grained concurrency tuning, minimum/maximum instance scaling, Secret Manager integration, and custom domain mapping.  
   📦 **Deliverables & Scope**:  
   - Containerized Go/Python API application.  
   - Terraform / `gcloud` deployment configuration with IAM service accounts and secret bindings.  
   - `benchmark_cloud_run.sh`: Benchmarking script measuring cold start latency and concurrent throughput.  
   🏗️ **Infrastructure**: Cloud (GCP Free Tier: Cloud Run 2M requests/month free) or Local (K3s with Knative / Google Cloud Run Emulator)  
   🧪 **Testing**: Execute `benchmark_cloud_run.sh`; verify that the service scales from 0 to multiple instances under load and measures cold start response times.  
   🔹 [Project directory](07-cloud-providers/07-gcp-cloud-run-microservice)

8. **Azure Functions Event Grid Blob Processor**  
   🔹 **Goal & Context**: Build a serverless event-driven processing pipeline on Microsoft Azure where Blob Storage uploads trigger Azure Functions via Event Grid to extract metadata and store it in Cosmos DB.  
   📦 **Deliverables & Scope**:  
   - Azure Function code (Python/TypeScript) with Event Grid trigger bindings and Cosmos DB output bindings.  
   - Bicep / Terraform IaC configuration provisioning Azure Storage, Function App, and Cosmos DB.  
   - `upload_test_blobs.py`: Script uploading test images and checking Cosmos DB records.  
   🏗️ **Infrastructure**: Cloud (Azure Free Tier: Functions 1M executions/mo + Cosmos DB Free Tier) or Local (Azurite Storage Emulator + Azure Functions Core Tools)  
   🧪 **Testing**: Run `upload_test_blobs.py`; upload a test image to Azure Blob Storage and verify that the Azure Function processes the event and writes metadata to Cosmos DB.  
   🔹 [Project directory](07-cloud-providers/08-azure-functions-eventgrid-processor)

9. **Cloud Cost Governance and Tag Compliance Engine**  
   🔹 **Goal & Context**: Implement automated FinOps governance using Cloud Custodian or AWS Lambda to continuously audit cloud resources for mandatory billing tags (`Environment`, `Owner`, `CostCenter`) and enforce compliance.  
   📦 **Deliverables & Scope**:  
   - Cloud Custodian policy YAML / Python Lambda auditor scanning EC2, S3, and RDS resources.  
   - Compliance reporting script sending daily summaries to Slack.  
   - `provision_untagged_resources.sh`: Test script provisioning compliant and non-compliant resources.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker running Cloud Custodian) or Cloud (AWS Lambda Free Tier)  
   🧪 **Testing**: Provision untagged resources with `provision_untagged_resources.sh`; run the governance engine and verify that non-compliant resources are tagged for termination and alerts fired.  
   🔹 [Project directory](07-cloud-providers/09-cloud-cost-tagging-governance-engine)

10. **Multi-Region Disaster Recovery with Route 53 Failover**  
    🔹 **Goal & Context**: Implement an active-passive multi-region disaster recovery architecture on AWS using Route 53 DNS health checks, S3 cross-region replication, and automated failover routing.  
    📦 **Deliverables & Scope**:  
    - Terraform code deploying Primary Region (`us-east-1`) and Secondary DR Region (`us-west-2`) infrastructure.  
    - Route 53 Failover Routing policies and endpoint health check configuration.  
    - `dr_failover_test.sh`: Script simulating primary region outage and measuring DNS failover recovery time.  
    🏗️ **Infrastructure**: Cloud (AWS Free Tier: Route 53 DNS Failover + S3 Cross-Region Replication)  
    🧪 **Testing**: Run `dr_failover_test.sh` to fail the primary endpoint; verify that Route 53 detects the failure within 60 seconds and redirects traffic to the DR region.  
    🔹 [Project directory](07-cloud-providers/10-multi-region-disaster-recovery-route53)

---

## 08. Monitoring & Observability

1. **Prometheus Node Exporter Monitoring Stack**  
   🔹 **Goal & Context**: Deploy and configure a core Prometheus monitoring server scraping host and container hardware metrics from Node Exporter with customized scrape intervals and retention policies.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml`: Stack running Prometheus and Node Exporter.  
   - `prometheus.yml`: Scrape configuration defining jobs, scrape intervals, and evaluation rules.  
   - `promql_validation.py`: Script querying Prometheus API for key host metrics (CPU, RAM, disk I/O).  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Prometheus & Node Exporter)  
   🧪 **Testing**: Start the stack, run `promql_validation.py`, and verify that Prometheus scrapes Node Exporter successfully and returns valid time-series data.  
   🔹 [Project directory](08-observability-and-monitoring/01-prometheus-node-exporter-stack)

2. **Application RED and USE Metrics Instrumentation**  
   🔹 **Goal & Context**: Instrument a web microservice with official Prometheus client libraries, exposing RED (Rate, Errors, Duration) and USE (Utilization, Saturation, Errors) metrics at `/metrics`.  
   📦 **Deliverables & Scope**:  
   - Web application (Go/Python/Node) instrumented with Prometheus Counter (requests), Histogram (latency), and Gauge (active connections).  
   - `traffic_simulator.py`: Script generating varied traffic patterns (steady load, latency spikes, error bursts).  
   - PromQL query test suite computing p95/p99 latencies and error percentages.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose)  
   🧪 **Testing**: Run `traffic_simulator.py`; query Prometheus for `rate(http_requests_total[1m])` and `histogram_quantile(0.99, ...)` and verify accurate computation.  
   🔹 [Project directory](08-observability-and-monitoring/02-application-metrics-instrumentation)

3. **Grafana Dashboards as Code Provisioning**  
   🔹 **Goal & Context**: Build and provision production-grade Grafana monitoring dashboards declaratively using JSON models and YAML provider configs without manual UI setup.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml`: Grafana container with automated provisioning volumes.  
   - Provisioning YAML configs (`datasources.yml`, `dashboards.yml`) and dashboard JSON model files featuring RED/USE panels and threshold alerts.  
   - `dashboard_smoke_test.sh`: Script verifying dashboard API availability.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Grafana)  
   🧪 **Testing**: Start Grafana; navigate to the web UI (`:3000`) and confirm that dashboards load automatically from disk and render live Prometheus metric data.  
   🔹 [Project directory](08-observability-and-monitoring/03-grafana-dashboards-as-code)

4. **Prometheus Alertmanager Routing and Slack Notifications**  
   🔹 **Goal & Context**: Construct an alerting pipeline with Prometheus alert rules, Alertmanager routing trees, alert grouping, inhibition rules, deduplication, and Slack/Discord webhook notifications.  
   📦 **Deliverables & Scope**:  
   - `alerts.yml`: Prometheus alerting rules detecting high error rates, slow response times, and service downtime.  
   - `alertmanager.yml`: Alertmanager routing configuration with fallback receivers and inhibition rules.  
   - `trigger_synthetic_alert.sh`: Script triggering threshold breaches to verify alert delivery.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose + Slack Webhook Sandbox)  
   🧪 **Testing**: Execute `trigger_synthetic_alert.sh`; verify that Prometheus transitions alert state to `FIRING`, Alertmanager deduplicates events, and formatted notifications arrive in Slack.  
   🔹 [Project directory](08-observability-and-monitoring/04-alertmanager-routing-slack)

5. **Blackbox Exporter Endpoint Uptime Probing**  
   🔹 **Goal & Context**: Set up synthetic external uptime monitoring using Prometheus Blackbox Exporter to probe HTTP/HTTPS, DNS, TCP, and ICMP endpoints, tracking SSL cert expiration and network latency.  
   📦 **Deliverables & Scope**:  
   - `blackbox.yml`: Blackbox exporter configuration defining `http_2xx`, `dns_query`, and `tcp_connect` probe modules.  
   - Prometheus scrape config targeting public and internal endpoints.  
   - `mock_target_endpoints/`: Test HTTP endpoints (healthy, slow, failing).  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Blackbox Exporter)  
   🧪 **Testing**: Start the stack; query `probe_success` and `probe_duration_seconds` in Prometheus and verify accurate uptime and response latency tracking.  
   🔹 [Project directory](08-observability-and-monitoring/05-blackbox-exporter-uptime-probing)

6. **Distributed Tracing with OpenTelemetry and Jaeger**  
   🔹 **Goal & Context**: Implement distributed tracing across a multi-tier microservice architecture using OpenTelemetry SDKs, propagating W3C trace context across HTTP boundaries, and visualizing traces in Jaeger.  
   📦 **Deliverables & Scope**:  
   - 3 microservices (Frontend -> Auth -> Payment) instrumented with OpenTelemetry SDK.  
   - `docker-compose.yml` running microservices and Jaeger All-in-One.  
   - `trace_verification.py`: Script executing end-to-end user transactions and validating span relationships via Jaeger API.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Jaeger all-in-one)  
   🧪 **Testing**: Send transactions via `trace_verification.py`; open Jaeger UI (`:16686`) and verify that unified traces link spans across all 3 microservices with detailed timing breakdowns.  
   🔹 [Project directory](08-observability-and-monitoring/06-opentelemetry-distributed-tracing-jaeger)

7. **OpenTelemetry Collector Telemetry Pipeline**  
   🔹 **Goal & Context**: Deploy an OpenTelemetry Collector to receive, process, batch, filter, and export metrics, logs, and traces to multiple backend destinations (Prometheus, Jaeger, Tempo).  
   📦 **Deliverables & Scope**:  
   - `otel-collector-config.yaml`: Configuration defining receivers (OTLP gRPC/HTTP), processors (`batch`, `memory_limiter`, `attributes`), and exporters.  
   - Sample application exporting OTLP telemetry.  
   - `pipeline_health_check.sh`: Script verifying collector internal metrics and backend delivery.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with OTel Collector & Backends)  
   🧪 **Testing**: Stream telemetry through the collector; inspect collector logs and verify that processed metrics appear in Prometheus and traces appear in Jaeger.  
   🔹 [Project directory](08-observability-and-monitoring/07-opentelemetry-collector-pipeline)

8. **VictoriaMetrics Long-Term Metric Storage**  
   🔹 **Goal & Context**: Configure scalable, high-performance long-term time-series metric storage using VictoriaMetrics as a remote-write destination for Prometheus with data downsampling.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` deploying Prometheus (with `remote_write`) and VictoriaMetrics Single-Node.  
   - `benchmark_metrics_ingestion.py`: Script generating high-cardinality metric streams to measure compression ratios.  
   - Storage utilization comparison script.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with VictoriaMetrics single-node)  
   🧪 **Testing**: Ingest 1 million data points; compare disk space usage between standard Prometheus TSDB and VictoriaMetrics, confirming superior compression efficiency.  
   🔹 [Project directory](08-observability-and-monitoring/08-victoriametrics-long-term-storage)

9. **Kubernetes Observability with kube-prometheus-stack**  
   🔹 **Goal & Context**: Deploy and operate the complete Kubernetes monitoring stack using `kube-prometheus-stack` Helm chart, configuring custom `ServiceMonitor`, `PodMonitor`, and `PrometheusRule` CRDs.  
   📦 **Deliverables & Scope**:  
   - Helm `values.yaml` customizing Prometheus, Alertmanager, and Grafana Operator.  
   - Sample microservice deployment with a dedicated `ServiceMonitor` CRD.  
   - `k8s_monitoring_test.sh`: Script verifying target discovery and metric ingestion.  
   🏗️ **Infrastructure**: Local (K3s / K3d / OrbStack Kubernetes + Helm 3)  
   🧪 **Testing**: Deploy the sample app and ServiceMonitor; verify in Prometheus Operator UI that the target is automatically discovered and scraped without manual configuration.  
   🔹 [Project directory](08-observability-and-monitoring/09-kube-prometheus-stack-helm-k8s)

10. **Synthetic User Journey Monitoring with Playwright**  
    🔹 **Goal & Context**: Build an automated synthetic user journey monitoring service that runs headless Playwright browser scripts on a schedule, tests multi-step user workflows (e.g. login, checkout), and exports latency metrics to Prometheus.  
    📦 **Deliverables & Scope**:  
    - Playwright test script (TypeScript/Python) simulating user transactions and capturing step execution timings.  
    - Custom Prometheus exporter daemon exposing synthetic journey latencies and failure counters.  
    - Target e-commerce test web application.  
    🏗️ **Infrastructure**: Local (OrbStack / Docker Compose running Playwright + Prometheus client)  
    🧪 **Testing**: Execute synthetic journeys under normal and degraded network conditions; verify screenshot capture on step failure and Prometheus metric updates.  
    🔹 [Project directory](08-observability-and-monitoring/10-synthetic-journey-monitoring-playwright)

---

## 09. Centralized Logging & Log Aggregation

1. **Structured JSON Logging Framework**  
   🔹 **Goal & Context**: Implement standardized structured JSON logging across application services, ensuring all log events include timestamps, log levels, caller info, trace correlation IDs, and contextual metadata.  
   📦 **Deliverables & Scope**:  
   - Application logging library setup (Go Zap / Python Loguru / Node Winston).  
   - Sample microservice generating structured logs across various error conditions.  
   - `validate_log_schema.py`: JSON schema validator script testing log format compliance.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker container)  
   🧪 **Testing**: Run `validate_log_schema.py` against application stdout; assert that 100% of log entries conform strictly to the required JSON schema.  
   🔹 [Project directory](09-logging/01-structured-json-logging-framework)

2. **Logrotate Daemon System Policy**  
   🔹 **Goal & Context**: Write and validate system-level `logrotate` configurations managing size-based rotation, daily compression, archive retention, and non-disruptive daemon reloads (`kill -HUP`).  
   📦 **Deliverables & Scope**:  
   - `/etc/logrotate.d/custom-app` configuration file with `maxsize 50M`, `rotate 7`, and `postrotate` scripts.  
   - `continuous_log_writer.py`: Daemon continuously writing logs with open file descriptors.  
   - `test_logrotate.sh`: Script forcing log rotation and asserting zero dropped log entries.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM with logrotate daemon)  
   🧪 **Testing**: Execute `test_logrotate.sh`; verify that logs are rotated to `.1.gz`, active log writes continue uninterrupted, and expired archives are purged.  
   🔹 [Project directory](09-logging/02-logrotate-daemon-system-policy)

3. **Docker Daemon Logging Drivers and Fluentd**  
   🔹 **Goal & Context**: Configure Docker daemon logging to route container stdout/stderr streams to a centralized Fluentd log collector using the native `fluentd` logging driver.  
   📦 **Deliverables & Scope**:  
   - `daemon.json` logging configuration and `fluent.conf` receiver configuration.  
   - `docker-compose.yml` deploying Fluentd and high-volume test log containers.  
   - `log_delivery_test.sh`: Script verifying that logs stream directly to Fluentd while host container log files remain constrained.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Fluentd service)  
   🧪 **Testing**: Generate 10,000 log lines in a test container; inspect Fluentd output to verify zero log loss and confirm host disk preservation.  
   🔹 [Project directory](09-logging/03-docker-logging-drivers-fluentd)

4. **Promtail, Loki, and Grafana LogQL Pipeline**  
   🔹 **Goal & Context**: Deploy a lightweight, scalable log aggregation pipeline using Grafana Loki and Promtail, scraping container and system log files, parsing labels, and querying logs using LogQL.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` running Loki, Promtail, and Grafana.  
   - `promtail-config.yaml` with regex parsing stages and dynamic label extraction (`level`, `app`, `endpoint`).  
   - `logql_test_queries.sh`: Script querying Loki API with LogQL filter expressions.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Loki, Promtail, Grafana)  
   🧪 **Testing**: Emit error logs with custom metadata; query `{app="api"} |= "error"` via `logql_test_queries.sh` and verify sub-second search responses.  
   🔹 [Project directory](09-logging/04-promtail-loki-grafana-logql)

5. **Fluent Bit Kubernetes Log DaemonSet**  
   🔹 **Goal & Context**: Deploy Fluent Bit as a Kubernetes DaemonSet to collect container logs from `/var/log/containers/`, enrich entries with Kubernetes pod metadata, and forward logs to Loki or Elasticsearch.  
   📦 **Deliverables & Scope**:  
   - Fluent Bit Helm configuration / DaemonSet manifest (`fluent-bit.conf` with `kubernetes` filter).  
   - Sample workloads generating logs across multiple namespaces.  
   - `k8s_log_metadata_audit.sh`: Script validating enriched metadata fields (`pod_name`, `namespace_name`, `container_image`).  
   🏗️ **Infrastructure**: Local (K3s / K3d with Fluent Bit DaemonSet)  
   🧪 **Testing**: Run `k8s_log_metadata_audit.sh`; query the log backend and confirm that log entries contain accurate Kubernetes metadata tags.  
   🔹 [Project directory](09-logging/05-fluent-bit-kubernetes-daemonset)

6. **ELK Stack with Logstash Grok Parsers**  
   🔹 **Goal & Context**: Deploy the Elasticsearch, Logstash, and Kibana (ELK) stack, configuring Logstash Grok filter pipelines to parse unstructured legacy access logs into indexed, searchable fields.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` running Elasticsearch, Logstash, and Kibana.  
   - `logstash.conf` with custom Grok patterns, GeoIP enrichment, and date filters.  
   - `log_injector.py`: Script streaming raw Apache/Nginx access logs to Logstash.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Elasticsearch single-node & Kibana)  
   🧪 **Testing**: Stream raw access logs via `log_injector.py`; open Kibana (`:5601`) and verify that logs are parsed into structured fields (`client_ip`, `response_code`, `request_path`).  
   🔹 [Project directory](09-logging/06-elk-stack-logstash-grok-parsers)

7. **Vector Log Sanitization and PII Masking**  
   🔹 **Goal & Context**: Build a high-throughput telemetry transformation pipeline using Datadog Vector, performing in-flight log sanitization to redact Personally Identifiable Information (PII) like credit cards and SSNs.  
   📦 **Deliverables & Scope**:  
   - `vector.toml`: Vector pipeline configuration with VRL (Vector Remap Language) transforms for regex masking and field redaction.  
   - `pii_log_generator.py`: Test script emitting logs containing mock credit card numbers, emails, and passwords.  
   - `pii_sanitization_test.sh`: Verification script asserting zero raw PII in output sinks.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Vector pipeline)  
   🧪 **Testing**: Run `pii_sanitization_test.sh`; confirm that all sensitive fields are replaced with `[REDACTED]` before forwarding downstream.  
   🔹 [Project directory](09-logging/07-vector-log-sanitization-pii-masking)

8. **OpenSearch Index Lifecycle Management (ISM)**  
   🔹 **Goal & Context**: Configure Index State Management (ISM) policies in OpenSearch to automate index rollouts across hot, warm, and cold storage tiers and enforce scheduled retention deletion.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` running OpenSearch and OpenSearch Dashboards.  
   - ISM policy JSON document defining rollover triggers (size > 10GB or age > 7 days), read-only transitions, and retention deletion.  
   - `simulate_ism_lifecycle.py`: Script simulating index aging and verifying state transitions.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with OpenSearch single-node)  
   🧪 **Testing**: Execute `simulate_ism_lifecycle.py`; verify that indices transition from hot to warm read-only tiers and delete on schedule.  
   🔹 [Project directory](09-logging/08-opensearch-index-lifecycle-management)

9. **Log-Based Metrics Extraction and Alerting**  
   🔹 **Goal & Context**: Extract real-time numerical Prometheus metrics directly from raw unstructured log streams using Loki LogQL metric queries or Fluent Bit metric filters to trigger immediate alerts.  
   📦 **Deliverables & Scope**:  
   - Loki metric alerting rules computing `rate({app="nginx"} |= "500"[1m])`.  
   - `error_spike_injector.sh`: Script generating sudden bursts of 500 error logs.  
   - Alertmanager validation script.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Loki, Promtail, Prometheus)  
   🧪 **Testing**: Run `error_spike_injector.sh`; verify that Loki extracts the metric count, Prometheus records the anomaly, and Alertmanager fires a threshold alert.  
   🔹 [Project directory](09-logging/09-log-based-metrics-extraction-alerting)

10. **Auditd Linux Security Event Log Analysis**  
    🔹 **Goal & Context**: Configure Linux Audit Framework (`auditd`) rules to capture critical security events (unauthorized file modifications in `/etc`, privilege escalation attempts), shipping audit logs to a SIEM for analysis.  
    📦 **Deliverables & Scope**:  
    - `/etc/audit/rules.d/security.rules`: Auditd rules monitoring `execve` system calls, `/etc/passwd`, and sudoer modifications.  
    - Audit log shipper daemon and SIEM parser.  
    - `simulate_security_event.sh`: Script simulating unauthorized file writes and privilege escalations.  
    🏗️ **Infrastructure**: Local (OrbStack Linux VM with Linux Audit subsystem)  
    🧪 **Testing**: Execute `simulate_security_event.sh`; verify that `audit.log` captures the event with full user/process context and the SIEM dashboard flags the security alert.  
    🔹 [Project directory](09-logging/10-auditd-security-event-logging-analysis)

---

## 10. SRE, Reliability & Incident Response

1. **SLI, SLO, and Error Budget Calculator**  
   🔹 **Goal & Context**: Build an SRE analytics tool in Python/Go that queries Prometheus metrics over rolling 30-day windows, calculates Service Level Indicators (SLIs), Service Level Objectives (SLOs, e.g. 99.9% availability), and remaining Error Budgets.  
   📦 **Deliverables & Scope**:  
   - `slo_calculator.py` / `slo_calculator.go`: Program querying Prometheus, computing availability percentages, and generating Markdown SLO reports.  
   - `mock_prometheus_metrics.py`: Synthetic time-series generator simulating varying outage profiles.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Prometheus & Python/Go SLI tool)  
   🧪 **Testing**: Feed synthetic availability data to Prometheus; run `slo_calculator.py` and verify accurate SLI percentage calculation and remaining error budget output.  
   🔹 [Project directory](10-sre-and-reliability/01-sli-slo-error-budget-calculator)

2. **Multiwindow Multi-Burn-Rate Alerting Rules**  
   🔹 **Goal & Context**: Implement Google SRE Multiwindow Multi-Burn-Rate alerting rules in Prometheus to detect rapid catastrophic outages (14.4x burn rate in 1hr) and slow silent budget drains (6x in 6hr) without alert fatigue.  
   📦 **Deliverables & Scope**:  
   - `slo_alerts.yml`: Prometheus recording rules and multi-burn-rate alerting rules.  
   - `burn_rate_simulator.py`: Tool injecting fast and slow error rate spikes into Prometheus metrics.  
   - Alert verification script.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Prometheus & Alertmanager)  
   🧪 **Testing**: Simulate a 15% error rate; verify that fast burn rate alerts fire within 2 minutes while slow burn rate alerts trigger appropriately over longer time windows.  
   🔹 [Project directory](10-sre-and-reliability/02-multiwindow-multi-burn-rate-alerts)

3. **Automated Incident Runbook Executor**  
   🔹 **Goal & Context**: Create an automated incident remediation daemon that executes self-healing runbook tasks (e.g. restarting hung workers, clearing stuck queues, scaling deployments) when specific PagerDuty/Webhook alerts trigger.  
   📦 **Deliverables & Scope**:  
   - `runbook_executor.py` / `runbook_executor.go`: Webhook listener verifying alert signatures and executing modular remediation scripts.  
   - Modular runbooks (`restart_service.sh`, `flush_cache.sh`, `scale_deployment.sh`).  
   - `simulate_pagerduty_alert.sh`: Script sending synthetic alert payloads.  
   🏗️ **Infrastructure**: Local (OrbStack VM / Docker + PagerDuty Developer Sandbox API)  
   🧪 **Testing**: Send an alert payload via `simulate_pagerduty_alert.sh`; verify that the executor runs the corresponding runbook, logs output, and auto-resolves the alert.  
   🔹 [Project directory](10-sre-and-reliability/03-automated-incident-runbook-executor)

4. **k6 Distributed Performance and Stress Testing**  
   🔹 **Goal & Context**: Design comprehensive load, stress, and spike performance tests using Grafana k6, configuring ramping arrival rate scenarios and asserting strict percentile latency thresholds (`p95 < 200ms`, `error_rate < 1%`).  
   📦 **Deliverables & Scope**:  
   - `load_test.js`: k6 script defining realistic user journeys, ramping stages (warmup, peak, cooldown), and threshold assertions.  
   - Target REST API microservice.  
   - `run_performance_suite.sh`: Automation script running k6 and exporting metrics to InfluxDB/Grafana.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with k6 + InfluxDB + Grafana)  
   🧪 **Testing**: Execute `run_performance_suite.sh`; observe real-time metrics in Grafana and confirm that k6 returns non-zero exit codes when thresholds are breached.  
   🔹 [Project directory](10-sre-and-reliability/04-k6-performance-load-testing-suite)

5. **Container Chaos Engineering with Pumba**  
   🔹 **Goal & Context**: Validate containerized microservice fault tolerance by injecting random chaos experiments (network latency, packet loss, paused containers, forced SIGKILLs) using Pumba under active traffic.  
   📦 **Deliverables & Scope**:  
   - `pumba_chaos.sh`: Chaos execution script targeting specific containers with network delays and unexpected kills.  
   - Resilient microservice stack (with circuit breakers and retries).  
   - Continuous load test runner measuring service availability during chaos injections.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with Pumba)  
   🧪 **Testing**: Run the load generator while injecting chaos via Pumba; assert that the overall service error rate remains <1% and services recover automatically.  
   🔹 [Project directory](10-sre-and-reliability/05-container-chaos-engineering-pumba)

6. **Circuit Breaker and Resilient Retry Engine**  
   🔹 **Goal & Context**: Implement microservice resilience by integrating the Circuit Breaker pattern (Closed, Open, Half-Open states), fallback degradation responses, and exponential backoff retry algorithms.  
   📦 **Deliverables & Scope**:  
   - Microservice client in Go/Node.js/Python implementing circuit breaker state machines.  
   - Mock downstream service with controllable latency and error injection endpoints.  
   - `circuit_breaker_test.py`: Concurrency test suite validating state transitions.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose multi-service setup)  
   🧪 **Testing**: Inject errors into the downstream service; verify that the circuit breaker trips to `OPEN` after 5 consecutive failures and serves fallback responses without network calls.  
   🔹 [Project directory](10-sre-and-reliability/06-circuit-breaker-resilience-pattern)

7. **Kubernetes Chaos Mesh Fault Injection**  
   🔹 **Goal & Context**: Execute declarative chaos experiments on Kubernetes using Chaos Mesh (`PodChaos`, `NetworkChaos`, `TimeChaos`) to validate cluster self-healing and service mesh resiliency.  
   📦 **Deliverables & Scope**:  
   - Chaos Mesh experiment manifests (`pod-failure.yaml`, `network-latency.yaml`, `io-fault.yaml`).  
   - Target multi-replica Kubernetes application.  
   - `chaos_validation_suite.sh`: Automated test suite monitoring cluster health during experiments.  
   🏗️ **Infrastructure**: Local (K3s / K3d with Chaos Mesh Operator)  
   🧪 **Testing**: Apply `pod-failure.yaml`; verify that Kubernetes automatically reschedules replacement pods and service availability remains >99.9%.  
   🔹 [Project directory](10-sre-and-reliability/07-kubernetes-chaos-mesh-fault-injection)

8. **Incident Timeline and Postmortem Generator**  
   🔹 **Goal & Context**: Build an incident management tool that aggregates Git commits, Slack incident discussions, Prometheus alert timestamps, and deployment events into a structured Markdown Postmortem document.  
   📦 **Deliverables & Scope**:  
   - `postmortem_generator.py`: CLI tool querying alert and commit APIs to construct a chronological incident timeline, 5-Whys Root Cause Analysis (RCA), and action items.  
   - `mock_incident_logs/`: Sample data fixtures simulating a major production outage.  
   🏗️ **Infrastructure**: Local (Host OS / OrbStack Linux VM)  
   🧪 **Testing**: Execute `postmortem_generator.py --incident-id INC-402`; verify the generated Markdown document contains an accurate timeline and action item checklist.  
   🔹 [Project directory](10-sre-and-reliability/08-incident-timeline-postmortem-generator)

9. **Graceful Shutdown and Connection Draining**  
   🔹 **Goal & Context**: Implement zero-downtime application lifecycle management handling `SIGTERM` signals, finishing in-flight HTTP requests, closing database connection pools cleanly, and configuring Kubernetes `preStop` hooks.  
   📦 **Deliverables & Scope**:  
   - Web application implementing graceful shutdown signal handling with configurable timeout.  
   - `deployment.yaml` configured with `lifecycle.preStop` sleep hooks and `terminationGracePeriodSeconds`.  
   - `flood_during_restart.sh`: Continuous HTTP load tester running during rolling updates.  
   🏗️ **Infrastructure**: Local (K3s / K3d or Docker Compose in OrbStack)  
   🧪 **Testing**: Run `flood_during_restart.sh` while triggering a rolling update; verify that 100% of in-flight requests complete successfully with zero connection resets.  
   🔹 [Project directory](10-sre-and-reliability/09-graceful-shutdown-connection-draining)

10. **Automated Disaster Recovery GameDay Simulator**  
    🔹 **Goal & Context**: Automate a Disaster Recovery GameDay simulation that fails an entire availability zone or region, orchestrates database failover and DNS redirection, and measures Recovery Time Objective (RTO) and Recovery Point Objective (RPO).  
    📦 **Deliverables & Scope**:  
    - `gameday_orchestrator.py`: Simulation runner injecting primary infrastructure failures and executing failover runbooks.  
    - Continuous data integrity validator and downtime timer logger.  
    - Automated GameDay executive summary report generator.  
    🏗️ **Infrastructure**: Local (Multi-container Docker / K3s) or Cloud (AWS Free Tier with multi-AZ simulate)  
    🧪 **Testing**: Run the GameDay simulator; confirm that automated failover completes within the target RTO (<3 minutes) with zero data loss (RPO = 0).  
    🔹 [Project directory](10-sre-and-reliability/10-disaster-recovery-gameday-simulator)

---

## 11. Security & DevSecOps

1. **Pre-Commit Git Secrets Detection Suite**  
   🔹 **Goal & Context**: Prevent accidental commits of private credentials, API keys, AWS tokens, and certificates into version control by configuring automated pre-commit git hooks with Gitleaks and detect-secrets.  
   📦 **Deliverables & Scope**:  
   - `.pre-commit-config.yaml` configuring Gitleaks and detect-secrets hooks.  
   - `.gitleaks.toml`: Custom rule definitions and allowlists.  
   - `test_secret_blocking.sh`: Script attempting to commit mock API keys to verify pre-commit blocking.  
   🏗️ **Infrastructure**: Local (Host Git environment with `pre-commit` & Gitleaks)  
   🧪 **Testing**: Run `test_secret_blocking.sh`; verify that the pre-commit hook intercepts the commit, outputs a secret detection warning, and prevents code push.  
   🔹 [Project directory](11-security-devsecops/01-pre-commit-secrets-detection)

2. **Container Image Vulnerability Scanning with Trivy**  
   🔹 **Goal & Context**: Build an automated container scanning pipeline using Trivy to inspect Docker images for OS package CVEs, language dependencies (SCA), and misconfigurations, outputting SARIF reports.  
   📦 **Deliverables & Scope**:  
   - `scan_image.sh`: Automation script scanning images, filtering by severity (`CRITICAL`, `HIGH`), and enforcing `.trivyignore` policies.  
   - `Dockerfile.vulnerable` (outdated base image) vs `Dockerfile.patched`.  
   - Automated SARIF report generator.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with Trivy CLI)  
   🧪 **Testing**: Execute `scan_image.sh` against both images; verify that the vulnerable image fails CI policy with non-zero exit code while the patched image passes.  
   🔹 [Project directory](11-security-devsecops/02-container-vulnerability-scanning-trivy)

3. **IaC Security Scanning with Checkov and tfsec**  
   🔹 **Goal & Context**: Enforce infrastructure security compliance by integrating Checkov and tfsec into development workflows to scan Terraform, Kubernetes manifests, and Dockerfiles for security misconfigurations.  
   📦 **Deliverables & Scope**:  
   - `.checkov.yml` / `.tfsec.yml` configuration rulesets.  
   - Test IaC manifests containing intentional security violations (public S3 buckets, open 0.0.0.0/0 security groups, unencrypted EBS volumes).  
   - `iac_security_audit.sh`: Script running scans and generating compliance scorecards.  
   🏗️ **Infrastructure**: Local (Checkov / tfsec CLI in Host or OrbStack / Docker)  
   🧪 **Testing**: Run `iac_security_audit.sh`; confirm that Checkov flags all intentional misconfigurations and provides actionable remediation guidance.  
   🔹 [Project directory](11-security-devsecops/03-iac-security-scanning-checkov-tfsec)

4. **HashiCorp Vault Secrets Engine Deployment**  
   🔹 **Goal & Context**: Deploy and operate HashiCorp Vault locally, configuring KV v2 secrets engines, AppRole machine-to-machine authentication, dynamic secrets, and automated token renewal policies.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` deploying Vault server in production-like configuration.  
   - `vault_bootstrap.sh`: Script configuring AppRoles, read/write policies, and initializing secrets.  
   - `app_vault_client.py`: Application retrieving short-lived tokens and reading dynamic database secrets.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with HashiCorp Vault)  
   🧪 **Testing**: Execute `app_vault_client.py`; authenticate via AppRole credentials, retrieve secrets, and verify that expired tokens are cleanly revoked.  
   🔹 [Project directory](11-security-devsecops/04-hashicorp-vault-secrets-engine)

5. **Vault Agent Sidecar Secret Injector for Kubernetes**  
   🔹 **Goal & Context**: Mount secrets dynamically into application pod memory on Kubernetes without writing secrets to Git or ConfigMaps using Vault Agent Sidecar Injector and Consul templates.  
   📦 **Deliverables & Scope**:  
   - Vault Kubernetes authentication configuration and secret policies.  
   - `deployment.yaml` annotated with `vault.hashicorp.com/agent-inject` annotations and secret templates.  
   - `secret_rotation_test.sh`: Script updating secrets in Vault and verifying live in-memory updates inside running pods.  
   🏗️ **Infrastructure**: Local (K3s / K3d with Vault Helm chart)  
   🧪 **Testing**: Deploy the application pod; verify that secrets appear at `/vault/secrets/config` and execute `secret_rotation_test.sh` to confirm dynamic secret updates.  
   🔹 [Project directory](11-security-devsecops/05-vault-agent-sidecar-injector-k8s)

6. **Container Image Signing and SBOM with Cosign**  
   🔹 **Goal & Context**: Secure the container supply chain by signing container images with Sigstore Cosign, generating Software Bill of Materials (SBOM) with Syft, and validating image signatures before deployment.  
   📦 **Deliverables & Scope**:  
   - `sign_pipeline.sh`: Script generating keypairs, creating SBOMs with Syft, attaching SBOM attestations, and signing images with Cosign.  
   - `verify_image_signature.sh`: Admission verification script rejecting unsigned or tampered container images.  
   🏗️ **Infrastructure**: Local (Cosign, Syft & local OCI registry in OrbStack / Docker)  
   🧪 **Testing**: Run `sign_pipeline.sh` on a test image; verify that `cosign verify` passes for signed images and immediately rejects tampered image digests.  
   🔹 [Project directory](11-security-devsecops/06-cosign-image-signing-sbom)

7. **Kubernetes Admission Control with Kyverno & Gatekeeper**  
   🔹 **Goal & Context**: Enforce cluster-wide security governance on Kubernetes using Kyverno or OPA Gatekeeper to disallow privileged containers, mandate read-only root filesystems, require non-root UIDs, and block `:latest` image tags.  
   📦 **Deliverables & Scope**:  
   - Kyverno `ClusterPolicy` / OPA Gatekeeper `ConstraintTemplate` manifests.  
   - Test pod manifests (compliant vs non-compliant).  
   - `admission_policy_audit.sh`: Automated test suite attempting deployments of non-compliant pods.  
   🏗️ **Infrastructure**: Local (K3s / K3d with Kyverno / Gatekeeper)  
   🧪 **Testing**: Execute `admission_policy_audit.sh`; confirm that the admission controller blocks non-compliant pods with descriptive error messages.  
   🔹 [Project directory](11-security-devsecops/07-kyverno-gatekeeper-admission-policies)

8. **Runtime Threat Detection with Falco and eBPF**  
   🔹 **Goal & Context**: Deploy Falco with modern eBPF probes to monitor Linux kernel system calls in real time, detecting unauthorized shell executions inside containers and modifications to sensitive directories.  
   📦 **Deliverables & Scope**:  
   - `falco_rules.local.yaml`: Custom Falco rules detecting container interactive shells, `/etc/shadow` reads, and network reverse shells.  
   - `simulate_threats.sh`: Exploit simulation script triggering suspicious actions inside a test container.  
   - Alert notification verification script.  
   🏗️ **Infrastructure**: Local (OrbStack Linux VM with eBPF / Falco driver)  
   🧪 **Testing**: Run `simulate_threats.sh`; verify that Falco catches the security events instantly and dispatches formatted alerts to syslog and webhooks.  
   🔹 [Project directory](11-security-devsecops/08-runtime-threat-detection-falco-ebpf)

9. **Automated SSL/TLS Cipher Hardening Audit**  
   🔹 **Goal & Context**: Develop an automated TLS scanner script using `testssl.sh` or Python SSL sockets to audit public and internal HTTPS endpoints for weak ciphers, disabled TLS protocols, and certificate validity.  
   📦 **Deliverables & Scope**:  
   - `tls_audit.py` / `tls_audit.sh`: Automated scanner evaluating TLS 1.0-1.3 support, cipher suite strength, and certificate chains.  
   - Mock Nginx servers configured with weak ciphers vs hardened TLS 1.3 settings.  
   - HTML/JSON compliance scorecard generator.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with `testssl.sh`)  
   🧪 **Testing**: Run the audit tool against the test endpoints; verify that weak ciphers and legacy TLS versions are flagged with security warnings in the scorecard.  
   🔹 [Project directory](11-security-devsecops/09-automated-ssl-tls-hardening-audit)

10. **Zero-Trust Service Mesh mTLS with Istio**  
    🔹 **Goal & Context**: Enforce zero-trust Mutual TLS (mTLS) and fine-grained `AuthorizationPolicy` across microservices using Istio Service Mesh, preventing unauthorized plaintext or lateral network traffic.  
    📦 **Deliverables & Scope**:  
    - Istio manifests (`PeerAuthentication` with `STRICT` mTLS, `AuthorizationPolicy` scoping service-to-service access).  
    - 3 microservices (Frontend, Backend, Rogue Pod).  
    - `mtls_verification_test.sh`: Script proving end-to-end encryption and access control enforcement.  
    🏗️ **Infrastructure**: Local (K3s / K3d with Istio Service Mesh installed)  
    🧪 **Testing**: Run `mtls_verification_test.sh`; confirm that authorized services communicate over encrypted TLS channels while unauthenticated requests from rogue pods are rejected with 403.  
    🔹 [Project directory](11-security-devsecops/10-zero-trust-service-mesh-istio-mtls)

---

## 12. Database Operations & Resilience

1. **Automated PostgreSQL Backup and Restore Validation**  
   🔹 **Goal & Context**: Write a production-grade database backup script using `pg_dump` with gzip compression, timestamping, SHA256 checksums, retention pruning, and an automated test restore routine into a temporary container.  
   📦 **Deliverables & Scope**:  
   - `backup_postgres.sh`: Backup script dumping tables, computing hashes, and enforcing retention.  
   - `restore_postgres.sh`: Validation script restoring dumps into a clean test database and validating row count parity.  
   - `seed_database.py`: Script generating sample database records and relational tables.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with PostgreSQL container)  
   🧪 **Testing**: Seed the database, run `backup_postgres.sh`, followed by `restore_postgres.sh`; verify 100% data integrity and schema consistency.  
   🔹 [Project directory](12-databases-ops/01-automated-postgres-backup-restore)

2. **PostgreSQL Streaming Replication Cluster**  
   🔹 **Goal & Context**: Deploy a high-availability PostgreSQL primary-replica cluster with physical streaming replication, Write-Ahead Logging (WAL) archiving, and read-only query routing.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` configuring Primary and Standby PostgreSQL nodes with shared WAL volumes.  
   - Replication configuration files (`pg_hba.conf`, `postgresql.conf`).  
   - `replication_lag_monitor.py`: Script inserting continuous write load and measuring replication lag via `pg_stat_replication`.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with primary & replica containers)  
   🧪 **Testing**: Insert 50,000 records on the primary node; query the replica node and confirm near-zero replication lag (<10ms) and read-only query execution.  
   🔹 [Project directory](12-databases-ops/02-postgres-streaming-replication-cluster)

3. **Database Migration Pipeline with Version Locking**  
   🔹 **Goal & Context**: Build an automated database schema migration pipeline using `golang-migrate` or Flyway in CI/CD, managing transactional forward (`up`) and rollback (`down`) SQL migrations with version locking.  
   📦 **Deliverables & Scope**:  
   - SQL migration files (`001_init.up.sql`, `001_init.down.sql`, `002_add_index.up.sql`).  
   - `migrate.sh`: CLI runner handling migration application, rollbacks, and dirty-state recovery.  
   - Migration test suite validating rollback state cleanliness.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with PostgreSQL + golang-migrate)  
   🧪 **Testing**: Run `migrate.sh up` to apply migrations; execute `migrate.sh down 1` to test rollback, and verify that the database schema returns cleanly to the prior version.  
   🔹 [Project directory](12-databases-ops/03-database-migration-pipeline-version-locking)

4. **PgBouncer Connection Pooling and Tuning**  
   🔹 **Goal & Context**: Deploy PgBouncer in front of PostgreSQL to handle high-concurrency client connections via transaction pooling, and benchmark connection overhead under heavy load.  
   📦 **Deliverables & Scope**:  
   - `pgbouncer.ini` (pool mode: transaction, max client connections: 1000, default pool size: 20) and `userlist.txt`.  
   - `docker-compose.yml` deploying PostgreSQL and PgBouncer.  
   - `benchmark_concurrency.py`: Script opening 500 simultaneous connections directly vs through PgBouncer.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with PostgreSQL + PgBouncer)  
   🧪 **Testing**: Execute `benchmark_concurrency.py`; verify that direct PostgreSQL connections exhaust connection limits while PgBouncer handles all 500 clients with lower memory overhead.  
   🔹 [Project directory](12-databases-ops/04-pgbouncer-connection-pooling-tuning)

5. **Redis Sentinel High Availability and Failover**  
   🔹 **Goal & Context**: Build a resilient in-memory caching cluster using Redis Sentinel (1 Master, 2 Replicas, 3 Sentinels) providing automatic quorum election, master failover, and client reconnection.  
   📦 **Deliverables & Scope**:  
   - `docker-compose.yml` deploying 3 Redis nodes and 3 Sentinel nodes with quorum configuration.  
   - `sentinel.conf` configuration files.  
   - `redis_client_resilience.py`: Client script writing continuous data while simulating Master node crash (`kill -9`).  
   🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with 3 Redis + 3 Sentinel nodes)  
   🧪 **Testing**: Run `redis_client_resilience.py` and kill the Master container; verify that Sentinel elects a Replica as the new Master within 5 seconds and client writes resume automatically.  
   🔹 [Project directory](12-databases-ops/05-redis-sentinel-ha-failover)

6. **MySQL Point-in-Time Recovery (PITR) Lab**  
   🔹 **Goal & Context**: Master disaster recovery by executing Point-in-Time Recovery (PITR) on MySQL using full physical backups and binary logs (`mysqlbinlog`) to restore data to an exact second before an accidental `DROP TABLE`.  
   📦 **Deliverables & Scope**:  
   - MySQL backup scripts with binary logging enabled (`binlog_format = ROW`).  
   - `simulate_disaster.py`: Script performing a backup, inserting valid transactions, and executing an accidental drop table at timestamp $T$.  
   - `pitr_restore_runbook.sh`: Recovery script replaying binlogs up to timestamp $T-1$.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with MySQL container)  
   🧪 **Testing**: Run `simulate_disaster.py` followed by `pitr_restore_runbook.sh`; verify that all records up to the exact second before the drop are recovered with zero data loss.  
   🔹 [Project directory](12-databases-ops/06-mysql-point-in-time-recovery-pitr)

7. **Database Slow Query Analyzer with pgBadger**  
   🔹 **Goal & Context**: Automate PostgreSQL query performance profiling by tuning log duration settings (`log_min_duration_statement`, `pg_stat_statements`) and generating daily visual HTML and JSON analysis reports using pgBadger.  
   📦 **Deliverables & Scope**:  
   - `postgresql.conf` performance logging configuration.  
   - `query_workload_generator.py`: Script executing mixed workloads (indexed fast queries vs unindexed slow table scans and lock contention).  
   - `generate_pgbadger_report.sh`: Automation script parsing logs and generating reports.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with PostgreSQL + pgBadger)  
   🧪 **Testing**: Execute the workload generator and run `generate_pgbadger_report.sh`; open the resulting HTML report and verify that slow queries and missing index recommendations are highlighted.  
   🔹 [Project directory](12-databases-ops/07-database-slow-query-analyzer-pgbadger)

8. **CloudNative-PG Operator on Kubernetes**  
   🔹 **Goal & Context**: Deploy and operate self-healing, enterprise PostgreSQL clusters on Kubernetes using CloudNative-PG Operator with automated WAL archiving to S3, replica scaling, and automatic failovers.  
   📦 **Deliverables & Scope**:  
   - CloudNative-PG `Cluster` CRD manifest specifying 3 instances, backup storage policies, and resource limits.  
   - `operator_failover_test.sh`: Script testing primary pod deletion, replica promotion, and WAL archive recovery.  
   🏗️ **Infrastructure**: Local (K3s / K3d / OrbStack Kubernetes + CloudNative-PG Operator)  
   🧪 **Testing**: Apply the cluster CRD; execute `operator_failover_test.sh` to terminate the primary pod, and confirm that the operator promotes a standby replica to primary in under 10 seconds.  
   🔹 [Project directory](12-databases-ops/08-cloudnative-pg-operator-k8s)

9. **Data Anonymization and PII Masking Pipeline**  
   🔹 **Goal & Context**: Build an automated ETL data sanitization pipeline that anonymizes production database dumps before importing them into staging or development environments, masking PII while preserving foreign key integrity.  
   📦 **Deliverables & Scope**:  
   - `mask_database.py`: Sanitization script replacing real names, emails, credit cards, and addresses with realistic synthetic data using Faker while maintaining referential integrity.  
   - `seed_production_dump.sql`: Sample database dump containing sensitive user records.  
   - `verify_anonymization.py`: Verification script scanning for unmasked PII.  
   🏗️ **Infrastructure**: Local (OrbStack / Docker with PostgreSQL + Python script)  
   🧪 **Testing**: Run `mask_database.py` on the sample dump; verify via `verify_anonymization.py` that all PII is redacted and foreign key constraints remain intact.  
   🔹 [Project directory](12-databases-ops/09-data-anonymization-pii-masking-pipeline)

10. **Zero-Downtime Expand and Contract Schema Refactoring**  
    🔹 **Goal & Context**: Execute a complex database schema refactoring (e.g. splitting a table or renaming a column) with zero application downtime using the Expand-and-Contract (Parallel Run) migration pattern.  
    📦 **Deliverables & Scope**:  
    - Migration scripts for Phase 1 (Expand: add new column + database triggers), Phase 2 (Dual-write & Backfill), and Phase 3 (Contract: drop legacy triggers and columns).  
    - Web application supporting dual-write mode.  
    - `continuous_traffic_runner.py`: Continuous read/write traffic simulator asserting zero failed transactions during migration.  
    🏗️ **Infrastructure**: Local (OrbStack / Docker Compose with PostgreSQL + API service)  
    🧪 **Testing**: Run `continuous_traffic_runner.py` while executing all 3 migration phases sequentially; confirm zero dropped transactions and complete data consistency.  
    🔹 [Project directory](12-databases-ops/10-zero-downtime-schema-refactoring)
