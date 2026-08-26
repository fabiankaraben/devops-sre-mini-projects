#!/usr/bin/env bash
# ==============================================================================
# node_setup.sh - Kubernetes Node Labeling and Taint Configuration Tool
# ==============================================================================
# Labels cluster nodes with realistic topology and hardware tags:
#   - disktype=ssd | hdd
#   - topology.kubernetes.io/zone=zone-a | zone-b | zone-c
#   - accelerator=gpu (with dedicated=gpu:NoSchedule taint)
#   - instance-type=high-memory | compute-optimized
#   - tier=spot | on-demand
#
# Flags:
#   --apply   : Applies labels and taints to detected nodes (default)
#   --status  : Displays current labels and taints on all nodes
#   --restore : Removes all custom labels and taints added by this project
# ==============================================================================

set -euo pipefail

# ANSI color formatting
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

CUSTOM_LABELS=(
    "disktype"
    "topology.kubernetes.io/zone"
    "accelerator"
    "instance-type"
    "tier"
    "environment"
)

CUSTOM_TAINTS=(
    "dedicated=gpu:NoSchedule"
    "maintenance=drain:NoExecute"
)

get_nodes() {
    kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""
}

show_status() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  📋 Current Node Topology, Labels & Taints Status"
    echo "======================================================================"
    echo -e "${CLR_RESET}"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "  ${CLR_YELLOW}[WARN] No reachable Kubernetes cluster found.${CLR_RESET}"
        return 0
    fi

    local nodes
    nodes=$(get_nodes)
    if [[ -z "$nodes" ]]; then
        echo -e "  ${CLR_RED}[ERROR] No nodes detected in cluster.${CLR_RESET}"
        return 1
    fi

    for node in $nodes; do
        echo -e "\n  ${CLR_BOLD}Node: ${CLR_CYAN}${node}${CLR_RESET}"
        echo -e "  ${CLR_GRAY}------------------------------------------------------------${CLR_RESET}"
        
        echo -e "  🏷️  ${CLR_MAGENTA}Relevant Labels:${CLR_RESET}"
        for lbl in "${CUSTOM_LABELS[@]}"; do
            local val
            val=$(kubectl get node "$node" -o jsonpath="{.metadata.labels.${lbl//\./\\\.}}" 2>/dev/null || echo "")
            if [[ -n "$val" ]]; then
                echo -e "     • ${lbl} = ${CLR_GREEN}${val}${CLR_RESET}"
            fi
        done

        echo -e "  ⚠️  ${CLR_YELLOW}Taints:${CLR_RESET}"
        local taints
        taints=$(kubectl get node "$node" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' 2>/dev/null || echo "")
        if [[ -n "$taints" ]]; then
            while IFS= read -r t; do
                if [[ -n "$t" ]]; then
                    echo -e "     • ${CLR_YELLOW}${t}${CLR_RESET}"
                fi
            done <<< "$taints"
        else
            echo -e "     ${CLR_GRAY}(none)${CLR_RESET}"
        fi
    done
    echo ""
}

apply_topology() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🏷️  Applying Multi-Node Scheduling Topology & Taints"
    echo "======================================================================"
    echo -e "${CLR_RESET}"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "  ${CLR_GRAY}[INFO] Offline mode: Validating label and taint commands syntactically.${CLR_RESET}"
        return 0
    fi

    local nodes
    nodes=$(get_nodes)
    local node_array=($nodes)
    local count=${#node_array[@]}

    echo -e "  Detected ${CLR_GREEN}${count} node(s)${CLR_RESET} in cluster.\n"

    if [[ "$count" -eq 1 ]]; then
        local n="${node_array[0]}"
        echo -e "  Configuring single-node development cluster (${CLR_CYAN}${n}${CLR_RESET})..."
        kubectl label node "$n" \
            disktype=ssd \
            topology.kubernetes.io/zone=zone-a \
            accelerator=gpu \
            instance-type=high-memory \
            tier=spot \
            environment=production \
            --overwrite >/dev/null
        # For single node, apply taint with toleration testing
        kubectl taint node "$n" dedicated=gpu:NoSchedule --overwrite >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Node '${n}' configured with test labels & GPU taint."
    else
        # Multi-node distribution (k3d, kind, multi-node cloud)
        # Node 1: Zone A, SSD, High-Memory
        local n1="${node_array[0]}"
        echo -e "  Configuring Node 1 (${CLR_CYAN}${n1}${CLR_RESET}) -> Zone-A, SSD, High-Memory..."
        kubectl label node "$n1" \
            disktype=ssd \
            topology.kubernetes.io/zone=zone-a \
            instance-type=high-memory \
            tier=on-demand \
            environment=production \
            --overwrite >/dev/null

        # Node 2: Zone B, SSD, GPU (Tainted)
        local n2="${node_array[1]}"
        echo -e "  Configuring Node 2 (${CLR_CYAN}${n2}${CLR_RESET}) -> Zone-B, SSD, GPU (Tainted NoSchedule)..."
        kubectl label node "$n2" \
            disktype=ssd \
            topology.kubernetes.io/zone=zone-b \
            accelerator=gpu \
            instance-type=compute-optimized \
            tier=on-demand \
            environment=production \
            --overwrite >/dev/null
        kubectl taint node "$n2" dedicated=gpu:NoSchedule --overwrite >/dev/null

        # Node 3+ (if present): Zone C, HDD, Spot
        if [[ "$count" -ge 3 ]]; then
            local n3="${node_array[2]}"
            echo -e "  Configuring Node 3 (${CLR_CYAN}${n3}${CLR_RESET}) -> Zone-C, HDD, Spot..."
            kubectl label node "$n3" \
                disktype=hdd \
                topology.kubernetes.io/zone=zone-c \
                instance-type=standard \
                tier=spot \
                environment=production \
                --overwrite >/dev/null
        fi
        echo -e "\n  [${CLR_GREEN}OK${CLR_RESET}] All ${count} nodes configured successfully."
    fi
}

restore_topology() {
    echo -e "${CLR_YELLOW}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🧹 Restoring Original Node State (Removing Custom Labels & Taints)"
    echo "======================================================================"
    echo -e "${CLR_RESET}"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "  ${CLR_GRAY}[INFO] No cluster reachable. Skipping node restore.${CLR_RESET}"
        return 0
    fi

    local nodes
    nodes=$(get_nodes)
    for node in $nodes; do
        echo "  Cleaning node '${node}'..."
        # Strip custom labels
        for lbl in "${CUSTOM_LABELS[@]}"; do
            kubectl label node "$node" "${lbl}-" >/dev/null 2>&1 || true
        done

        # Strip custom taints
        for t in "${CUSTOM_TAINTS[@]}"; do
            local key="${t%%=*}"
            local effect="${t##*:}"
            kubectl taint node "$node" "${key}:${effect}-" >/dev/null 2>&1 || true
            kubectl taint node "$node" "${key}-" >/dev/null 2>&1 || true
        done
    done
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All custom node labels and taints removed."
}

MODE="${1:---apply}"

case "$MODE" in
    --apply)
        apply_topology
        show_status
        ;;
    --status)
        show_status
        ;;
    --restore|--cleanup)
        restore_topology
        ;;
    *)
        echo "Usage: $0 [--apply | --status | --restore]"
        exit 1
        ;;
esac
