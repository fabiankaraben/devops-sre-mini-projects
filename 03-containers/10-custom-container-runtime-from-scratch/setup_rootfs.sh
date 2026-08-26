#!/usr/bin/env bash
# ==============================================================================
# setup_rootfs.sh - Alpine Minimal Rootfs Bundle Provisioner
# ==============================================================================
# Prepares a minimal, isolated Alpine Linux root filesystem bundle for the
# custom container runtime (my_runtime).
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-/rootfs}"

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  📦 Minimal Container Rootfs Bundle Provisioner"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

prepare_rootfs() {
    print_banner
    echo -e "${CLR_BOLD}🚀 Provisioning Alpine Rootfs in '${TARGET_DIR}'...${CLR_RESET}"

    if [[ -d "${TARGET_DIR}/bin" && -f "${TARGET_DIR}/bin/sh" ]]; then
        echo -e "${CLR_GREEN}✔ Rootfs bundle already exists in '${TARGET_DIR}'. Skipping download.${CLR_RESET}"
        return 0
    fi

    mkdir -p "${TARGET_DIR}"

    # Detect CPU architecture for minirootfs
    local arch
    arch=$(uname -m)
    local alpine_arch="x86_64"
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        alpine_arch="aarch64"
    fi

    local alpine_ver="3.20.3"
    local alpine_branch="v3.20"
    local tar_name="alpine-minirootfs-${alpine_ver}-${alpine_arch}.tar.gz"
    local url="https://dl-cdn.alpinelinux.org/alpine/${alpine_branch}/releases/${alpine_arch}/${tar_name}"
    local tmp_tar="/tmp/${tar_name}"

    echo -e "  --> Downloading Alpine Linux Minirootfs (${alpine_arch})..."
    if curl -fsSL -o "$tmp_tar" "$url"; then
        echo -e "  --> Extracting bundle into ${TARGET_DIR}..."
        tar -xzf "$tmp_tar" -C "$TARGET_DIR"
        rm -f "$tmp_tar"
    else
        echo -e "${CLR_YELLOW}⚠️  Direct download failed. Falling back to local OS toolchain copy...${CLR_RESET}"
        # Fallback for offline or restricted lab: copy base system binaries
        mkdir -p "${TARGET_DIR}"/{bin,sbin,etc,proc,sys,dev,tmp,root,usr/bin,usr/sbin,lib}
        cp -a /bin/* "${TARGET_DIR}/bin/" 2>/dev/null || true
        cp -a /sbin/* "${TARGET_DIR}/sbin/" 2>/dev/null || true
        cp -a /lib/* "${TARGET_DIR}/lib/" 2>/dev/null || true
    fi

    # Create special marker inside rootfs to prove filesystem boundary isolation
    echo "CONTAINER_ROOTFS_ISOLATED_FS" > "${TARGET_DIR}/CONTAINER_ID"
    mkdir -p "${TARGET_DIR}/proc" "${TARGET_DIR}/dev" "${TARGET_DIR}/tmp"

    echo -e "${CLR_GREEN}✨ Rootfs bundle successfully provisioned in '${TARGET_DIR}'!${CLR_RESET}"
}

prepare_rootfs
