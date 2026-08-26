<!-- markdownlint-disable MD013 -->
# Mini-Project 14: Static Pods and Control Plane Bootstrap Diagnostics

> **Domain**: 04. Kubernetes & Orchestration  
> **Level**: Intermediate  
> **Infrastructure**: Local (K3d / Kind / OrbStack Linux VM / Minikube) or Bare-Metal Linux VM  

---

## 🎯 Overview & Context

In standard Kubernetes operations, application workloads (`Deployments`, `StatefulSets`, `DaemonSets`) are created by submitting YAML manifests to the `kube-apiserver`, stored in the `etcd` distributed database, and scheduled onto worker nodes by `kube-scheduler`.

However, this raises a fundamental **"Chicken-and-Egg" paradox**:

> *If the Kubernetes API Server, etcd, Controller Manager, and Scheduler run inside containers, how does Kubernetes deploy and supervise those control-plane components before the API server itself exists?*

The answer is **Static Pods**.

A **Static Pod** is a pod managed directly by the node's local `kubelet` agent, without the API Server or `kube-scheduler` having to observe or schedule it. The `kubelet` continuously monitors a designated local directory on the host filesystem (typically `/etc/kubernetes/manifests` or `/var/lib/rancher/k3s/agent/pod-manifests`). Whenever a YAML manifest is dropped into that directory, `kubelet` immediately starts and supervises the container via the Container Runtime Interface (CRI).

```mermaid
flowchart TD
    subgraph HostFilesystem ["📁 Host Operating System (/etc/kubernetes/manifests)"]
        Manifest1["etcd.yaml"]
        Manifest2["kube-apiserver.yaml"]
        Manifest3["kube-controller-manager.yaml"]
        Manifest4["static-diagnostics-web.yaml"]
    end

    subgraph NodeKubelet ["⚙️ Node-Level Kubelet Daemon"]
        FileWatcher["Inotify / Directory Polling Loop"]
        CRISupervisor["Container Runtime Interface (CRI / containerd)"]
        MirrorCreator["Mirror Pod Sync Engine"]
        
        FileWatcher -->|Detects YAML file| CRISupervisor
        CRISupervisor -->|Spawns Container| LocalPod["Running Static Pod Container\n(Restarts automatically on crash)"]
        FileWatcher -->|Posts Mirror Definition| MirrorCreator
    end

    subgraph APIServerLayer ["🌐 Kubernetes API Server (Cluster View)"]
        MirrorPod["Mirror Pod (Read-Only Representation)\n• Name: static-diagnostics-web-node0\n• OwnerReferences: null"]
    end

    Manifest4 --> FileWatcher
    MirrorCreator -->|Syncs status (Read-Only)| MirrorPod
    Client["DevOps Engineer / Kubectl"] -.->|kubectl delete pod (Ignored by Kubelet)| MirrorPod
```

---

## 🧠 Core Static Pod Architectural Concepts

### 1. Static Pods vs. Mirror Pods

- **Static Pod**: The actual running container process supervised by `kubelet` based purely on the local filesystem manifest.
- **Mirror Pod**: A read-only representation of the static pod created by `kubelet` inside the `kube-apiserver` so that cluster operators can inspect logs and health status using standard `kubectl get pods` and `kubectl logs`.

```mermaid
sequenceDiagram
    autonumber
    participant Op as DevOps Engineer
    participant API as Kubernetes API Server
    participant Kubelet as Node Kubelet Daemon
    participant Host as Host Filesystem (/etc/kubernetes/manifests)

    Op->>Host: Drop static-diagnostics-web.yaml on host disk
    Kubelet->>Host: Detects new YAML manifest
    Kubelet->>Kubelet: Starts container via CRI (containerd)
    Kubelet->>API: Creates read-only Mirror Pod in API Server
    Note over API: Mirror Pod appears in 'kubectl get pods'
    Op->>API: Executes 'kubectl delete pod static-diagnostics-web'
    API->>API: Deletes Mirror Pod record from etcd
    Kubelet->>API: Re-creates Mirror Pod within 3 seconds!
    Note over Op: Static pod cannot be killed via API;<br/>Must delete file from host disk!
```

---

### 2. The Immutability Principle of Static Pods

When an operator attempts to delete a mirror pod via `kubectl delete pod <name>`, the API server accepts the deletion and removes the record from `etcd`. However, because the `kubelet` remains unaware of API server deletion events and its local manifest file remains on disk, the `kubelet` immediately posts a **fresh mirror pod** back to the API server.

To modify or terminate a static pod, you **must modify or delete the YAML manifest directly from the host filesystem**.

---

### 3. Static Pods vs. DaemonSets vs. Deployments

| Dimension | Static Pod | DaemonSet | Deployment |
| :--- | :--- | :--- | :--- |
| **Supervisor / Controller** | Local node `kubelet` daemon | `DaemonSetController` in Controller Manager | `Deployment` + `ReplicaSet` Controllers |
| **API Server Dependency** | **Zero** (Runs even if API server is down) | Hard dependency (API server + etcd required) | Hard dependency (API server + etcd required) |
| **Manifest Location** | Local node directory (`/etc/kubernetes/manifests`) | `etcd` database via API Server | `etcd` database via API Server |
| **Manifest Format** | Strictly raw `kind: Pod` | `kind: DaemonSet` wrapping pod template | `kind: Deployment` wrapping pod template |
| **Deletion Method** | Delete file from host disk | `kubectl delete daemonset <name>` | `kubectl delete deployment <name>` |
| **Primary Use Cases** | `etcd`, `kube-apiserver`, bootstrap diagnostics | `node-exporter`, `fluentbit`, CNI agents | Stateless web apps, backend APIs |

---

### 4. Diagnosing Control-Plane Outages (When API Server is Down)

When the Kubernetes API server crashes, `kubectl` commands fail with `connection refused`. In this scenario, SREs use static pod diagnostics:

1. **Inspect Node Kubelet Logs**:

   ```bash
   journalctl -u kubelet -f --no-tail
   ```

2. **Inspect Low-Level Containers via CRI**:

   ```bash
   crictl ps -a
   crictl logs <container-id>
   ```

3. **Check Static Pod Manifest Directory**:

   ```bash
   ls -la /etc/kubernetes/manifests/
   ```

---

## 📁 Repository Structure

```text
04-orchestration/14-static-pods-control-plane-diagnostics/
├── README.md                              # Comprehensive educational guide (markdownlint compliant)
├── app/
│   ├── main.go                            # Lightweight diagnostics service reporting static pod runtime info
│   ├── go.mod                             # Go module definition
│   └── Dockerfile                         # Multi-stage minimal container build (<10MB, non-root UID 10001)
├── static-manifests/
│   ├── static-diagnostics-web.yaml        # Static pod definition for diagnostics web service
│   └── static-etcd-simulator.yaml         # Static pod definition modeling control-plane etcd component
├── bootstrap_static_pods.sh               # CLI tool discovering kubelet staticPodPath and deploying manifests
├── mirror_pod_audit.sh                    # Diagnostic audit testing mirror pods, API deletion immutability & self-healing
├── verify_static_pods.sh                  # Comprehensive static pod schema and kubelet manifest validator
├── test_static_pods_pipeline.sh           # End-to-end automated testing orchestrator
└── cleanup.sh                             # Teardown script (removes static manifests from nodes, purges images & files)
```

---

## 🛠️ Step-by-Step Execution & Testing Guide

### Prerequisites

- `kubectl` (v1.24+)
- `docker` (for container builds)
- *(Recommended)* Local Kubernetes cluster (`k3d`, `kind`, `orbstack`, or `minikube`)

---

### Step 1: Validate Static Pod Manifests Offline

Run the automated policy validator to verify all static pod architectural rules:

```bash
./verify_static_pods.sh
```

**Expected Output**:

```text
======================================================================
  🔍 Static Pods & Control Plane Bootstrap Validator
======================================================================

▶ Step 1: Checking Required Tools...
  [PASS] kubectl CLI is available

▶ Step 2: Validating Static Pod Manifests...
  [PASS] Manifest file presence: static-diagnostics-web.yaml
  [PASS] Manifest file presence: static-etcd-simulator.yaml

▶ Step 3: Asserting Static Pod Architectural Constraints...
  [1. Standalone Pod Object Constraint]
  [PASS] Static pod manifests strictly use 'kind: Pod' (no Deployment/ReplicaSet wrappers)

  [2. Kubelet Supervision & Restart Policy]
  [PASS] restartPolicy: Always declared for autonomous Kubelet process supervision

  [3. HostPath Storage for Control-Plane State]
  [PASS] HostPath volume (/var/lib/etcd) configured with DirectoryOrCreate

  [4. Downward API Node Metadata Injection]
  [PASS] Downward API spec.nodeName injected into static pod environment

  [5. Kubelet Container Health Probes]
  [PASS] Liveness and Readiness HTTP health probes configured for Kubelet monitoring

======================================================================
  ✅ ALL STATIC POD VALIDATION CHECKS PASSED (9/9)
======================================================================
```

---

### Step 2: Build the Static Pod Diagnostics Container Image

Build the lightweight container image:

```bash
docker build -t static-diagnostics-app:v1.0.0 ./app
```

---

### Step 3: Inject Static Pod Manifest into Kubelet Watch Directory

Deploy the static pod directly onto the node's filesystem using the bootstrap tool:

```bash
./bootstrap_static_pods.sh --deploy
```

List active static pod manifests:

```bash
./bootstrap_static_pods.sh --list
```

---

### Step 4: Run the Mirror Pod & Immutability Audit

Execute the mirror pod audit script to verify mirror pod creation and demonstrate API server deletion resilience:

```bash
./mirror_pod_audit.sh
```

Notice how `kubectl delete pod` triggers immediate recreation by the local `kubelet`.

---

### Step 5: Run the Complete Automated Test Suite

Execute the full end-to-end test pipeline:

```bash
./test_static_pods_pipeline.sh
```

---

## 🧹 Teardown & Environment Cleanup

To ensure a clean environment for subsequent mini-projects, execute the provided teardown script:

```bash
./cleanup.sh
```

### What `cleanup.sh` Automatically Purges

1. **Static Pod Manifests**: Removes all static pod YAML files from `/etc/kubernetes/manifests` or containerized Kubelet directories, terminating the static pod processes.
2. **Active Port-Forward Tunnels**: Kills any background `kubectl port-forward` processes associated with `static-diagnostics`.
3. **Local Docker Artifacts**: Purges the `static-diagnostics-app:v1.0.0` container image.
4. **Temporary Project Files**: Cleans up all `.tmp_*` logs and test directories strictly within the mini-project directory.

### Manual Cleanup Commands (Reference)

```bash
# 1. Remove static manifest from host directory
./bootstrap_static_pods.sh --remove

# 2. Terminate port-forwards
pkill -f "port-forward.*static-diagnostics" || true

# 3. Delete Docker image
docker rmi -f static-diagnostics-app:v1.0.0 2>/dev/null || true
```

---

## 📚 Key Learnings & SRE Takeaways

1. **Bootstrap Without Dependencies**: Static pods allow Kubernetes to bootstrap its own control-plane (`etcd`, `kube-apiserver`) before the cluster database is initialized.
2. **Kubelet-Centric Supervision**: The `kubelet` acts as an autonomous process supervisor on each node, continuously restarting crashed static pods regardless of API server connectivity.
3. **Immutability of Mirror Pods**: Deleting a mirror pod via `kubectl` has zero effect on the actual running container. The manifest on the host disk is the single source of truth.
4. **Disaster Recovery Preparedness**: When troubleshooting severe control-plane outages where `kubectl` fails, SREs rely directly on host-level tools (`crictl`, `journalctl`, and manifest inspection) to diagnose and heal static pods.
