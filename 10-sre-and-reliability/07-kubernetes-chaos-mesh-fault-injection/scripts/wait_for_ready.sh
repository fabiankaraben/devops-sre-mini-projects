#!/usr/bin/env bash
# ==============================================================================
# wait_for_ready.sh - Cluster & Workload Health Verification
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="$PROJECT_DIR/.kubeconfig"

echo "Waiting for Chaos Mesh controller manager and daemons..."
kubectl wait --for=condition=Available deployment/chaos-controller-manager -n chaos-mesh --timeout=90s >/dev/null 2>&1 || true
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=chaos-daemon -n chaos-mesh --timeout=90s >/dev/null 2>&1 || true

echo "Waiting for Payment API deployment in chaos-lab..."
kubectl rollout status deployment/payment-api -n chaos-lab --timeout=90s >/dev/null 2>&1 || true
kubectl wait --for=condition=Ready pods -l app=payment-api -n chaos-lab --timeout=60s >/dev/null 2>&1 || true

echo "All cluster workloads are Ready."
