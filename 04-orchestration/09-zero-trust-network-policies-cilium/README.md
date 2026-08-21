<!-- markdownlint-disable MD013 -->
# Mini-Project 09: Zero-Trust Network Policies with Cilium CNI

> **Domain**: 04. Kubernetes & Orchestration  
> **Level**: Advanced  
> **Infrastructure**: Local (K3d / K3s / OrbStack / Minikube / Kind + Cilium CNI / NetworkPolicy Engine)  

---

## 🎯 Overview & Context

In a default Kubernetes cluster, the network model is completely **flat**: any pod in
any namespace can communicate directly with any other pod across the cluster. If an attacker
exploits a vulnerability in a public-facing frontend web application, they can immediately
move laterally to access internal databases, cache clusters, and sensitive microservices.

**Zero-Trust Network Architecture** operates on the core principle:
> *"Never Trust, Always Verify. Assume Breach and Enforce Least-Privilege Micro-Segmentation."*

This mini-project implements end-to-end Zero-Trust network security using **Cilium CNI**
and native Kubernetes network security policies. We enforce:

- **Default-Deny Ingress & Egress**: Every cross-namespace packet is dropped unless
  explicitly allowed.
- **Layer 7 HTTP Path/Method Filtering**: The Frontend can only send `POST /api` requests
  to the Backend; administrative paths (`/admin`) are blocked at the kernel/proxy layer.
- **Layer 4 TCP Filtering**: The Database only accepts incoming traffic on port `5432`
  from the authorized Backend tier. Direct Frontend or Attacker connections are dropped.
- **Egress Perimeter Isolation**: Workloads are prevented from establishing outbound
  connections to unauthorized public internet CIDRs.

```mermaid
flowchart TD
    subgraph UntrustedZone ["💀 Untrusted Tenant (tenant-untrusted)"]
        AttackerPod["rogue-attacker\n(Simulated Adversary Pod)"]
    end

    subgraph FrontendZone ["🌐 Frontend Tenant (tenant-frontend)"]
        FrontendPod["frontend-app\n(Public-Facing Proxy)"]
    end

    subgraph BackendZone ["⚙️ Backend Tenant (tenant-backend)"]
        BackendPod["backend-api\n(Core Business Logic)"]
    end

    subgraph DatabaseZone ["🗄️ Database Tenant (tenant-database)"]
        DatabasePod["relational-db\n(TCP 5432 Data Layer)"]
    end

    %% Allowed Traffic Flows
    FrontendPod -->|✅ ALLOWED: POST /api (L7 HTTP)| BackendPod
    BackendPod -->|✅ ALLOWED: TCP 5432 (L4 Postgres)| DatabasePod

    %% Blocked Traffic Flows
    FrontendPod -.-x|🚫 BLOCKED: GET /admin (L7 Filter)| BackendPod
    FrontendPod -.-x|🚫 BLOCKED: Direct DB Access (L4)| DatabasePod
    AttackerPod -.-x|🚫 BLOCKED: Cross-Tenant Ingress| BackendPod
    AttackerPod -.-x|🚫 BLOCKED: Direct DB Access| DatabasePod
    BackendPod -.-x|🚫 BLOCKED: Egress to Unknown CIDRs| ExternalWorld["🌍 Public Internet (CIDR Drop)"]
```

---

## 🧠 Zero-Trust Micro-Segmentation & Cilium Mechanics Deep-Dive

### 1. Standard Kubernetes `NetworkPolicy` vs `CiliumNetworkPolicy`

| Security Capability | Standard `NetworkPolicy` (`networking.k8s.io/v1`) | `CiliumNetworkPolicy` (`cilium.io/v2`) |
| :--- | :--- | :--- |
| **Layer 3/4 Filtering** | ✅ IP, CIDR, Port, Protocol (TCP/UDP) | ✅ High-performance eBPF in kernel space |
| **Layer 7 Application Filtering** | ❌ None (No HTTP path/method/header awareness) | ✅ Native HTTP (`GET`, `POST`, regex paths), gRPC, Kafka |
| **DNS-Aware Egress** | ❌ IP-only (breaks with dynamic CDN IPs) | ✅ FQDN matching (`*.amazonaws.com`, `api.github.com`) |
| **Entity-Based Policies** | ❌ Pod/Namespace selectors only | ✅ `world`, `cluster`, `host`, `remote-node` entities |
| **Enforcement Engine** | iptables / IPVS (kernel connection tracking) | **eBPF (Extended Berkeley Packet Filter)** |

---

### 2. Layer 7 HTTP Policy Anatomy

`CiliumNetworkPolicy` allows inspecting and restricting application-layer payloads
without sidecar proxies:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-l7-policy
  namespace: tenant-backend
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": tenant-frontend
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api"
              - method: "GET"
                path: "/healthz"
```

Any request attempting to access `/admin` or using an unauthorized HTTP method
(e.g. `DELETE` or `PUT`) is immediately rejected before touching application code.

---

### 3. Default-Deny Security Model

In Zero-Trust, every namespace begins with a `default-deny` policy for both ingress
and egress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-database
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

---

## 📂 Project Structure

```text
04-orchestration/09-zero-trust-network-policies-cilium/
├── services/
│   ├── backend/main.go       # Go REST backend exposing POST /api and restricted /admin
│   ├── database/main.go      # Go TCP relational store listening on port 5432
│   ├── frontend/main.go      # Go frontend proxy with interactive diagnostic routes
│   └── go.mod                # Unified Go module definition
├── Dockerfile                # Hardened multi-stage container build (<20MB Alpine)
├── .dockerignore             # Clean build context filter
├── install/
│   └── cilium-crds.yaml      # Bundled official CiliumNetworkPolicy CRDs
├── namespaces.yaml           # Multi-tenant isolated namespaces
├── workloads/
│   ├── frontend.yaml         # Frontend deployment & service (tenant-frontend)
│   ├── backend.yaml          # Backend deployment & service (tenant-backend)
│   ├── database.yaml         # Database deployment & service (tenant-database)
│   └── attacker.yaml         # Rogue attacker pod (tenant-untrusted)
├── policies/
│   ├── cilium-policies.yaml  # CiliumNetworkPolicy with L7 HTTP rules & L4 Postgres rules
│   └── k8s-network-policies.yaml # Standard NetworkPolicies with default-deny & DNS rules
├── network_policy_test.sh    # Interactive 7-point connectivity matrix verification tool
├── test_zero_trust.sh        # Automated 12-point end-to-end verification test suite
├── cleanup.sh                # Complete environment teardown script
└── README.md                 # Pedagogical guide, network matrix & operational manual
```

---

## 🚀 Quickstart: Deploy, Secure & Test

### Prerequisites

- **Docker Engine / OrbStack**: Running and accessible (`docker info`).
- **Kubernetes CLI (`kubectl`)**: Configured and connected (`kubectl cluster-info`).
- **Active Cluster**: Any local Kubernetes cluster (K3d, K3s, OrbStack, Minikube, Kind).

---

### Step 1: Register Cilium Custom Resource Definitions (CRDs)

Apply the bundled Cilium CRDs to enable `CiliumNetworkPolicy` resources:

```bash
kubectl apply -f install/cilium-crds.yaml
```

---

### Step 2: Build and Import Container Images

Build the multi-tier microservice image:

```bash
docker build -t zero-trust-app:latest .
```

> **Note for K3d / Minikube / Kind users**:  
> Import the built image into your cluster runtime:
>
> ```bash
> # For k3d:
> k3d image import zero-trust-app:latest -c <cluster-name>
>
> # For minikube:
> minikube image load zero-trust-app:latest
>
> # For kind:
> kind load docker-image zero-trust-app:latest
> ```

---

### Step 3: Deploy Multi-Tenant Namespaces & Workloads

Create the isolated tenant namespaces and deploy the 3-tier microservices along with
the simulated rogue attacker pod:

```bash
kubectl apply -f namespaces.yaml
kubectl apply -f workloads/frontend.yaml
kubectl apply -f workloads/backend.yaml
kubectl apply -f workloads/database.yaml
kubectl apply -f workloads/attacker.yaml
```

Verify that all pods are active and ready:

```bash
kubectl get pods -A -l 'tier in (frontend, backend, database, attacker)'
```

---

### Step 4: Apply Zero-Trust Network Policies

Enforce default-deny, L7 HTTP filtering, and L4 database isolation:

```bash
kubectl apply -f policies/cilium-policies.yaml
kubectl apply -f policies/k8s-network-policies.yaml
```

---

## 🧪 Testing with Network Policy Matrix Auditor

The project includes an interactive audit tool: `network_policy_test.sh`.

```bash
./network_policy_test.sh
```

### 7-Point Security Matrix Evaluated

| Probe # | Source $\rightarrow$ Destination | Scope & Protocol | Expected Policy Action |
| :--- | :--- | :--- | :--- |
| **01** | `frontend` $\rightarrow$ `backend` | `POST /api` (HTTP 8080) | ✅ **ALLOWED** (HTTP 200) |
| **02** | `frontend` $\rightarrow$ `backend` | `GET /admin` (HTTP 8080) | 🚫 **BLOCKED** (HTTP 403 / Dropped) |
| **03** | `frontend` $\rightarrow$ `database` | `TCP 5432` (Direct SQL) | 🚫 **BLOCKED** (Lateral movement dropped) |
| **04** | `backend` $\rightarrow$ `database` | `TCP 5432` (Authorized SQL) | ✅ **ALLOWED** (TCP Connection OK) |
| **05** | `rogue-attacker` $\rightarrow$ `backend` | `POST /api` (Cross-Tenant) | 🚫 **BLOCKED** (Untrusted ingress dropped) |
| **06** | `rogue-attacker` $\rightarrow$ `database` | `TCP 5432` (Data Breach) | 🚫 **BLOCKED** (Untrusted ingress dropped) |
| **07** | `backend` $\rightarrow$ `1.1.1.1:80` | Public Internet Egress | 🚫 **BLOCKED** (Egress perimeter isolated) |

Sample output:

```text
======================================================================
  🛡️  Zero-Trust Connectivity Matrix & Network Policy Auditor
======================================================================
▶ Locating active pods in tenant namespaces...
  [OK] Frontend Pod : frontend-67f78b54-x9q4p (tenant-frontend)
  [OK] Backend Pod  : backend-5884fc57b-7km2v (tenant-backend)
  [OK] Database Pod : database-847b85f67-8l9mp (tenant-database)
  [OK] Attacker Pod : rogue-attacker-7db8b7-w4f9c (tenant-untrusted)

▶ Executing Zero-Trust Connectivity Probes...

  [PASS] Probe 01: Frontend -> Backend POST /api (Authorized L7 Path)
         ↳ Expected: HTTP 200 | Actual: HTTP 200
  [PASS] Probe 02: Frontend -> Backend GET /admin (Restricted L7 Path)
         ↳ Expected: HTTP 403 / Dropped | Actual: HTTP 403
  [PASS] Probe 03: Frontend -> Database TCP 5432 (Unauthorized Lateral Access)
         ↳ Expected: Connection Dropped / Refused | Actual: Blocked (Connection Dropped)
  [PASS] Probe 04: Backend -> Database TCP 5432 (Authorized Data Tier Access)
         ↳ Expected: Connection Allowed | Actual: Connected (TCP Handshake OK)
  [PASS] Probe 05: Attacker -> Backend POST /api (Untrusted Cross-Tenant Ingress)
         ↳ Expected: Connection Dropped (000) | Actual: Response: 000
  [PASS] Probe 06: Attacker -> Database TCP 5432 (Untrusted Data Access)
         ↳ Expected: Connection Dropped / Refused | Actual: Blocked (Connection Dropped)
  [PASS] Probe 07: Backend -> External Internet CIDR (Egress Perimeter Isolation)
         ↳ Expected: Egress Dropped | Actual: Blocked (Egress Dropped)

======================================================================
📊 ZERO-TRUST NETWORK AUDIT REPORT
======================================================================
  Authorized Frontend -> Backend (POST /api) : PASSED
  L7 HTTP Restricted Path (GET /admin)       : BLOCKED
  Lateral Movement (Frontend -> Database)    : BLOCKED
  Authorized Backend -> Database (TCP 5432)   : PASSED
  Untrusted Attacker Isolation               : BLOCKED
======================================================================
  Probes Summary: 7 Passed, 0 Failed (Total: 7)
======================================================================
✅ ZERO-TRUST MICRO-SEGMENTATION VERIFIED!
```

---

## ⚡ Automated End-to-End Test Suite

Run the full 12-point automated verification suite:

```bash
./test_zero_trust.sh
```

### Verification Matrix

| # | Test Case Description | Scope & Verification Method |
| :--- | :--- | :--- |
| **01** | Docker Daemon Availability | Validates Docker engine is running. |
| **02** | Kubernetes Cluster Connectivity | Validates API server reachability. |
| **03** | Cilium CRD Registration | Verifies `ciliumnetworkpolicies.cilium.io` is registered. |
| **04** | Container Image Build | Builds `<20MB` multi-microservice image (`zero-trust-app`). |
| **05** | Declarative Manifest Dry-Run | Runs `kubectl apply --dry-run=client` on all YAMLs. |
| **06** | Multi-Tenant Provisioning | Creates `tenant-frontend`, `tenant-backend`, `tenant-database`, `tenant-untrusted`. |
| **07** | Workload Readiness | Verifies 4 deployments reach 100% ready state. |
| **08** | Policy Application | Applies Cilium & Kubernetes NetworkPolicy rules. |
| **09** | 7-Point Matrix Verification | Runs `network_policy_test.sh` asserting all 7 probes pass. |
| **10** | End-to-End API Transaction | Validates Frontend proxy forwards `POST /api` to Backend. |
| **11** | Direct DB Access Rejection | Confirms direct Frontend $\rightarrow$ Database connection is dropped. |
| **12** | Complete Resource Teardown | Validates `cleanup.sh` removes all namespaces and images. |

---

## 🧹 Complete Resource Teardown & Cleanup

To leave your local environment completely clean for subsequent mini-projects, execute:

```bash
./cleanup.sh
```

### Manual Cleanup Commands

```bash
# 1. Terminate active port-forward tunnels
pkill -f "port-forward.*tenant" || true

# 2. Delete tenant namespaces (cascades Deployments, Services, and Policies)
kubectl delete namespace tenant-frontend tenant-backend tenant-database tenant-untrusted --ignore-not-found=true

# 3. Remove local Docker image
docker rmi -f zero-trust-app:latest

# 4. (Optional) Delete temporary test cluster if created
k3d cluster delete cilium-test
```

---

## 📚 SRE & DevSecOps Best Practices for Zero-Trust Networking

1. **Always Implement Default-Deny First**: When provisioning any new namespace in
   production, automatically apply a default-deny ingress and egress policy via GitOps.
2. **Combine L4 and L7 Rules**: Use Layer 4 port matching for databases and cache engines,
   and Layer 7 HTTP/gRPC matching for REST APIs to prevent path transversal and method injection.
3. **Always Allow DNS Egress to CoreDNS**: Forgetting to allow UDP/TCP port `53` egress
   to `kube-system` will cause DNS lookup timeouts across your microservices.
4. **Audit Before Enforce with Cilium Monitor**: In production, leverage `cilium monitor`
   and Hubble UI to inspect live network flows in audit mode before transitioning
   policies to strict enforcement.
