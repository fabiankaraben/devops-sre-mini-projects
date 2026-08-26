#!/usr/bin/env bash
# ==============================================================================
# setup_rootless.sh - Rootless Container & User Namespace Configurator
# ==============================================================================
# Inspects and configures:
#   1. Subordinate user & group IDs (/etc/subuid & /etc/subgid)
#   2. Kernel user namespace allocation controls
#   3. Spawns isolated rootless container namespaces with user mapping
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🛡️  Rootless Container Execution & User Namespace Configurator"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

print_environment() {
    print_banner
    echo -e "${CLR_BOLD}👤 Current Host/Parent Identity Context:${CLR_RESET}"
    echo -e "  • User:               $(whoami) (UID: $(id -u), GID: $(id -g))"
    echo -e "  • Groups:             $(id -Gn)"
    echo -e "  • PID:                $$"
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

    echo -e "${CLR_BOLD}📄 Subordinate ID Mappings Configuration:${CLR_RESET}"
    if [[ -f /etc/subuid ]]; then
        echo -e "  • /etc/subuid:        $(cat /etc/subuid)"
    else
        echo -e "  • /etc/subuid:        ${CLR_YELLOW}Not present${CLR_RESET}"
    fi

    if [[ -f /etc/subgid ]]; then
        echo -e "  • /etc/subgid:        $(cat /etc/subgid)"
    else
        echo -e "  • /etc/subgid:        ${CLR_YELLOW}Not present${CLR_RESET}"
    fi
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

    echo -e "${CLR_BOLD}🔬 Kernel User Namespace Capability:${CLR_RESET}"
    if unshare -U true 2>/dev/null; then
        echo -e "  • unshare(CLONE_NEWUSER): ${CLR_GREEN}Supported & Enabled${CLR_RESET}"
    else
        echo -e "  • unshare(CLONE_NEWUSER): ${CLR_RED}Unavailable / Disabled${CLR_RESET}"
    fi
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"
}

spawn_rootless_namespace() {
    echo ""
    echo -e "${CLR_BOLD}🚀 Spawning Isolated Rootless Container Namespace...${CLR_RESET}"
    echo -e "  Executing: ${CLR_GRAY}unshare --user --map-root-user --mount --pid --fork bash${CLR_RESET}"
    echo ""

    # Launch rootless container namespace
    unshare --user --map-root-user --mount --pid --fork /bin/bash -c '
        echo "=== [INSIDE ROOTLESS NAMESPACE] ==="
        echo "Inside Identity: $(whoami) (UID: $(id -u), GID: $(id -g))"
        echo "UID Mapping Table (/proc/self/uid_map):"
        cat /proc/self/uid_map
        echo "==================================="
    '
}

main() {
    print_environment
    if [[ "${1:-}" == "--run" || "${1:-}" == "-r" ]]; then
        spawn_rootless_namespace
    else
        echo -e "Run ${CLR_CYAN}./setup_rootless.sh --run${CLR_RESET} to spawn an interactive rootless namespace session."
        echo -e "Run ${CLR_CYAN}./verify_isolation.sh${CLR_RESET} to execute the automated security verification suite."
    fi
}

main "$@"
