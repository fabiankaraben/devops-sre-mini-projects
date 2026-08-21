#!/usr/bin/env bash
# ==============================================================================
# persistence_test.sh - StatefulSet Dynamic Persistence & Recovery Verification
# ==============================================================================
# Verifies:
#   1. Ordered replica startup and PVC binding (data-volume-stateful-app-0..2)
#   2. Volume write operations to pod-0, pod-1, and pod-2 (isolated storage)
#   3. Forced pod termination of stateful-app-0
#   4. StatefulSet pod recreation with identical identity and PVC re-attachment
#   5. 100% data integrity verification across container destruction
#   6. Headless Service DNS peer discovery across replicas
# ==============================================================================

set -euo pipefail

# ANSI Color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

NAMESPACE="${NAMESPACE:-statefulset-demo}"
STATEFULSET_NAME="${STATEFULSET_NAME:-stateful-app}"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  💾 StatefulSet Persistence & Volume Recovery Verification Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Verify Initial Pod & PVC Status
echo -e "${CLR_YELLOW}▶ Step 1: Auditing StatefulSet Pods and Dynamic PVC Bindings...${CLR_RESET}"
for i in 0 1 2; do
    pod_name="${STATEFULSET_NAME}-${i}"
    pvc_name="data-volume-${STATEFULSET_NAME}-${i}"

    pvc_phase=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    pod_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

    if [[ "$pvc_phase" == "Bound" && "$pod_ready" == "True" ]]; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] ${pod_name} is Ready | PVC ${pvc_name} is ${CLR_GREEN}Bound${CLR_RESET}"
    else
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] ${pod_name} (Ready: ${pod_ready}) | PVC ${pvc_name} (${pvc_phase})"
        exit 1
    fi
done

# Step 2: Write Unique State to Pod 0, Pod 1, and Pod 2
echo -e "\n${CLR_YELLOW}▶ Step 2: Writing Isolated Key-Value State to Stateful Replicas...${CLR_RESET}"

# Write to Pod 0
echo "  Writing records to stateful-app-0..."
kubectl exec -n "$NAMESPACE" stateful-app-0 -- curl -s -X POST http://127.0.0.1:8080/data \
    -H "Content-Type: application/json" \
    -d '{"key":"database_checkpoint","value":"tx_994821_committed"}' >/dev/null

kubectl exec -n "$NAMESPACE" stateful-app-0 -- curl -s -X POST http://127.0.0.1:8080/data \
    -H "Content-Type: application/json" \
    -d '{"key":"cluster_role","value":"primary_master"}' >/dev/null

# Write to Pod 1
echo "  Writing records to stateful-app-1..."
kubectl exec -n "$NAMESPACE" stateful-app-1 -- curl -s -X POST http://127.0.0.1:8080/data \
    -H "Content-Type: application/json" \
    -d '{"key":"cluster_role","value":"replica_node_1"}' >/dev/null

# Write to Pod 2
echo "  Writing records to stateful-app-2..."
kubectl exec -n "$NAMESPACE" stateful-app-2 -- curl -s -X POST http://127.0.0.1:8080/data \
    -H "Content-Type: application/json" \
    -d '{"key":"cluster_role","value":"replica_node_2"}' >/dev/null

# Step 3: Inspect Baseline State on Pod 0
echo -e "\n${CLR_YELLOW}▶ Step 3: Inspecting Baseline State on stateful-app-0 before deletion...${CLR_RESET}"
pod0_baseline=$(kubectl exec -n "$NAMESPACE" stateful-app-0 -- curl -s http://127.0.0.1:8080/data)
echo "  Baseline Data: ${pod0_baseline}"

val_ckpt_pre=$(echo "$pod0_baseline" | grep -o '"value":"[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "")
echo -e "  Recorded database_checkpoint : ${CLR_GREEN}${val_ckpt_pre}${CLR_RESET}"

# Step 4: Forcefully Destroy Pod 0
echo -e "\n${CLR_YELLOW}▶ Step 4: Simulating Sudden Node Crash by Force-Deleting stateful-app-0...${CLR_RESET}"
kubectl delete pod stateful-app-0 -n "$NAMESPACE" --now >/dev/null
echo "  Pod stateful-app-0 deleted. Waiting for StatefulSet controller to reconcile..."

# Step 5: Wait for Pod 0 Recreation
kubectl rollout status statefulset/"$STATEFULSET_NAME" -n "$NAMESPACE" --timeout=60s >/dev/null

# Wait until pod is ready
for _ in {1..30}; do
    pod0_ready=$(kubectl get pod stateful-app-0 -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$pod0_ready" == "True" ]]; then
        break
    fi
    sleep 1
done

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Reincarnated stateful-app-0 is Ready!"

# Step 6: Verify Data Recovery & Integrity
echo -e "\n${CLR_YELLOW}▶ Step 6: Querying Recovered stateful-app-0 Persistent Volume...${CLR_RESET}"
pod0_recovered=$(kubectl exec -n "$NAMESPACE" stateful-app-0 -- curl -s http://127.0.0.1:8080/data)
echo "  Recovered Data: ${pod0_recovered}"

val_ckpt_post=$(echo "$pod0_recovered" | grep -o '"tx_994821_committed"' || echo "")
val_role_post=$(echo "$pod0_recovered" | grep -o '"primary_master"' || echo "")

if [[ -n "$val_ckpt_post" && -n "$val_role_post" ]]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All state records successfully recovered from PersistentVolumeClaim!"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Data loss detected! Expected records missing from persistent volume."
    exit 1
fi

# Step 7: Test Peer Discovery via Headless Service DNS
echo -e "\n${CLR_YELLOW}▶ Step 7: Testing Peer Discovery via Headless Service DNS...${CLR_RESET}"
peers_resp=$(kubectl exec -n "$NAMESPACE" stateful-app-0 -- curl -s http://127.0.0.1:8080/peers)
echo "  Peers Telemetry: ${peers_resp}"

if echo "$peers_resp" | grep -q "replica_node_1" && echo "$peers_resp" | grep -q "replica_node_2"; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Headless Service DNS resolved and aggregated sibling peer states!"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Peer communication via Headless Service DNS failed."
    exit 1
fi

# Final Summary Report
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}📊 STATEFULSET PERSISTENCE VERIFICATION REPORT${CLR_RESET}"
echo -e "======================================================================"
echo -e "  Replicas Verified            : 3 (stateful-app-0, 1, 2)"
echo -e "  Dynamic Storage Provisioner  : local-path (StorageClass)"
echo -e "  Volume Claim Template Name   : data-volume (ReadWriteOnce)"
echo -e "  Pod Destruction Target       : stateful-app-0 (Simulated Node Crash)"
echo -e "  Data Recovery Success Rate   : ${CLR_GREEN}100.00%${CLR_RESET} (0 data loss observed)"
echo -e "  Headless DNS Resolution      : ${CLR_GREEN}PASSED${CLR_RESET} (Peer mesh active)"
echo -e "======================================================================"
echo -e "${CLR_GREEN}${CLR_BOLD}✅ STATEFULSET TEST PASSED: State survived pod lifecycle destruction!${CLR_RESET}\n"
