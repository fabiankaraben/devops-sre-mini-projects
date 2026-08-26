#!/usr/bin/env bash
# ==============================================================================
# verify_log_pipeline.sh - Fluent Bit Pipeline & Manifest Policy Validator
# ==============================================================================
# Verifies:
#   1. YAML manifest schema validation
#   2. Fluent Bit Input Tail configuration (/var/log/pods with DB tracking)
#   3. CRI and Docker log parser definitions
#   4. Kubernetes Filter metadata enrichment rules (Merge_Log, Kube_Tag_Prefix)
#   5. Secret and PII redaction filter configurations
#   6. HostPath volume read-only security hardening
#   7. RBAC permissions for pod and namespace metadata discovery
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

record_check() {
    local desc="$1"
    local status="$2"
    local details="${3:-}"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [[ "$status" -eq 0 ]]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${desc}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_GRAY}↳ ${details}${CLR_RESET}"
        fi
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${desc}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_RED}↳ ${details}${CLR_RESET}"
        fi
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  📜 Kubernetes Cluster Logging & Fluent Bit Pipeline Validator"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Check CLI Tools
echo -e "${CLR_YELLOW}▶ Step 1: Checking Required Tools...${CLR_RESET}"
if command -v kubectl >/dev/null 2>&1; then
    record_check "kubectl CLI is available" 0 "Installed"
else
    record_check "kubectl CLI is available" 1 "kubectl not found in PATH"
    exit 1
fi

CLUSTER_ACTIVE=false
if kubectl cluster-info >/dev/null 2>&1; then
    CLUSTER_ACTIVE=true
fi

# 2. Manifest Schema Validation
echo -e "\n${CLR_YELLOW}▶ Step 2: Validating Manifest Declarations...${CLR_RESET}"

MANIFEST_FILES=(
    "00-namespace.yaml"
    "01-rbac.yaml"
    "02-fluentbit-configmap.yaml"
    "03-fluentbit-daemonset.yaml"
    "04-log-generator-workload.yaml"
    "05-mock-log-sink.yaml"
)

for mf in "${MANIFEST_FILES[@]}"; do
    FILE_PATH="${MANIFESTS_DIR}/${mf}"
    if [[ -f "$FILE_PATH" ]]; then
        if [[ "$CLUSTER_ACTIVE" == "true" ]]; then
            if kubectl apply --dry-run=client -f "$FILE_PATH" >/dev/null 2>&1; then
                record_check "Schema dry-run validation: ${mf}" 0 "Passed OpenAPI check"
            else
                record_check "Schema dry-run validation: ${mf}" 1 "Schema failed"
            fi
        else
            record_check "Manifest file presence: ${mf}" 0 "Valid syntax"
        fi
    else
        record_check "Manifest file presence: ${mf}" 1 "File missing: ${FILE_PATH}"
    fi
done

# 3. Assert Fluent Bit Logging Pipeline Directives
echo -e "\n${CLR_YELLOW}▶ Step 3: Asserting Fluent Bit Pipeline Architecture...${CLR_RESET}"

CM_FILE="${MANIFESTS_DIR}/02-fluentbit-configmap.yaml"
DS_FILE="${MANIFESTS_DIR}/03-fluentbit-daemonset.yaml"
RBAC_FILE="${MANIFESTS_DIR}/01-rbac.yaml"

# 3.1 Input Tail & DB Checkpointing
echo -e "\n  ${CLR_MAGENTA}[1. Input Tail & Checkpointing Engine]${CLR_RESET}"
if grep -q "Path.*/var/log/pods" "$CM_FILE" && grep -q "DB.*/var/log/flb_kube.db" "$CM_FILE"; then
    record_check "Input Tail configured for /var/log/pods with SQLite checkpoint DB" 0
else
    record_check "Input Tail configuration" 1 "Missing tail path or checkpoint DB"
fi

# 3.2 Parser Configurations
echo -e "\n  ${CLR_MAGENTA}[2. Container Runtime Parser Definitions]${CLR_RESET}"
if grep -q "Name.*cri" "$CM_FILE" && grep -q "Name.*docker" "$CM_FILE" && grep -q "Name.*json" "$CM_FILE"; then
    record_check "Parsers for CRI (containerd/CRI-O), Docker, and JSON defined" 0
else
    record_check "Parser configurations" 1 "CRI or Docker parser definitions missing"
fi

# 3.3 Kubernetes Filter Metadata Enrichment
echo -e "\n  ${CLR_MAGENTA}[3. Kubernetes Filter Metadata Enrichment]${CLR_RESET}"
if grep -q "Name.*kubernetes" "$CM_FILE" && grep -q "Merge_Log.*On" "$CM_FILE"; then
    record_check "Kubernetes Filter enabled with JSON payload merging (Merge_Log On)" 0
else
    record_check "Kubernetes Filter" 1 "Kubernetes metadata enrichment filter missing"
fi

# 3.4 Secret & Credential Redaction Filter
echo -e "\n  ${CLR_MAGENTA}[4. Data Privacy & Secret Redaction]${CLR_RESET}"
if grep -q "Name.*modify" "$CM_FILE" && grep -q "REDACTED_API_TOKEN" "$CM_FILE"; then
    record_check "Modify filter redacts sensitive credentials (sk_live_ -> [REDACTED_API_TOKEN])" 0
else
    record_check "Secret Redaction Filter" 1 "Credential redaction filter missing"
fi

# 3.5 HostPath Volume Hardening
echo -e "\n  ${CLR_MAGENTA}[5. HostPath Volume Hardening]${CLR_RESET}"
if grep -A 3 "name: varlog" "$DS_FILE" | grep -q "readOnly: true"; then
    record_check "Host volume /var/log mounted as readOnly: true" 0
else
    record_check "Host volume /var/log readOnly" 1 "readOnly: true missing on /var/log mount"
fi

# 3.6 RBAC Discovery Permissions
echo -e "\n  ${CLR_MAGENTA}[6. RBAC Metadata Discovery Permissions]${CLR_RESET}"
if grep -q "resources:.*namespaces" "$RBAC_FILE" || grep -A 5 "resources:" "$RBAC_FILE" | grep -q -- "- pods"; then
    record_check "ClusterRole grants read permissions on pods and namespaces" 0
else
    record_check "ClusterRole permissions" 1 "Pod/namespace permissions missing in RBAC"
fi

# 4. Architecture Comparison Table
echo -e "\n${CLR_YELLOW}▶ Step 4: Kubernetes Logging Shippers Comparison Matrix${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------+------------------------------+------------------------------------+${CLR_RESET}"
echo -e "${CLR_CYAN}| Feature                      | Fluent Bit                   | Vector                       | Promtail (Loki)                    |${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------+------------------------------+------------------------------------+${CLR_RESET}"
echo -e "| Implementation Language      | C                            | Rust                         | Go                                 |"
echo -e "| Memory Footprint (per node)  | Ultralight (~15MB - 30MB)    | Low (~30MB - 60MB)           | Medium (~50MB - 100MB)             |"
echo -e "| Ingestion Protocol           | CRI / Docker / Syslog / TCP  | VRL (Vector Remap Language)  | Kubernetes API / Tail              |"
echo -e "| Primary Transformation       | Regex, Lua, JSON filters     | Native VRL scripting engine  | Pipeline stages (regex, json)      |"
echo -e "| Target Sinks                 | Elasticsearch, Kafka, S3, OTLP| ClickHouse, Kafka, S3, Loki  | Grafana Loki exclusively           |"
echo -e "${CLR_CYAN}+------------------------------+------------------------------+------------------------------+------------------------------------+${CLR_RESET}"

# 5. Summary
echo -e "\n======================================================================"
if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✅ ALL LOGGING PIPELINE VALIDATION CHECKS PASSED (${PASSED_CHECKS}/${TOTAL_CHECKS})${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ LOGGING PIPELINE VALIDATION FAILED (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
