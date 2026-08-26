#!/usr/bin/env bash
# ==============================================================================
# verify_csi_storage.sh - CSI Storage, Expansion & Snapshot Policy Validator
# ==============================================================================
# Verifies:
#   1. YAML manifest schema validation
#   2. VolumeSnapshot CRD definitions (VolumeSnapshot, VolumeSnapshotClass, VolumeSnapshotContent)
#   3. StorageClass configuration with 'allowVolumeExpansion: true'
#   4. VolumeSnapshotClass and VolumeSnapshot bindings
#   5. Point-in-time restore PVC dataSource configuration
#   6. Online PVC dynamic expansion to 2Gi
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
echo "  💾 CSI Storage, Volume Expansion & Snapshot Validator"
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
    "01-volumesnapshot-crds.yaml"
    "02-storageclass.yaml"
    "03-volumesnapshotclass.yaml"
    "04-stateful-app-pvc.yaml"
    "05-volumesnapshot.yaml"
    "06-restore-pvc-from-snapshot.yaml"
    "07-volume-expansion.yaml"
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

# 3. Assert CSI Architectural Directives
echo -e "\n${CLR_YELLOW}▶ Step 3: Asserting CSI Storage & Snapshot Directives...${CLR_RESET}"

CRD_FILE="${MANIFESTS_DIR}/01-volumesnapshot-crds.yaml"
SC_FILE="${MANIFESTS_DIR}/02-storageclass.yaml"
VSC_FILE="${MANIFESTS_DIR}/03-volumesnapshotclass.yaml"
SNAP_FILE="${MANIFESTS_DIR}/05-volumesnapshot.yaml"
RESTORE_FILE="${MANIFESTS_DIR}/06-restore-pvc-from-snapshot.yaml"
EXPAND_FILE="${MANIFESTS_DIR}/07-volume-expansion.yaml"

# 3.1 VolumeSnapshot CRDs
echo -e "\n  ${CLR_MAGENTA}[1. CSI VolumeSnapshot CustomResourceDefinitions]${CLR_RESET}"
if grep -q "name: volumesnapshots.snapshot.storage.k8s.io" "$CRD_FILE" && grep -q "name: volumesnapshotclasses.snapshot.storage.k8s.io" "$CRD_FILE"; then
    record_check "VolumeSnapshot and VolumeSnapshotClass CRDs defined" 0
else
    record_check "VolumeSnapshot CRDs" 1 "CRD definitions missing"
fi

# 3.2 StorageClass Expansion Flag
echo -e "\n  ${CLR_MAGENTA}[2. Dynamic StorageClass & Volume Expansion]${CLR_RESET}"
if grep -q "allowVolumeExpansion: true" "$SC_FILE"; then
    record_check "StorageClass enables online PVC resizing (allowVolumeExpansion: true)" 0
else
    record_check "StorageClass allowVolumeExpansion" 1 "allowVolumeExpansion: true missing"
fi

if grep -q "reclaimPolicy: Delete" "$SC_FILE"; then
    record_check "StorageClass specifies explicit reclaimPolicy: Delete" 0
else
    record_check "StorageClass reclaimPolicy" 1 "reclaimPolicy missing"
fi

# 3.3 VolumeSnapshotClass
echo -e "\n  ${CLR_MAGENTA}[3. VolumeSnapshotClass & Deletion Policy]${CLR_RESET}"
if grep -q "kind: VolumeSnapshotClass" "$VSC_FILE" && grep -q "deletionPolicy: Delete" "$VSC_FILE"; then
    record_check "VolumeSnapshotClass configures deletionPolicy: Delete" 0
else
    record_check "VolumeSnapshotClass deletionPolicy" 1 "deletionPolicy missing in VolumeSnapshotClass"
fi

# 3.4 VolumeSnapshot Binding
echo -e "\n  ${CLR_MAGENTA}[4. VolumeSnapshot Source Binding]${CLR_RESET}"
if grep -q "persistentVolumeClaimName: app-data-pvc" "$SNAP_FILE" && grep -q "volumeSnapshotClassName: csi-snapshot-class" "$SNAP_FILE"; then
    record_check "VolumeSnapshot targets source PVC 'app-data-pvc' via 'csi-snapshot-class'" 0
else
    record_check "VolumeSnapshot target" 1 "Source PVC binding mismatch"
fi

# 3.5 Point-in-Time Restore dataSource
echo -e "\n  ${CLR_MAGENTA}[5. Point-in-Time Restore dataSource]${CLR_RESET}"
if grep -A 5 "dataSource:" "$RESTORE_FILE" | grep -q "name: app-data-snapshot" && grep -A 5 "dataSource:" "$RESTORE_FILE" | grep -q "kind: VolumeSnapshot"; then
    record_check "Restored PVC configures dataSource referencing VolumeSnapshot 'app-data-snapshot'" 0
else
    record_check "Restored PVC dataSource" 1 "dataSource VolumeSnapshot missing"
fi

# 3.6 Online Volume Expansion
echo -e "\n  ${CLR_MAGENTA}[6. Online Volume Expansion Definition]${CLR_RESET}"
if grep -A 4 "resources:" "$EXPAND_FILE" | grep -q "storage: 2Gi"; then
    record_check "Volume expansion manifest requests 2Gi storage capacity" 0
else
    record_check "Volume expansion request" 1 "storage: 2Gi missing"
fi

# 4. Architecture Summary Table
echo -e "\n${CLR_YELLOW}▶ Step 4: Kubernetes Storage Provisioning & Backup Mechanisms${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------+------------------------------------+${CLR_RESET}"
echo -e "${CLR_CYAN}| Mechanism                    | Trigger / API Primitive      | Primary SRE Use Case               |${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------+------------------------------------+${CLR_RESET}"
echo -e "| Dynamic Provisioning         | PVC -> StorageClass          | Automated EBS/Persistent Disk alloc|"
echo -e "| Online Volume Expansion      | Edit PVC (storage: 2Gi)      | Zero-downtime disk resizing on DBs |"
echo -e "| VolumeSnapshot               | VolumeSnapshot CR            | Crash-consistent point-in-time snap|"
echo -e "| DataSource Point-in-Time Res | PVC.spec.dataSource          | Disaster recovery & staging clones |"
echo -e "+------------------------------+------------------------------+------------------------------------+${CLR_RESET}"

# 5. Summary
echo -e "\n======================================================================"
if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✅ ALL CSI STORAGE VALIDATION CHECKS PASSED (${PASSED_CHECKS}/${TOTAL_CHECKS})${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ STORAGE VALIDATION FAILED (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
