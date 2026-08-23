#!/usr/bin/env bash
# ==============================================================================
# k8s_log_metadata_audit.sh - Fluent Bit Kubernetes Log Metadata Audit Script
# ==============================================================================
# Fetches live log stream from Fluent Bit DaemonSet and verifies that 100% of
# captured container records contain enriched Kubernetes metadata tags.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔍 Kubernetes Log Metadata Audit: Fluent Bit DaemonSet"
echo "======================================================================"
echo -e "${CLR_RESET}"

if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] kubectl CLI not found in PATH."
    exit 1
fi

echo -e "${CLR_YELLOW}▶ [1/2] Fetching Fluent Bit Log Stream from Kubernetes Cluster...${CLR_RESET}"

# Find all fluent-bit pods in logging namespace across nodes
FB_PODS=$(kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit -o jsonpath="{.items[*].metadata.name}" 2>/dev/null || true)

if [[ -z "$FB_PODS" ]]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] No Fluent Bit pods found in 'logging' namespace."
    echo "  Ensure DaemonSet is deployed: kubectl get pods -n logging"
    exit 1
fi

TEMP_LOG_FILE="/tmp/flb_audit_stream_$$.log"
: > "$TEMP_LOG_FILE"
trap 'rm -f "$TEMP_LOG_FILE"' EXIT

for pod in $FB_PODS; do
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Collecting logs from DaemonSet pod: ${CLR_BOLD}${pod}${CLR_RESET}"
    kubectl logs -n logging "$pod" --tail=500 >> "$TEMP_LOG_FILE" 2>/dev/null || true
done

LOG_LINE_COUNT=$(wc -l < "$TEMP_LOG_FILE" | tr -d ' ')
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Captured ${LOG_LINE_COUNT} total log lines across all cluster nodes."

echo -e "\n${CLR_YELLOW}▶ [2/2] Running Python Metadata Enrichment Audit...${CLR_RESET}"

python3 "$SCRIPT_DIR/audit_metadata.py" \
    --file "$TEMP_LOG_FILE" \
    --namespaces "frontend-ns" "backend-ns" "analytics-ns"
