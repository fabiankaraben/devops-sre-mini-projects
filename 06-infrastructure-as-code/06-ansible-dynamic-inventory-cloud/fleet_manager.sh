#!/usr/bin/env bash
# ==============================================================================
# fleet_manager.sh - Simulated Cloud Fleet Manager for Ansible Dynamic Inventory
# ==============================================================================
# Provisions, scales, inspects, and destroys local containerized fleet nodes
# tagged with metadata labels (Environment, Role, App, Version).
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="ansible-fleet-node:latest"
NETWORK_NAME="ansible-fleet-net"
FLEET_LABEL="devops.fleet=ansible-dynamic-inventory"

# Default fleet definition: name, environment, role, app, version, host_port
DEFAULT_NODES=(
    "web-prod-01:production:web:frontend:1.0.0:8081"
    "web-prod-02:production:web:frontend:1.0.0:8082"
    "web-stage-01:staging:web:frontend:1.0.0:8083"
    "api-prod-01:production:api:backend:1.0.0:8084"
    "db-prod-01:production:db:datastore:1.0.0:8085"
)

show_help() {
    echo -e "${CLR_CYAN}${CLR_BOLD}Ansible Dynamic Inventory - Fleet Manager${CLR_RESET}"
    echo "Usage: ./fleet_manager.sh [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  up             Build image and launch initial 5-node cloud fleet"
    echo "  status         Display running fleet nodes, tags, health, and versions"
    echo "  scale          Dynamically provision a new node (e.g. simulate auto-scaling)"
    echo "  stop <node>    Stop a specific fleet node (simulate outage)"
    echo "  start <node>   Start an existing stopped fleet node"
    echo "  drain <node>   Put a node in maintenance/drain mode (HTTP 503 on /health)"
    echo "  undrain <node> Remove maintenance/drain mode from a node"
    echo "  down           Stop and remove all running fleet containers and network"
    echo "  help           Show this help message"
    echo ""
    echo "Scale Options:"
    echo "  --name <str>   Node container name (e.g., web-prod-03)"
    echo "  --env <str>    Environment tag (default: production)"
    echo "  --role <str>   Role tag (default: web)"
    echo "  --app <str>    App tag (default: frontend)"
    echo "  --version <str>Version tag (default: 1.0.0)"
    echo "  --port <num>   Host port to map (default: auto-selected or 8086)"
}

ensure_network() {
    if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        echo -e "${CLR_YELLOW}Creating Docker network '${NETWORK_NAME}'...${CLR_RESET}"
        docker network create "$NETWORK_NAME" >/dev/null
    fi
}

build_image() {
    echo -e "${CLR_CYAN}🔨 Building fleet base image '${IMAGE_NAME}'...${CLR_RESET}"
    docker build -t "$IMAGE_NAME" -f test_environment/Dockerfile test_environment/
    echo -e "${CLR_GREEN}✓ Base image '${IMAGE_NAME}' built successfully.${CLR_RESET}"
}

cmd_up() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Provisioning Local Simulated Cloud Fleet"
    echo "======================================================================"
    echo -e "${CLR_RESET}"

    build_image
    ensure_network

    for node_spec in "${DEFAULT_NODES[@]}"; do
        IFS=':' read -r name env role app version port <<< "$node_spec"

        # If container already running, remove it
        if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
            docker rm -f "$name" >/dev/null 2>&1 || true
        fi

        echo -e "Starting node: ${CLR_BOLD}${name}${CLR_RESET} (${CLR_YELLOW}Env=${env}${CLR_RESET}, ${CLR_CYAN}Role=${role}${CLR_RESET}, Port=${port})..."

        docker run -d \
            --name "$name" \
            --network "$NETWORK_NAME" \
            -p "${port}:8080" \
            --label "${FLEET_LABEL}" \
            --label "Environment=${env}" \
            --label "Role=${role}" \
            --label "App=${app}" \
            --label "Cluster=cluster-alpha" \
            --label "Version=${version}" \
            --label "HostPort=${port}" \
            -e "FLEET_ENVIRONMENT=${env}" \
            -e "FLEET_ROLE=${role}" \
            -e "FLEET_APP=${app}" \
            -e "FLEET_VERSION=${version}" \
            -e "APP_PORT=8080" \
            --restart unless-stopped \
            "$IMAGE_NAME" >/dev/null
    done

    echo -e "\n${CLR_YELLOW}Waiting for fleet nodes to initialize endpoints...${CLR_RESET}"
    sleep 2

    cmd_status
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Fleet is UP and ready for Ansible Dynamic Inventory discovery!${CLR_RESET}"
}

cmd_status() {
    local running_containers
    running_containers=$(docker ps --filter "label=${FLEET_LABEL}" --format '{{.Names}}' | sort)

    if [[ -z "$running_containers" ]]; then
        echo -e "${CLR_YELLOW}No active fleet containers found.${CLR_RESET}"
        return 0
    fi

    echo -e "\n${CLR_BOLD}Active Fleet Nodes:${CLR_RESET}"
    printf "%-15s %-12s %-8s %-10s %-10s %-8s %-12s\n" "NODE NAME" "ENVIRONMENT" "ROLE" "APP" "VERSION" "PORT" "HEALTH"
    printf "%-15s %-12s %-8s %-10s %-10s %-8s %-12s\n" "---------------" "------------" "--------" "----------" "----------" "--------" "------------"

    while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        local cjson
        cjson=$(docker inspect "$cname" 2>/dev/null || echo "[]")
        
        local cenv crole capp cver cport health_stat
        cenv=$(echo "$cjson" | python3 -c 'import sys, json; data=json.load(sys.stdin); labels=data[0]["Config"]["Labels"]; print(labels.get("Environment", "unknown"))' 2>/dev/null || echo "unknown")
        crole=$(echo "$cjson" | python3 -c 'import sys, json; data=json.load(sys.stdin); labels=data[0]["Config"]["Labels"]; print(labels.get("Role", "unknown"))' 2>/dev/null || echo "unknown")
        capp=$(echo "$cjson" | python3 -c 'import sys, json; data=json.load(sys.stdin); labels=data[0]["Config"]["Labels"]; print(labels.get("App", "unknown"))' 2>/dev/null || echo "unknown")
        cver=$(echo "$cjson" | python3 -c 'import sys, json; data=json.load(sys.stdin); labels=data[0]["Config"]["Labels"]; print(labels.get("Version", "unknown"))' 2>/dev/null || echo "unknown")
        cport=$(echo "$cjson" | python3 -c 'import sys, json; data=json.load(sys.stdin); labels=data[0]["Config"]["Labels"]; print(labels.get("HostPort", "8080"))' 2>/dev/null || echo "8080")

        # Test live HTTP health endpoint
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${cport}/health" 2>/dev/null || echo "ERR")
        if [[ "$http_code" == "200" ]]; then
            health_stat="${CLR_GREEN}HEALTHY (200)${CLR_RESET}"
        elif [[ "$http_code" == "503" ]]; then
            health_stat="${CLR_YELLOW}DRAINING (503)${CLR_RESET}"
        else
            health_stat="${CLR_RED}DOWN (${http_code})${CLR_RESET}"
        fi

        # Query live version from file/endpoint if available
        local live_ver
        live_ver=$(curl -s "http://127.0.0.1:${cport}/version" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get("version", "'"$cver"'"))' 2>/dev/null || echo "$cver")

        printf "%-15s %-12s %-8s %-10s %-10s %-8s %b\n" "$cname" "$cenv" "$crole" "$capp" "$live_ver" "$cport" "$health_stat"
    done <<< "$running_containers"
}

cmd_scale() {
    local node_name=""
    local node_env="production"
    local node_role="web"
    local node_app="frontend"
    local node_version="1.0.0"
    local node_port="8086"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                node_name="$2"; shift 2 ;;
            --env)
                node_env="$2"; shift 2 ;;
            --role)
                node_role="$2"; shift 2 ;;
            --app)
                node_app="$2"; shift 2 ;;
            --version)
                node_version="$2"; shift 2 ;;
            --port)
                node_port="$2"; shift 2 ;;
            *)
                echo "Unknown scale option: $1"; show_help; exit 1 ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        echo -e "${CLR_RED}Error: --name <node_name> is required for scale command.${CLR_RESET}"
        exit 1
    fi

    ensure_network

    if docker ps -a --format '{{.Names}}' | grep -q "^${node_name}$"; then
        docker rm -f "$node_name" >/dev/null 2>&1 || true
    fi

    echo -e "${CLR_CYAN}🚀 Scaling out: Provisioning new dynamic node '${CLR_BOLD}${node_name}${CLR_RESET}' (${CLR_YELLOW}Env=${node_env}${CLR_RESET}, ${CLR_CYAN}Role=${node_role}${CLR_RESET}, Port=${node_port})...${CLR_RESET}"

    docker run -d \
        --name "$node_name" \
        --network "$NETWORK_NAME" \
        -p "${node_port}:8080" \
        --label "${FLEET_LABEL}" \
        --label "Environment=${node_env}" \
        --label "Role=${node_role}" \
        --label "App=${node_app}" \
        --label "Cluster=cluster-alpha" \
        --label "Version=${node_version}" \
        --label "HostPort=${node_port}" \
        -e "FLEET_ENVIRONMENT=${node_env}" \
        -e "FLEET_ROLE=${node_role}" \
        -e "FLEET_APP=${node_app}" \
        -e "FLEET_VERSION=${node_version}" \
        -e "APP_PORT=8080" \
        --restart unless-stopped \
        "$IMAGE_NAME" >/dev/null

    sleep 1
    echo -e "${CLR_GREEN}✓ Node '${node_name}' scaled out and running.${CLR_RESET}"
    cmd_status
}

cmd_drain() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo -e "${CLR_RED}Error: Specify container name to drain.${CLR_RESET}"
        exit 1
    fi
    local port
    port=$(docker inspect "$target" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)[0]["Config"]["Labels"].get("HostPort", "8080"))' 2>/dev/null || echo "8080")
    curl -s -X POST "http://127.0.0.1:${port}/drain/enable" >/dev/null 2>&1 || true
    echo -e "${CLR_YELLOW}✓ Drained node '${target}' on port ${port}. Health endpoint will now return HTTP 503.${CLR_RESET}"
}

cmd_undrain() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo -e "${CLR_RED}Error: Specify container name to undrain.${CLR_RESET}"
        exit 1
    fi
    local port
    port=$(docker inspect "$target" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)[0]["Config"]["Labels"].get("HostPort", "8080"))' 2>/dev/null || echo "8080")
    curl -s -X POST "http://127.0.0.1:${port}/drain/disable" >/dev/null 2>&1 || true
    echo -e "${CLR_GREEN}✓ Undrained node '${target}' on port ${port}. Health endpoint restored to HTTP 200.${CLR_RESET}"
}

cmd_stop() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo -e "${CLR_RED}Error: Specify container name to stop.${CLR_RESET}"; exit 1
    fi
    docker stop "$target" >/dev/null
    echo -e "${CLR_YELLOW}✓ Stopped node '${target}'.${CLR_RESET}"
}

cmd_start() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo -e "${CLR_RED}Error: Specify container name to start.${CLR_RESET}"; exit 1
    fi
    docker start "$target" >/dev/null
    echo -e "${CLR_GREEN}✓ Started node '${target}'.${CLR_RESET}"
}

cmd_down() {
    echo -e "${CLR_YELLOW}Stopping and removing all fleet containers...${CLR_RESET}"
    local containers
    containers=$(docker ps -a --filter "label=${FLEET_LABEL}" --format '{{.Names}}')
    if [[ -n "$containers" ]]; then
        while IFS= read -r c; do
            [[ -z "$c" ]] && continue
            docker rm -f "$c" >/dev/null 2>&1 || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container '$c' removed."
        done <<< "$containers"
    else
        echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] No fleet containers to remove."
    fi

    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker network '${NETWORK_NAME}' removed."
    fi

    echo -e "${CLR_GREEN}✓ Fleet stopped and destroyed.${CLR_RESET}"
}

# Main command dispatcher
COMMAND="${1:-status}"
shift || true

case "$COMMAND" in
    up)
        cmd_up ;;
    status)
        cmd_status ;;
    scale)
        cmd_scale "$@" ;;
    drain)
        cmd_drain "$@" ;;
    undrain)
        cmd_undrain "$@" ;;
    stop)
        cmd_stop "$@" ;;
    start)
        cmd_start "$@" ;;
    down)
        cmd_down ;;
    help|--help|-h)
        show_help ;;
    *)
        echo -e "${CLR_RED}Unknown command: ${COMMAND}${CLR_RESET}"
        show_help
        exit 1
        ;;
esac
