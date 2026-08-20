# devops-sre-mini-projects

DevOps & SRE mini-projects, each one a new challenge.

![Featured Image](https://fabiankaraben.github.io/mini-projects/imgs/devops-sre.webp)

## Setup instructions

1. Install essential CLI tools: `bash`, `git`, `curl`, `jq`, `openssl`, `python3`, `go`
2. Install container & orchestration tools: `docker`, `docker-compose`, `kubectl`, `helm`, `minikube` (or `kind`)
3. Install Infrastructure as Code & automation tools: `terraform` (or `opentofu`), `ansible`
4. Set up environment variables and configuration files (`.env`) in each project directory where required

---

## 01. Linux Scripting

1. **System Resource Health Checker**  
   🔹 Bash script that monitors CPU, memory, and disk usage against configurable thresholds, outputting structured JSON metrics and triggering warnings when limits are exceeded.  
   🧪 **Testing**: Execute script with custom threshold flags (`--cpu-max 80`) and verify stdout output and non-zero exit code when thresholds are breached.  
   🔹 [Project directory](01-linux-scripting/01-system-resource-health-checker)

2. **Log File Rotation and Archiver**  
   🔹 Shell script to compress, timestamp, and archive logs older than N days to a backup directory, while safely handling locked or open file descriptors.  
   🧪 **Testing**: Generate dummy log files with past timestamps and verify archived tarball contents and log directory clean-up.  
   🔹 [Project directory](01-linux-scripting/02-log-file-rotation-archiver)

3. **User and Group Batch Provisioner**  
   🔹 POSIX-compliant script that parses a CSV/JSON manifest of users, groups, and SSH public keys, idempotently creating system users and configuring `.ssh/authorized_keys` with strict permissions.  
   🧪 **Testing**: Execute provisioner against a test manifest in a disposable container; verify `id`, `/etc/passwd`, `/etc/group`, and SSH key permissions for each provisioned user.  
   🔹 [Project directory](01-linux-scripting/03-user-group-batch-provisioner)

4. **Process Watchdog Daemon**  
   🔹 Process watchdog in Bash/Python that monitors a list of critical PID/service names, automatically attempts restart upon unexpected termination, logs restart attempts to syslog, and triggers a webhook notification.  
   🧪 **Testing**: Kill dummy target processes with `kill -9` and verify the watchdog restarts the service within 5 seconds and sends an alert.  
   🔹 [Project directory](01-linux-scripting/04-process-watchdog-daemon)

5. **Automated Backup with S3 Upload**  
   🔹 Backup utility in Python/Bash that dumps specified directories and databases, creates GPG-encrypted tarballs, and uploads them to an S3-compatible bucket with SHA256 checksum validation.  
   🧪 **Testing**: Run backup against test folder and local MinIO instance; verify remote object integrity via SHA256 checksum comparison and successful GPG decryption.  
   🔹 [Project directory](01-linux-scripting/05-automated-backup-s3-upload)

6. **SSL/TLS Certificate Expiry Auditor**  
   🔹 CLI tool in Python/Go that reads a list of domains or IP endpoints, connects via TLS, extracts X.509 certificate metadata, calculates days until expiration, and exports Prometheus metrics or alerts for certs expiring soon.  
   🧪 **Testing**: Run auditor against endpoints with valid, near-expired, and self-signed certificates; verify accurate day calculation and alert triggering.  
   🔹 [Project directory](01-linux-scripting/06-ssl-certificate-expiry-auditor)

7. **Network Port Scanner and Troubleshooter**  
   🔹 Concurrent network diagnostics script in Go/Python that accepts CIDR blocks and port ranges, performs non-blocking TCP socket connect scans, checks DNS latency, and generates a formatted Markdown connectivity matrix.  
   🧪 **Testing**: Run against a local test environment with known open and closed ports; benchmark execution time and assert accuracy against `nmap` output.  
   🔹 [Project directory](01-linux-scripting/07-network-port-scanner-troubleshooter)

8. **Zombie and Orphan Process Reaper**  
   🔹 Linux kernel process tree analyzer in Python using `/proc` filesystem to inspect process states (`Z`, `D`), identify parent-child ancestry, report memory leaks from abandoned child processes, and safely signal parent processes to collect exit statuses.  
   🧪 **Testing**: Compile a test script that spawns zombie and orphan processes, run the reaper tool, and verify that defunct entries are cleaned up from `/proc`.  
   🔹 [Project directory](01-linux-scripting/08-zombie-orphan-process-reaper)

9. **Kernel and Sysctl Performance Tuner**  
   🔹 Automated system hardening and performance optimization script that evaluates current Linux `sysctl` parameters (TCP buffer sizes, `file-max`, `swappiness`, `somaxconn`), backs up original config, and applies tuned profiles for high-throughput network servers.  
   🧪 **Testing**: Apply the tuning script inside a privileged test container, verify `sysctl -p` application, and run rollback function to verify state restoration.  
   🔹 [Project directory](01-linux-scripting/09-kernel-sysctl-performance-tuner)

10. **Unified DevOps Toolkit CLI**  
    🔹 Comprehensive unified CLI utility in Go (using Cobra) or Python (using Click) compiling system diagnostics, log analyzers, remote SSH execution pools, and cloud cost estimators into a single binary with shell autocompletion.  
    🧪 **Testing**: Run unit and integration tests for all subcommands, test `--help` generation, and verify shell completion script generation.  
    🔹 [Project directory](01-linux-scripting/10-unified-devops-toolkit-cli)

---

## 02. Networking & Traffic Routing

1. **Static Web Nginx Reverse Proxy**  
   🔹 Nginx configuration serving static assets with custom error pages, gzip compression, client-side caching headers (`Cache-Control`), and forwarding `/api/*` traffic to an upstream mock HTTP server.  
   🧪 **Testing**: Use `curl -I` to verify `Content-Encoding: gzip`, `Cache-Control` header presence, and proxy upstream response code 200.  
   🔹 [Project directory](02-networking/01-static-web-nginx-reverse-proxy)

2. **Internal DNS Server with CoreDNS**  
   🔹 Local DNS resolution service configured with CoreDNS supporting forward and reverse lookup zones, split-horizon DNS records for internal vs external clients, and custom upstream forwarding rules.  
   🧪 **Testing**: Query DNS server using `dig @127.0.0.1 -p 53 <zone>` for A, CNAME, and PTR records; verify correct IP resolution and query response times.  
   🔹 [Project directory](02-networking/02-internal-dns-server-coredns)

3. **SSL/TLS Termination Reverse Proxy**  
   🔹 Reverse proxy setup terminating TLS 1.3 using certificates, enforcing HTTP-to-HTTPS redirection, HSTS headers, and modern cipher suites while offloading unencrypted traffic to backend instances.  
   🧪 **Testing**: Use `openssl s_client` to verify TLS 1.3 negotiation, cipher selection, HSTS header presence, and HTTP 301 redirection.  
   🔹 [Project directory](02-networking/03-ssl-tls-termination-reverse-proxy)

4. **Layer 4 TCP HAProxy Load Balancer**  
   🔹 HAProxy configuration operating at Layer 4 (TCP) balancing traffic across multiple backend TCP services with active health checks, round-robin and leastconn balancing algorithms, and a statistics dashboard.  
   🧪 **Testing**: Spin up backend HTTP/TCP servers, send continuous requests, stop one backend, and verify traffic redistribution without dropped packets.  
   🔹 [Project directory](02-networking/04-layer4-haproxy-load-balancer)

5. **API Gateway with Leaky-Bucket Rate Limiting**  
   🔹 Nginx / Envoy based API gateway with leaky-bucket rate limiting per client IP (`limit_req`), request body size validation, CORS header injection, and custom 429 JSON response payloads.  
   🧪 **Testing**: Send rapid bursts of requests using `hey` or `autocannon` and verify that requests exceeding the rate limit receive HTTP 429 Too Many Requests.  
   🔹 [Project directory](02-networking/05-api-gateway-rate-limiting)

6. **Site-to-Site WireGuard VPN Mesh**  
   🔹 Fully configured WireGuard VPN mesh connecting two distinct virtual networks, complete with public/private key pairs, IP routing tables, and keep-alive configuration for NAT traversal.  
   🧪 **Testing**: Execute ICMP ping and HTTP requests between containers across isolated subnets over the `wg0` tunnel interface, confirming packet encapsulation.  
   🔹 [Project directory](02-networking/06-wireguard-vpn-mesh)

7. **Linux Firewall Hardening with nftables**  
   🔹 Comprehensive Linux firewall script using `nftables` / `iptables` implementing default-drop policies, stateful packet inspection, anti-spoofing rules, ICMP rate limiting, and port scan detection.  
   🧪 **Testing**: Run `nmap` scans against the host to verify drop policies for closed ports, rate limiting on SYN floods, and legitimate SSH/HTTP ingress allowances.  
   🔹 [Project directory](02-networking/07-linux-firewall-nftables-hardening)

8. **Shadow Traffic Mirroring Proxy**  
   🔹 Traffic mirroring setup (using Nginx `mirror` or eBPF/tc) that duplicates live incoming production HTTP traffic to a shadow analysis backend for asynchronous telemetry and security anomaly detection.  
   🧪 **Testing**: Send HTTP POST requests to primary endpoint and verify payload arrival on shadow service without impacting client response latency.  
   🔹 [Project directory](02-networking/08-shadow-traffic-mirroring-proxy)

9. **Dynamic DNS Updater Daemon**  
   🔹 Dynamic DNS (DDNS) daemon written in Python/Go that detects public IP changes via STUN/HTTP lookup, authenticates with Cloudflare/AWS Route53 API, and updates DNS A-records with idempotency and exponential backoff retry logic.  
   🧪 **Testing**: Mock IP change responses in integration test suite; verify API patch call dispatch and record TTL preservation.  
   🔹 [Project directory](02-networking/09-dynamic-dns-updater-daemon)

10. **Envoy L7 Canary Router and Circuit Breaker**  
    🔹 Envoy Proxy deployment implementing Layer 7 weighted routing, header-based canary matching (`x-canary: true`), circuit breaking (outlier detection), and gRPC access logging.  
    🧪 **Testing**: Route 1000 requests and verify an exact 90/10 traffic split between v1 and v2 services, along with 100% routing to v2 when the canary header is present.  
    🔹 [Project directory](02-networking/10-envoy-canary-router-circuit-breaker)

---

## 03. Containers & Image Optimization

1. **Multi-Stage Minimal Dockerfile**  
   🔹 Multi-stage Dockerfile for Go/Node.js/Python applications utilizing minimal base images (Alpine / Distroless / Scratch), non-root user execution (`UID 10001`), and proper `.dockerignore` filters to achieve <25MB final image sizes.  
   🧪 **Testing**: Build image, inspect image layers with `docker history`, check size with `docker images`, and assert that the binary runs as a non-root user (`whoami`).  
   🔹 [Project directory](03-containers/01-multi-stage-minimal-dockerfile)

2. **Multi-Service Docker Compose Stack**  
   🔹 Production-ready Docker Compose environment linking a Web API, Redis cache, PostgreSQL database, and Adminer UI with dedicated custom bridge networks, named volumes, health checks, and restart policies.  
   🧪 **Testing**: Execute `docker compose up -d`, verify container dependency order with `docker compose ps` (waiting for database healthy status), and perform end-to-end CRUD requests.  
   🔹 [Project directory](03-containers/02-multi-service-docker-compose-stack)

3. **Container Healthchecks and Autoheal Engine**  
   🔹 Docker Compose setup featuring custom `HEALTHCHECK` instructions (HTTP endpoint probes and database ping scripts) integrated with an auto-healing watcher daemon that detects unhealthy states and restarts faulty containers.  
   🧪 **Testing**: Trigger synthetic failure endpoint on the application container; verify Docker marks state as `unhealthy` and autoheal watcher restarts container.  
   🔹 [Project directory](03-containers/03-container-healthchecks-autoheal)

4. **BuildKit Layer Caching and Secrets Mounting**  
   🔹 Advanced Docker BuildKit configuration leveraging cache mounts (`--mount=type=cache`), secret mounts (`--mount=type=secret`), and remote inline cache export to optimize CI build times by >80%.  
   🧪 **Testing**: Benchmark initial build vs warm cache build with dependency modifications; assert that unchanged package layers are fetched from cache.  
   🔹 [Project directory](03-containers/04-buildkit-caching-secrets)

5. **Distroless Hardened Container Runtimes**  
   🔹 Secure container build using GoogleContainerTools Distroless images and Chainguard Wolfi images, stripping all shells, package managers, and unnecessary binaries while preserving standard timezone and CA-certificate stores.  
   🧪 **Testing**: Attempt `docker exec -it <container> sh` (expecting failure) and verify application function, SSL certificate verification, and zero critical CVEs via vulnerability scan.  
   🔹 [Project directory](03-containers/05-distroless-hardened-runtimes)

6. **Container Resource Constraints and OOM Profiler**  
   🔹 Container benchmarking lab applying hard cgroups limits (`cpus`, `memory`, `memory-swap`, `pids-limit`) and profiling container behavior under OOM (Out Of Memory) conditions using Linux `systemd-cgls` and `docker stats`.  
   🧪 **Testing**: Trigger memory leak script inside container; verify OOM-killer termination with exit code 137 and inspect Docker event streams.  
   🔹 [Project directory](03-containers/06-container-resource-constraints-oom-profiler)

7. **Docker Socket Security Proxy Gateway**  
   🔹 Security proxy for Docker Daemon socket (`/var/run/docker.sock`) using HAProxy / Tecnativa Docker Socket Proxy, exposing a restricted read-only subset of the API to monitoring tools while blocking container creation and volume mounting.  
   🧪 **Testing**: Run monitoring tools through proxy; verify read operations succeed while `POST /containers/create` requests return 403 Forbidden.  
   🔹 [Project directory](03-containers/07-docker-socket-security-proxy)

8. **Multi-Architecture Image Builder with Buildx**  
   🔹 Docker Buildx setup with QEMU virtualization configured to cross-compile and assemble multi-architecture container manifests supporting `linux/amd64` and `linux/arm64` architectures.  
   🧪 **Testing**: Inspect generated multi-arch manifest using `docker buildx imagetools inspect` and verify container execution on both x86_64 and ARM emulation targets.  
   🔹 [Project directory](03-containers/08-multi-arch-builder-buildx)

9. **Rootless Container Execution Environment**  
   🔹 Rootless container execution environment using Podman / Rootless Docker with user namespaces (`subuid`/`subgid`), eliminating root daemon privileges and preventing container-breakout host root compromises.  
   🧪 **Testing**: Run container under an unprivileged user account; verify process UID mapping inside container namespace vs host process table (`ps aux`).  
   🔹 [Project directory](03-containers/09-rootless-container-environment)

10. **Custom Container Runtime from Scratch**  
    🔹 Minimal container runtime written in Go/C leveraging Linux kernel namespaces (`CLONE_NEWPID`, `CLONE_NEWNET`, `CLONE_NEWNS`), cgroups v2 resource limits, and `pivot_root` into an unpacked rootfs.  
    🧪 **Testing**: Execute custom runtime binary with isolation flags, check isolated process list (`ps`), verify filesystem sandbox boundary, and confirm memory limits.  
    🔹 [Project directory](03-containers/10-custom-container-runtime-from-scratch)

---

## 04. Kubernetes & Orchestration

1. **Stateless Application Deployment and Service**  
   🔹 Kubernetes declarative manifest defining a multi-replica Deployment, ClusterIP Service, Readiness/Liveness Probes, and resource requests/limits for a stateless web application.  
   🧪 **Testing**: Apply manifest to local cluster (Kind/Minikube); verify pod rollout status, endpoint resolution via `kubectl port-forward`, and probe success.  
   🔹 [Project directory](04-orchestration/01-stateless-app-deployment-service)

2. **ConfigMaps, Secrets, and Dynamic Reloading**  
   🔹 Configuration management in Kubernetes using ConfigMaps and Secrets mounted as environment variables and volume files, with automatic pod reload upon config changes via Reloader.  
   🧪 **Testing**: Update ConfigMap data; verify mounted configuration updates in running pods and verify secret decryption inside container.  
   🔹 [Project directory](04-orchestration/02-configmaps-secrets-reloading)

3. **Ingress Routing with Automated TLS via cert-manager**  
   🔹 Nginx Ingress Controller setup with host-based and path-based routing rules, TLS termination, and automated certificate issuance and renewal using cert-manager with Let's Encrypt / Self-Signed Issuer.  
   🧪 **Testing**: Send curl requests with custom `Host` headers; verify routing to separate backend services and check TLS certificate validity.  
   🔹 [Project directory](04-orchestration/03-ingress-routing-tls-cert-manager)

4. **StatefulSet and Dynamic Persistent Volumes**  
   🔹 StatefulSet deployment for a distributed storage system (e.g. MongoDB/Redis) utilizing dynamic PersistentVolumeClaims (PVC), StorageClasses, and Headless Services for stable network identities.  
   🧪 **Testing**: Write data to primary pod, delete pod forcefully (`kubectl delete pod <pod-0>`), and verify state retention on newly scheduled replacement pod.  
   🔹 [Project directory](04-orchestration/04-statefulset-persistent-volumes)

5. **Horizontal Pod Autoscaler with Custom Metrics**  
   🔹 Horizontal Pod Autoscaler (HPA v2) configuration scaling pods based on average CPU utilization, memory thresholds, and custom Prometheus metrics with scale-up and scale-down stabilization windows.  
   🧪 **Testing**: Generate artificial traffic load using `hey`; monitor `kubectl get hpa -w` and verify deployment scales from 2 to 10 replicas and stabilizes.  
   🔹 [Project directory](04-orchestration/05-horizontal-pod-autoscaler)

6. **Production-Grade Helm Chart Packaging**  
   🔹 Helm 3 chart with parameterized `values.yaml`, helper templates (`_helpers.tpl`), JSON schema validation, conditional dependency subcharts, and linting automation.  
   🧪 **Testing**: Run `helm lint`, `helm template`, and `helm test` against local test cluster to verify dry-run output and live release deployment.  
   🔹 [Project directory](04-orchestration/06-production-helm-chart-packaging)

7. **RBAC Least-Privilege Policies and Pod Security**  
   🔹 Role-Based Access Control (RBAC) architecture defining Namespaces, ServiceAccounts, Roles, ClusterRoles, RoleBindings, and Least-Privilege access rules, complemented by Pod Security Standards (PSS/PSA).  
   🧪 **Testing**: Use `kubectl auth can-i` under various ServiceAccount contexts to assert authorized vs forbidden operations across namespaces.  
   🔹 [Project directory](04-orchestration/07-rbac-pod-security-policies)

8. **Canary and Blue-Green Deployments with Argo Rollouts**  
   🔹 Advanced deployment strategies using Argo Rollouts implementing progressive traffic shifting (Canary: 10% -> 25% -> 50% -> 100%) with automated analysis templates pausing/aborting rollouts on error rate spikes.  
   🧪 **Testing**: Trigger canary release with intentional error injection; verify Argo Rollout detects metrics breach and executes automatic rollback to stable revision.  
   🔹 [Project directory](04-orchestration/08-canary-blue-green-argo-rollouts)

9. **Zero-Trust Network Policies with Cilium CNI**  
   🔹 Zero-trust network segmentation using Kubernetes NetworkPolicies and Cilium CNI, enforcing default-deny ingress/egress, namespace isolation, and egress CIDR whitelisting.  
   🧪 **Testing**: Spin up test pods across namespaces; verify blocked inter-pod communication where disallowed and successful connection across explicitly permitted ports.  
   🔹 [Project directory](04-orchestration/09-zero-trust-network-policies-cilium)

10. **Custom Kubernetes Operator with Kubebuilder**  
    🔹 Custom Kubernetes Operator written in Go using Kubebuilder and Controller-Runtime, managing a custom CustomResourceDefinition (CRD) with reconciliation loop, status subresources, and finalizers.  
    🧪 **Testing**: Run integration test suite using `envtest`; apply CRD manifest to live cluster and verify the operator creates backing resources and updates status conditions.  
    🔹 [Project directory](04-orchestration/10-custom-kubernetes-operator-kubebuilder)

---

## 05. CI/CD Pipelines

1. **GitHub Actions Matrix Lint and Test Workflow**  
   🔹 GitHub Actions workflow implementing parallel job matrix testing across multiple language versions, static code analysis (linter/formatter), and unit test execution with code coverage reporting.  
   🧪 **Testing**: Trigger workflow on pull request; verify all matrix jobs pass and code coverage artifacts are uploaded to GitHub Actions summary.  
   🔹 [Project directory](05-ci-cd/01-github-actions-lint-test-workflow)

2. **Multi-Arch Docker Build and Push Pipeline**  
   🔹 Automated CI pipeline that builds multi-arch Docker images, tags them with git commit SHA and semantic release tags, and securely authenticates and pushes images to GitHub Container Registry (GHCR) using OIDC.  
   🧪 **Testing**: Push git release tag; verify GHCR image repository receives new image digest with correct labels and metadata.  
   🔹 [Project directory](05-ci-cd/02-multi-arch-docker-build-push-pipeline)

3. **Semantic Release and Automated Changelog**  
   🔹 Automated release management pipeline using Semantic Release and Conventional Commits to calculate next semantic version (semver), generate `CHANGELOG.md`, create GitHub Releases, and tag the repository.  
   🧪 **Testing**: Push commits with `feat:` and `fix:` prefixes; verify automated release tag creation, version bump, and release notes accuracy.  
   🔹 [Project directory](05-ci-cd/03-semantic-release-automated-changelog)

4. **Multi-Stage Security Scanning Pipeline**  
   🔹 Multi-tier security scanning pipeline integrating Trivy (container vulnerabilities), Gitleaks (hardcoded secrets detection), and Semgrep (SAST), blocking pull requests on high/critical findings.  
   🧪 **Testing**: Commit a dummy test secret and vulnerable package; assert that CI pipeline fails, emits actionable report, and blocks PR merge.  
   🔹 [Project directory](05-ci-cd/04-multi-stage-security-scanning-pipeline)

5. **GitLab CI Multi-Environment Delivery Pipeline**  
   🔹 GitLab CI/CD pipeline (`.gitlab-ci.yml`) with distinct stages (`build`, `test`, `deploy-staging`, `deploy-production`), manual approval gates, environment URL tracking, and dynamic review apps for feature branches.  
   🧪 **Testing**: Simulate branch pipeline execution in GitLab runner; verify staging auto-deploys while production requires manual gate approval.  
   🔹 [Project directory](05-ci-cd/05-gitlab-ci-multi-environment-pipeline)

6. **GitOps Continuous Delivery with ArgoCD**  
   🔹 Declarative GitOps deployment workflow using ArgoCD Application manifests tracking a Kubernetes repository, configuring automated sync policies, self-healing, and drift detection.  
   🧪 **Testing**: Commit an image tag change to the config repo; verify ArgoCD detects change and syncs application to new state within 60 seconds.  
   🔹 [Project directory](05-ci-cd/06-gitops-cd-argocd)

7. **Jenkins Declarative Pipeline with Shared Libraries**  
   🔹 Enterprise Jenkins Declarative Pipeline utilizing a custom Groovy Shared Library, dynamic Docker agent provisioning, credential masking, and post-build Slack notification webhooks.  
   🧪 **Testing**: Execute Jenkinsfile in test Jenkins controller; verify shared step execution, agent ephemeral container lifecycle, and Slack webhook delivery.  
   🔹 [Project directory](05-ci-cd/07-jenkins-declarative-pipeline-shared-libraries)

8. **Ephemeral Preview Environments per Pull Request**  
   🔹 CI workflow that dynamically provisions an isolated preview environment on Kubernetes for every pull request with unique subdomains, and automatically tears it down when PR is closed/merged.  
   🧪 **Testing**: Open PR; verify preview namespace and ingress creation with live URL. Close PR; verify namespace and associated cloud resources deletion.  
   🔹 [Project directory](05-ci-cd/08-ephemeral-preview-environments-pr)

9. **ChatOps Slack Deployment Bot**  
   🔹 ChatOps service in Go/Node.js integrated with Slack/Discord Slash Commands and GitHub/GitLab APIs, allowing engineers to trigger deployments, rollbacks, and status queries directly from chat channels with RBAC authorization.  
   🧪 **Testing**: Send `/deploy app staging` slash command via mock Slack webhook; verify authorized dispatch to CI runner and channel status confirmation.  
   🔹 [Project directory](05-ci-cd/09-chatops-slack-deployment-bot)

10. **Multi-Region Blue-Green Deployment Orchestrator**  
    🔹 End-to-end continuous deployment orchestrator coordinating zero-downtime blue-green deployments across multi-region / multi-cluster environments with automated smoke testing and instant DNS switchover.  
    🧪 **Testing**: Run end-to-end deployment runbook; verify traffic shifts seamlessly from blue to green pool with zero dropped requests during live load testing.  
    🔹 [Project directory](05-ci-cd/10-multi-region-blue-green-orchestrator)

---

## 06. Infrastructure as Code (IaC)

1. **Terraform Local Docker Provider Infrastructure**  
   🔹 Terraform project utilizing the `kreuzwerker/docker` provider to provision custom networks, volumes, and containerized services locally with variables, outputs, and state files.  
   🧪 **Testing**: Run `terraform init`, `terraform validate`, `terraform apply -auto-approve`, and verify running containers with `docker ps`.  
   🔹 [Project directory](06-infrastructure-as-code/01-terraform-local-docker-infrastructure)

2. **Modular High-Availability AWS VPC**  
   🔹 Reusable, modular Terraform codebase provisioning a highly available AWS VPC across 3 Availability Zones with public/private subnets, Internet Gateway, NAT Gateways, and route tables.  
   🧪 **Testing**: Execute `tflint` and `terraform plan` against LocalStack/AWS; verify output subnet IDs and routing table associations.  
   🔹 [Project directory](06-infrastructure-as-code/02-modular-aws-vpc-terraform)

3. **Remote State Locking with S3 and DynamoDB**  
   🔹 Terraform backend architecture using AWS S3 bucket with server-side encryption and versioning, combined with a DynamoDB state-locking table to prevent concurrent apply race conditions.  
   🧪 **Testing**: Attempt concurrent `terraform apply` executions from two terminals; verify that the second execution is blocked by the DynamoDB lock.  
   🔹 [Project directory](06-infrastructure-as-code/03-remote-state-locking-s3-dynamodb)

4. **Ansible Baseline Server Hardening Playbook**  
   🔹 Ansible playbook and roles applying CIS Linux benchmark hardening: disabling root SSH, configuring UFW/firewalld, updating packages, installing fail2ban, and setting up automated security updates.  
   🧪 **Testing**: Run `ansible-playbook -i inventory site.yml --check` (dry-run) and apply to test VM; verify SSH config changes and fail2ban service status.  
   🔹 [Project directory](06-infrastructure-as-code/04-ansible-server-baseline-hardening)

5. **OpenTofu Multi-Environment Workspaces**  
   🔹 OpenTofu / Terraform setup implementing workspace-based multi-environment deployments (`dev`, `staging`, `prod`) with environment-specific `.tfvars`, resource tagging, and sizing rules.  
   🧪 **Testing**: Switch workspaces with `tofu workspace select prod` and assert that resource count and instance types match production specifications in `tofu plan`.  
   🔹 [Project directory](06-infrastructure-as-code/05-opentofu-multi-environment-workspaces)

6. **Ansible Dynamic Inventory for Cloud Fleets**  
   🔹 Ansible dynamic inventory plugin configuring automated host discovery from AWS/GCP/Docker tags, orchestrating rolling application updates across dynamic server groups without hardcoded IPs.  
   🧪 **Testing**: Provision temporary cloud instances with tags; execute `ansible-inventory --graph` and run a playbook targeting tag-based host groups.  
   🔹 [Project directory](06-infrastructure-as-code/06-ansible-dynamic-inventory-cloud)

7. **DRY Multi-Account Architecture with Terragrunt**  
   🔹 DRY (Don't Repeat Yourself) infrastructure architecture using Terragrunt to manage multi-account, multi-region Terraform modules with root `terragrunt.hcl` inheritance and remote state generation.  
   🧪 **Testing**: Run `terragrunt run-all plan` across all service folders and verify proper variable inheritance and zero duplicated backend configs.  
   🔹 [Project directory](06-infrastructure-as-code/07-terragrunt-dry-architecture)

8. **Pulumi TypeScript Kubernetes Infrastructure**  
   🔹 Real programming language IaC using Pulumi (TypeScript/Python) to provision a Kubernetes cluster, configure namespaces, and deploy an application stack with strongly-typed configurations.  
   🧪 **Testing**: Run `pulumi preview` and `pulumi up --yes`; verify created resources via `kubectl` and assert Pulumi stack outputs.  
   🔹 [Project directory](06-infrastructure-as-code/08-pulumi-typescript-k8s-infrastructure)

9. **Automated Terraform Drift Detection and Alerting**  
   🔹 Automated infrastructure drift detection tool running on a cron schedule that compares live cloud state with Terraform state files, flags out-of-band modifications, and triggers Slack alerts or auto-remediation.  
   🧪 **Testing**: Manually modify a security group rule out-of-band; run drift detection pipeline and verify alert generation detailing the exact drift diff.  
   🔹 [Project directory](06-infrastructure-as-code/09-terraform-drift-detection-alerting)

10. **Self-Service Cloud Sandbox Provisioning Portal**  
    🔹 Infrastructure self-service platform backend wrapping Terraform / OpenTofu modules behind a lightweight API/CLI, allowing developers to request ephemeral sandbox environments with automatic TTL expiration.  
    🧪 **Testing**: Send API request to provision an ephemeral environment; verify cloud resource creation, expiration timer trigger, and automatic `terraform destroy` upon TTL timeout.  
    🔹 [Project directory](06-infrastructure-as-code/10-self-service-cloud-sandbox-portal)

---

## 07. Cloud Providers & Serverless

1. **AWS IAM Least-Privilege and Role Boundaries**  
   🔹 AWS IAM architecture implementing least-privilege permission boundaries, role assumption policies with MFA conditions, and Service Control Policies (SCPs) for developer and CI/CD roles.  
   🧪 **Testing**: Use AWS IAM Policy Simulator to test permitted vs denied actions across S3, EC2, and KMS actions.  
   🔹 [Project directory](07-cloud-providers/01-aws-iam-least-privilege-policies)

2. **Secure Static Web Hosting with S3 and CloudFront**  
   🔹 High-performance static web hosting architecture using private AWS S3 bucket with CloudFront CDN, Origin Access Control (OAC), ACM SSL/TLS certificate, and custom security headers via CloudFront Functions.  
   🧪 **Testing**: Request site via CloudFront domain; verify HTTPS certificate, HTTP 200 response, security headers, and verify that direct S3 bucket access is blocked (403 Forbidden).  
   🔹 [Project directory](07-cloud-providers/02-s3-cloudfront-static-hosting)

3. **Event-Driven Serverless Pipeline with Lambda and SQS**  
   🔹 Serverless event-driven processing pipeline using AWS Lambda (Python/Go), SQS FIFO queues, and Dead Letter Queues (DLQ) with exponential backoff and CloudWatch error alarms.  
   🧪 **Testing**: Publish 100 messages to SQS queue including bad payloads; verify Lambda batches process valid events and bad payloads route to DLQ.  
   🔹 [Project directory](07-cloud-providers/03-serverless-pipeline-lambda-sqs)

4. **CloudWatch Alarms and SNS Incident Routing**  
   🔹 AWS CloudWatch monitoring infrastructure configuring composite alarms on CPU utilization, 5xx errors, and disk I/O, routing notifications via SNS topics to email and webhook endpoints.  
   🧪 **Testing**: Trigger test metric data using AWS CLI `put-metric-data`; verify alarm transition from `OK` to `ALARM` and verify SNS notification payload.  
   🔹 [Project directory](07-cloud-providers/04-cloudwatch-alarms-sns-routing)

5. **Multi-VPC Networking with Transit Gateway**  
   🔹 Multi-VPC networking architecture establishing AWS Transit Gateway / VPC Peering between Production, Staging, and Shared Services VPCs with strict route table isolation.  
   🧪 **Testing**: Launch EC2 instances in each VPC; verify ping connectivity between permitted subnets and complete packet drop between isolated tiers.  
   🔹 [Project directory](07-cloud-providers/05-multi-vpc-transit-gateway)

6. **High-Availability Auto Scaling EC2 Fleet behind ALB**  
   🔹 Fault-tolerant AWS Auto Scaling Group (ASG) behind an Application Load Balancer (ALB) across multiple AZs, with Launch Templates, dynamic scaling policies based on request count, and graceful instance termination lifecycle hooks.  
   🧪 **Testing**: Apply synthetic HTTP traffic load to ALB endpoint; verify ASG scales up new EC2 instances and scales down once traffic subsides.  
   🔹 [Project directory](07-cloud-providers/06-auto-scaling-ec2-alb-fleet)

7. **GCP Cloud Run Scalable Microservice**  
   🔹 Google Cloud Run microservice deployment with container concurrency settings, minimum/maximum instance scaling, Secret Manager integration, and custom domain mapping.  
   🧪 **Testing**: Deploy container to Cloud Run via `gcloud` / Terraform; test zero-scale cold start vs warm concurrency latency.  
   🔹 [Project directory](07-cloud-providers/07-gcp-cloud-run-microservice)

8. **Azure Functions Event Grid Blob Processor**  
   🔹 Azure Serverless pipeline with Azure Functions triggered by Event Grid events (blob uploads), performing image resizing/processing and saving metadata to Azure Cosmos DB.  
   🧪 **Testing**: Upload test file to Azure Blob Storage; verify Event Grid event trigger, function execution logs, and output record in Cosmos DB.  
   🔹 [Project directory](07-cloud-providers/08-azure-functions-eventgrid-processor)

9. **Cloud Cost Governance and Tag Compliance Engine**  
   🔹 Automated FinOps governance engine using AWS Lambda / Cloud Custodian to audit AWS/GCP resources for mandatory billing tags (`Environment`, `Owner`, `CostCenter`), flagging or stopping untagged non-compliant resources.  
   🧪 **Testing**: Provision an EC2 instance without mandatory tags; run governance script and verify compliance warning event and scheduled termination alert.  
   🔹 [Project directory](07-cloud-providers/09-cloud-cost-tagging-governance-engine)

10. **Multi-Region Disaster Recovery with Route 53 Failover**  
    🔹 Comprehensive AWS Disaster Recovery architecture implementing Route 53 DNS failover routing, cross-region DynamoDB global tables / S3 replication, and automated RTO/RPO validation runbook.  
    🧪 **Testing**: Simulate primary region outage by failing health check endpoint; verify Route 53 health check triggers DNS failover to secondary region within 60 seconds.  
    🔹 [Project directory](07-cloud-providers/10-multi-region-disaster-recovery-route53)

---

## 08. Monitoring & Observability

1. **Prometheus Node Exporter Monitoring Stack**  
   🔹 Prometheus server scraping Node Exporter metrics in Docker Compose, collecting host metrics (CPU, disk I/O, network traffic, memory) with custom scrape intervals.  
   🧪 **Testing**: Access Prometheus web UI (`:9090`), query `node_cpu_seconds_total` and `node_memory_MemAvailable_bytes`, and verify data scrapers return status `UP`.  
   🔹 [Project directory](08-observability-and-monitoring/01-prometheus-node-exporter-stack)

2. **Application RED and USE Metrics Instrumentation**  
   🔹 Web application (Go/Python/Node) instrumented with official Prometheus client library, exporting custom business metrics (counter for total orders, histogram for request duration, gauge for active connections) at `/metrics`.  
   🧪 **Testing**: Send simulated user requests; verify Prometheus scrapes and accurately computes request duration percentiles (`p95`, `p99`) and request rates (`rate()`).  
   🔹 [Project directory](08-observability-and-monitoring/02-application-metrics-instrumentation)

3. **Grafana Dashboards as Code Provisioning**  
   🔹 Grafana deployment utilizing Dashboards-as-Code (provisioning YAML and JSON model files), building comprehensive RED (Rate, Errors, Duration) and USE (Utilization, Saturation, Errors) method dashboards.  
   🧪 **Testing**: Spin up Grafana container; verify dashboards load automatically from disk without manual UI creation and all panels display active time-series data.  
   🔹 [Project directory](08-observability-and-monitoring/03-grafana-dashboards-as-code)

4. **Prometheus Alertmanager Routing and Slack Notifications**  
   🔹 Prometheus Alerting Rules configuration coupled with Alertmanager, featuring route trees, alert grouping, inhibition rules, deduplication, and rich notifications to Slack/Discord webhooks.  
   🧪 **Testing**: Trigger test alert condition (e.g. simulated high CPU / endpoint down); verify Alertmanager receives alert and posts formatted notification to webhook.  
   🔹 [Project directory](08-observability-and-monitoring/04-alertmanager-routing-slack)

5. **Blackbox Exporter Endpoint Uptime Probing**  
   🔹 Prometheus Blackbox Exporter configuration probing external endpoints over HTTP/HTTPS, DNS, TCP, and ICMP, monitoring SSL certificate expiration, response codes, and network latency.  
   🧪 **Testing**: Configure probes for public and internal targets; query `probe_success` and `probe_duration_seconds` metrics in Prometheus.  
   🔹 [Project directory](08-observability-and-monitoring/05-blackbox-exporter-uptime-probing)

6. **Distributed Tracing with OpenTelemetry and Jaeger**  
   🔹 Multi-tier microservices application instrumented with OpenTelemetry SDK, propagating W3C trace context (`traceparent`) across HTTP boundaries, and exporting traces to Jaeger for distributed visualization.  
   🧪 **Testing**: Execute end-to-end request traversing frontend, auth service, and database; view unified trace in Jaeger UI (`:16686`) and inspect span durations.  
   🔹 [Project directory](08-observability-and-monitoring/06-opentelemetry-distributed-tracing-jaeger)

7. **OpenTelemetry Collector Telemetry Pipeline**  
   🔹 OpenTelemetry Collector deployment with custom pipelines (receivers, processors: batch/memory_limiter/attributes, exporters) routing metrics to Prometheus and traces to Tempo/Jaeger.  
   🧪 **Testing**: Stream telemetry through collector; verify collector metrics and confirm processed telemetry data arrives at respective backend stores.  
   🔹 [Project directory](08-observability-and-monitoring/07-opentelemetry-collector-pipeline)

8. **VictoriaMetrics Long-Term Metric Storage**  
   🔹 High-performance long-term time-series storage setup using VictoriaMetrics as a remote-write destination for Prometheus, with data downsampling and retention policies.  
   🧪 **Testing**: Configure Prometheus `remote_write` to VictoriaMetrics; query metrics through VictoriaMetrics API and verify storage compression efficiency.  
   🔹 [Project directory](08-observability-and-monitoring/08-victoriametrics-long-term-storage)

9. **Kubernetes Observability with kube-prometheus-stack**  
   🔹 Full Kubernetes observability stack deployed via `kube-prometheus-stack` Helm chart, configuring ServiceMonitors, PodMonitors, PrometheusRules, and Grafana Operator.  
   🧪 **Testing**: Deploy a sample microservice with a custom `ServiceMonitor`; verify Prometheus Operator automatically discovers targets and scrapes endpoints.  
   🔹 [Project directory](08-observability-and-monitoring/09-kube-prometheus-stack-helm-k8s)

10. **Synthetic User Journey Monitoring with Playwright**  
    🔹 Continuous synthetic end-to-end monitoring service using Playwright/Puppeteer in headless containers, executing simulated user checkout workflows on a schedule and exporting latency and failure metrics to Prometheus.  
    🧪 **Testing**: Run synthetic suite against staging application; verify screenshot capture on test failure and Prometheus counter increment on step anomalies.  
    🔹 [Project directory](08-observability-and-monitoring/10-synthetic-journey-monitoring-playwright)

---

## 09. Centralized Logging & Log Aggregation

1. **Structured JSON Logging Framework**  
   🔹 Application logging framework setup (Go Zap / Python Loguru / Winston) enforcing structured JSON log formats with standard fields (`timestamp`, `level`, `trace_id`, `caller`, `message`, `context`).  
   🧪 **Testing**: Trigger various application actions and errors; verify stdout outputs valid JSON lines matching log schema.  
   🔹 [Project directory](09-logging/01-structured-json-logging-framework)

2. **Logrotate Daemon System Policy**  
   🔹 Custom `logrotate` configuration for application and web server log files managing daily rotation, size thresholds (`maxsize 100M`), compression (`gzip`), and post-rotate process reloading (`kill -HUP`).  
   🧪 **Testing**: Force log rotation using `logrotate -f /etc/logrotate.d/custom-app`; verify rotated `.1.gz` file creation and continuous uninterrupted logging.  
   🔹 [Project directory](09-logging/02-logrotate-daemon-system-policy)

3. **Docker Daemon Logging Drivers and Fluentd**  
   🔹 Docker daemon logging configuration routing container stdout/stderr through the `fluentd` or `syslog` logging driver, preventing local disk filling and centralizing log delivery.  
   🧪 **Testing**: Run container producing rapid logs; verify logs stream directly to the centralized receiver while host container log json files stay constrained.  
   🔹 [Project directory](09-logging/03-docker-logging-drivers-fluentd)

4. **Promtail, Loki, and Grafana LogQL Pipeline**  
   🔹 Lightweight log aggregation pipeline using Grafana Loki and Promtail, scraping container and system log files, parsing log labels, and querying logs in Grafana using LogQL.  
   🧪 **Testing**: Emit error logs with custom metadata; query `{app="api"} |= "error"` in Grafana Explore and verify sub-second log query response.  
   🔹 [Project directory](09-logging/04-promtail-loki-grafana-logql)

5. **Fluent Bit Kubernetes Log DaemonSet**  
   🔹 Fluent Bit deployed as a Kubernetes DaemonSet, extracting container logs from `/var/log/containers/`, enriching logs with Kubernetes metadata (pod, namespace, container name), and forwarding to Loki / Elasticsearch.  
   🧪 **Testing**: Deploy test pods across multiple nodes; verify log entries in the backend store contain accurate Kubernetes labels and metadata annotations.  
   🔹 [Project directory](09-logging/05-fluent-bit-kubernetes-daemonset)

6. **ELK Stack with Logstash Grok Parsers**  
   🔹 Complete ELK Stack deployment (Elasticsearch, Logstash, Kibana) in Docker Compose, configuring Logstash pipelines with Grok filters to parse unstructured legacy server logs into indexed fields.  
   🧪 **Testing**: Feed raw Apache/Nginx access logs to Logstash input; verify Elasticsearch index creation and Kibana index pattern visualization.  
   🔹 [Project directory](09-logging/06-elk-stack-logstash-grok-parsers)

7. **Vector Log Sanitization and PII Masking**  
   🔹 High-performance observability data pipeline using Datadog Vector, performing in-flight log sanitization, PII (Personally Identifiable Information) masking (credit cards, emails), and log sampling.  
   🧪 **Testing**: Stream logs containing mock SSNs and credit card numbers; verify Vector transforms sensitive fields to `[REDACTED]` before forwarding downstream.  
   🔹 [Project directory](09-logging/07-vector-log-sanitization-pii-masking)

8. **OpenSearch Index Lifecycle Management (ISM)**  
   🔹 OpenSearch cluster configuration with Index State Management (ISM) policies defining hot-warm-cold storage tiering, automated rollover, and scheduled index deletion after 30 days.  
   🧪 **Testing**: Apply ISM policy; simulate index aging and verify that indices transition automatically from hot to warm read-only tiers.  
   🔹 [Project directory](09-logging/08-opensearch-index-lifecycle-management)

9. **Log-Based Metrics Extraction and Alerting**  
   🔹 Loki LogQL metric queries and Fluent Bit metric filters extracting real-time Prometheus metrics from raw log streams (e.g. counting 5xx errors per minute from Nginx logs) to trigger alerts.  
   🧪 **Testing**: Inject 500 error logs into stream; verify Loki/Prometheus generates alert metric and Alertmanager fires threshold alert.  
   🔹 [Project directory](09-logging/09-log-based-metrics-extraction-alerting)

10. **Auditd Linux Security Event Log Analysis**  
    🔹 Linux Audit Framework (`auditd`) setup monitoring critical system calls (`execve`, file modifications in `/etc/passwd`, `/etc/sudoers`), shipping audit logs to a SIEM / OpenSearch instance for real-time security analysis.  
    🧪 **Testing**: Trigger unauthorized file write or privilege escalation command; verify `audit.log` records event and SIEM dashboard flags the security alert.  
    🔹 [Project directory](09-logging/10-auditd-security-event-logging-analysis)

---

## 10. SRE, Reliability & Incident Response

1. **SLI, SLO, and Error Budget Calculator**  
   🔹 Tool in Python/Go that queries Prometheus metrics over rolling 30-day windows, calculates Service Level Indicators (SLIs), Service Level Objectives (SLOs, e.g. 99.9% availability), and remaining Error Budgets.  
   🧪 **Testing**: Feed synthetic availability time-series data; verify SLI percentage calculation, error budget burn rate computation, and markdown report output.  
   🔹 [Project directory](10-sre-and-reliability/01-sli-slo-error-budget-calculator)

2. **Multiwindow Multi-Burn-Rate Alerting Rules**  
   🔹 Implementation of Google SRE Multiwindow Multi-Burn-Rate alerting rules in Prometheus, calculating 14.4x (1hr), 6x (6hr), and 1x (3-day) burn rates to eliminate alert fatigue while catching catastrophic outages early.  
   🧪 **Testing**: Inject simulated outage metrics into Prometheus; verify that fast burn rate alerts fire within 2 minutes while slow burn alerts trigger appropriately over longer windows.  
   🔹 [Project directory](10-sre-and-reliability/02-multiwindow-multi-burn-rate-alerts)

3. **Automated Incident Runbook Executor**  
   🔹 Automated incident remediation engine triggered by PagerDuty / Webhook alerts, executing self-healing runbook tasks (restarting hung workers, clearing stuck queues) via secure SSH/Kubernetes APIs.  
   🧪 **Testing**: Send simulated PagerDuty webhook event; verify runbook executor runs target remediation script, logs output, and resolves incident.  
   🔹 [Project directory](10-sre-and-reliability/03-automated-incident-runbook-executor)

4. **k6 Distributed Performance and Stress Testing**  
   🔹 Comprehensive load and stress testing suite using Grafana k6, defining ramping arrival rate scenarios, threshold assertions (`p99 < 200ms`, `error_rate < 1%`), and exporting metrics to InfluxDB/Grafana.  
   🧪 **Testing**: Run `k6 run load-test.js` against target service; verify test execution through ramp-up, peak, and recovery phases, and check threshold exit codes.  
   🔹 [Project directory](10-sre-and-reliability/04-k6-performance-load-testing-suite)

5. **Container Chaos Engineering with Pumba**  
   🔹 Chaos testing framework using Pumba / Chaos Mesh for Docker containers, injecting random network latency, packet loss, paused containers, and forced SIGKILLs against microservices.  
   🧪 **Testing**: Run chaos experiment during continuous load test; verify application handles pod failures gracefully with circuit breakers without crashing.  
   🔹 [Project directory](10-sre-and-reliability/05-container-chaos-engineering-pumba)

6. **Circuit Breaker and Resilient Retry Engine**  
   🔹 Microservice resilience implementation in Go/Node.js utilizing the Circuit Breaker pattern (Closed, Open, Half-Open states), fallback responses, and exponential backoff retry mechanisms.  
   🧪 **Testing**: Simulate downstream API failure; assert that circuit breaker trips to Open state after consecutive errors and serves fallback responses without downstream calls.  
   🔹 [Project directory](10-sre-and-reliability/06-circuit-breaker-resilience-pattern)

7. **Kubernetes Chaos Mesh Fault Injection**  
   🔹 Chaos Mesh deployment on Kubernetes executing declarative Chaos Experiments (`PodChaos`, `NetworkChaos`, `IOChaos`, `TimeChaos`) to validate cluster self-healing and service mesh resiliency.  
   🧪 **Testing**: Apply `pod-kill` chaos experiment manifest; verify Kubernetes scheduler restarts pods and service availability remains >99.9% during the experiment.  
   🔹 [Project directory](10-sre-and-reliability/07-kubernetes-chaos-mesh-fault-injection)

8. **Incident Timeline and Postmortem Generator**  
   🔹 Incident management tool that aggregates Git commits, Slack incident channel messages, Prometheus alert timestamps, and PagerDuty logs into a structured Markdown Postmortem document with Root Cause Analysis (RCA) and Action Items.  
   🧪 **Testing**: Run generator with incident timeframe; verify timeline reconstruction, metrics snapshot inclusion, and markdown postmortem generation.  
   🔹 [Project directory](10-sre-and-reliability/08-incident-timeline-postmortem-generator)

9. **Graceful Shutdown and Connection Draining**  
   🔹 Application lifecycle and Kubernetes `preStop` hook configuration implementing zero-downtime graceful shutdowns, finishing in-flight requests, closing database pools, and unregistering from service discovery.  
   🧪 **Testing**: Send SIGTERM signal to application during active HTTP request stream; verify in-flight connections complete while new connections are cleanly rejected or rerouted.  
   🔹 [Project directory](10-sre-and-reliability/09-graceful-shutdown-connection-draining)

10. **Automated Disaster Recovery GameDay Simulator**  
    🔹 Automated GameDay orchestration script that simulates total zone failure, orchestrating database failover, DNS traffic shift, and state reconciliation while continuously measuring Recovery Time Objective (RTO) and Recovery Point Objective (RPO).  
    🧪 **Testing**: Trigger game day script in staging environment; record automated failover timeline, assert zero data loss, and verify RTO under 3 minutes.  
    🔹 [Project directory](10-sre-and-reliability/10-disaster-recovery-gameday-simulator)

---

## 11. Security & DevSecOps

1. **Pre-Commit Git Secrets Detection Suite**  
   🔹 Git pre-commit hook suite using Gitleaks and detect-secrets to prevent accidental commits of API keys, private certificates, AWS credentials, and environment tokens into version control.  
   🧪 **Testing**: Attempt to stage and commit a file containing a dummy private key or AWS access key; verify pre-commit hook blocks the commit.  
   🔹 [Project directory](11-security-devsecops/01-pre-commit-secrets-detection)

2. **Container Image Vulnerability Scanning with Trivy**  
   🔹 Automated container scanning pipeline using Trivy, scanning Docker images for OS package vulnerabilities, language-specific dependencies (SCA), and misconfigurations, generating SARIF reports.  
   🧪 **Testing**: Scan a known vulnerable image; verify Trivy identifies CVEs, filters by severity (CRITICAL/HIGH), and returns non-zero exit code when policy fails.  
   🔹 [Project directory](11-security-devsecops/02-container-vulnerability-scanning-trivy)

3. **IaC Security Scanning with Checkov and tfsec**  
   🔹 Infrastructure as Code security scanning setup using Checkov and tfsec, evaluating Terraform, Dockerfiles, and Kubernetes manifests against CIS Benchmarks and compliance rules.  
   🧪 **Testing**: Run scanner against an unencrypted S3 bucket or overly permissive security group manifest; assert that Checkov flags violations and fails CI build.  
   🔹 [Project directory](11-security-devsecops/03-iac-security-scanning-checkov-tfsec)

4. **HashiCorp Vault Secrets Engine Deployment**  
   🔹 HashiCorp Vault server deployed locally in Docker with KV version 2 secrets engine, AppRole authentication, dynamic secret generation, and token renewal policies.  
   🧪 **Testing**: Authenticate using AppRole credentials via CLI/API, write secret, retrieve secret with short-lived token, and verify token revocation.  
   🔹 [Project directory](11-security-devsecops/04-hashicorp-vault-secrets-engine)

5. **Vault Agent Sidecar Secret Injector for Kubernetes**  
   🔹 Vault Agent Sidecar Injector configuration on Kubernetes, dynamically mounting secrets into application pod memory at `/vault/secrets/` with template-based rendering and automated pod reloads.  
   🧪 **Testing**: Deploy application pod with Vault annotations; verify sidecar container injects decrypted secrets and updates them upon Vault secret rotation.  
   🔹 [Project directory](11-security-devsecops/05-vault-agent-sidecar-injector-k8s)

6. **Container Image Signing and SBOM with Cosign**  
   🔹 Container supply-chain security pipeline using Sigstore Cosign to sign container images with keyless OIDC authentication, generate Software Bill of Materials (SBOM) with Syft, and attach SBOM attestations.  
   🧪 **Testing**: Sign container image, verify signature using `cosign verify`, and validate that unsigned images cannot be pulled in admission controller.  
   🔹 [Project directory](11-security-devsecops/06-cosign-image-signing-sbom)

7. **Kubernetes Admission Control with Kyverno & Gatekeeper**  
   🔹 Kubernetes Admission Controller policies using Kyverno / OPA Gatekeeper enforcing security policies: disallowing privileged containers, enforcing read-only root filesystems, requiring non-root UIDs, and mandating resource limits.  
   🧪 **Testing**: Attempt to deploy a pod requesting `privileged: true` or `latest` image tag; verify admission controller denies deployment with descriptive error message.  
   🔹 [Project directory](11-security-devsecops/07-kyverno-gatekeeper-admission-policies)

8. **Runtime Threat Detection with Falco and eBPF**  
   🔹 Cloud-native runtime security monitoring using Falco deployed on Linux host / Kubernetes, capturing kernel system calls via eBPF to detect unauthorized shell spawns inside containers and sensitive directory writes.  
   🧪 **Testing**: Execute `bash` inside a running container or touch `/etc/shadow`; verify Falco generates critical security alert to syslog and alert webhook.  
   🔹 [Project directory](11-security-devsecops/08-runtime-threat-detection-falco-ebpf)

9. **Automated SSL/TLS Cipher Hardening Audit**  
   🔹 Automated TLS security analyzer script running `testssl.sh` / Python SSL scanner against public and internal web endpoints, verifying cipher suite strength, disabling SSLv3/TLS 1.0/1.1, and auditing certificate chains.  
   🧪 **Testing**: Run audit against test server with weak ciphers enabled; verify tool outputs vulnerability warnings and generates compliance scorecard.  
   🔹 [Project directory](11-security-devsecops/09-automated-ssl-tls-hardening-audit)

10. **Zero-Trust Service Mesh mTLS with Istio**  
    🔹 Istio Service Mesh deployment enforcing STRICT Mutual TLS (mTLS) between all microservices, SPIFFE identity verification, and fine-grained AuthorizationPolicies based on source service identities.  
    🧪 **Testing**: Attempt unauthorized plaintext connection between services; verify mTLS rejects unauthenticated traffic while authorized services communicate over encrypted TLS tunnel.  
    🔹 [Project directory](11-security-devsecops/10-zero-trust-service-mesh-istio-mtls)

---

## 12. Database Operations & Resilience

1. **Automated PostgreSQL Backup and Restore Validation**  
   🔹 Bash/Python automated backup utility executing `pg_dump` with compression, timestamping, checksum generation, retention pruning, and a verified test restore script into a temporary database container.  
   🧪 **Testing**: Seed test database with records, run backup script, execute restore script into clean instance, and assert row count equality.  
   🔹 [Project directory](12-databases-ops/01-automated-postgres-backup-restore)

2. **PostgreSQL Streaming Replication Cluster**  
   🔹 High-availability PostgreSQL cluster configuration using Docker Compose with physical streaming replication (Primary-Replica), WAL (Write-Ahead Logging) archiving, and read-only query routing.  
   🧪 **Testing**: Insert data on primary instance; query replica instance and assert immediate data consistency with near-zero replication lag (`pg_stat_replication`).  
   🔹 [Project directory](12-databases-ops/02-postgres-streaming-replication-cluster)

3. **Database Migration Pipeline with Version Locking**  
   🔹 Automated database schema migration pipeline using `golang-migrate` / Flyway integrated into CI/CD, managing transactional forward (`up`) and backward (`down`) SQL migrations with version locking.  
   🧪 **Testing**: Run migration `up` to create tables and indexes, insert data, run migration `down`, and verify schema returns cleanly to initial state.  
   🔹 [Project directory](12-databases-ops/03-database-migration-pipeline-version-locking)

4. **PgBouncer Connection Pooling and Tuning**  
   🔹 PgBouncer connection pooler deployment in front of PostgreSQL, configuring transaction-level pooling, max client connections, pool reserve settings, and monitoring stats via `SHOW POOLS`.  
   🧪 **Testing**: Run concurrency benchmark with 500 simulated client connections; verify PgBouncer handles concurrency without exhausting PostgreSQL max connections limit.  
   🔹 [Project directory](12-databases-ops/04-pgbouncer-connection-pooling-tuning)

5. **Redis Sentinel High Availability and Failover**  
   🔹 Redis Sentinel cluster setup (1 Master, 2 Replicas, 3 Sentinels) providing automatic failover, health monitoring, and client reconnection handling.  
   🧪 **Testing**: Forcefully stop Master node; verify Sentinel quorum elects a Replica as new Master within 5 seconds and cluster accepts write commands.  
   🔹 [Project directory](12-databases-ops/05-redis-sentinel-ha-failover)

6. **MySQL Point-in-Time Recovery (PITR) Lab**  
   🔹 Disaster recovery lab for MySQL / MariaDB implementing Point-In-Time Recovery (PITR) using full physical backups and binary logs (`mysqlbinlog`) to recover data to an exact second before accidental `DROP TABLE`.  
   🧪 **Testing**: Perform backup, insert transactions, execute accidental drop table, run PITR recovery procedure, and verify all transactions up to the drop second are recovered.  
   🔹 [Project directory](12-databases-ops/06-mysql-point-in-time-recovery-pitr)

7. **Database Slow Query Analyzer with pgBadger**  
   🔹 Automated query performance analyzer configuring PostgreSQL `log_min_duration_statement` and `pg_stat_statements`, generating daily HTML and JSON performance reports using `pgBadger`.  
   🧪 **Testing**: Execute unindexed queries under synthetic load; run analyzer and verify that slow queries, missing indexes, and lock contentions are highlighted in report.  
   🔹 [Project directory](12-databases-ops/07-database-slow-query-analyzer-pgbadger)

8. **CloudNative-PG Operator on Kubernetes**  
   🔹 Kubernetes database management using CloudNative-PG / Zalando Postgres Operator, provisioning self-healing clusters with automated failover, WAL archiving to S3, and replica scaling.  
   🧪 **Testing**: Deploy cluster CRD; terminate primary pod with `kubectl delete pod`; verify operator promotes replica to primary and provisions new standby replica.  
   🔹 [Project directory](12-databases-ops/08-cloudnative-pg-operator-k8s)

9. **Data Anonymization and PII Masking Pipeline**  
   🔹 ETL data masking pipeline in Python/SQL that sanitizes production database dumps before importing into staging/dev environments, hashing emails, obfuscating credit cards, and faking PII while preserving referential integrity.  
   🧪 **Testing**: Run masking script on sample production dataset; verify no raw PII remains while foreign key constraints and dataset volume remain valid.  
   🔹 [Project directory](12-databases-ops/09-data-anonymization-pii-masking-pipeline)

10. **Zero-Downtime Expand and Contract Schema Refactoring**  
    🔹 Blue-green zero-downtime database schema refactoring implementing the Expand-and-Contract (Parallel Run) pattern (column rename / table split) with triggers and dual-writing application layer.  
    🧪 **Testing**: Run continuous read/write load during all 3 migration phases (expand, dual-write, contract); verify zero transaction failures and zero downtime.  
    🔹 [Project directory](12-databases-ops/10-zero-downtime-schema-refactoring)
