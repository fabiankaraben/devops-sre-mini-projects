#!/usr/bin/env bash
# ==============================================================================
# verify_image_signature.sh - Admission Controller & Image Signature Verifier
# ==============================================================================
# Verifies container image signatures and in-toto SBOM attestations using
# Sigstore Cosign public keys. Rejects unauthenticated, modified, or tampered
# container images, acting as an enterprise pre-deployment security gate.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Defaults
IMAGE_TARGET=""
PUB_PATH="$SCRIPT_DIR/cosign.pub"
VERIFY_ATTESTATION=false
STRICT_MODE=true
COMPOSE_NETWORK="06-cosign-image-signing-sbom_default"
REPORTS_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORTS_DIR"

print_usage() {
    echo -e "${CLR_CYAN}Usage: ./verify_image_signature.sh [OPTIONS] <IMAGE_NAME>${CLR_RESET}"
    echo ""
    echo "Options:"
    echo "  --pub <PATH>              Path to Cosign public key (default: ./cosign.pub)"
    echo "  --verify-attestation      Verify attached In-Toto SBOM attestation"
    echo "  --strict                  Fail with exit code 1 on verification failure (default: true)"
    echo "  --help, -h                Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./verify_image_signature.sh localhost:5001/secure-app:1.0.0"
    echo "  ./verify_image_signature.sh --verify-attestation localhost:5001/secure-app:1.0.0"
    echo "  ./verify_image_signature.sh --pub ./cosign.pub localhost:5001/secure-app:tampered"
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pub)
            PUB_PATH="$2"
            shift 2
            ;;
        --verify-attestation)
            VERIFY_ATTESTATION=true
            shift
            ;;
        --strict)
            STRICT_MODE=true
            shift
            ;;
        --no-strict)
            STRICT_MODE=false
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            if [[ -z "$IMAGE_TARGET" ]]; then
                IMAGE_TARGET="$1"
                shift
            else
                echo -e "${CLR_RED}Error: Unknown argument '$1'${CLR_RESET}"
                print_usage
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$IMAGE_TARGET" ]]; then
    echo -e "${CLR_RED}Error: No target container image specified.${CLR_RESET}"
    print_usage
    exit 1
fi

if [[ ! -f "$PUB_PATH" ]]; then
    echo -e "${CLR_RED}Error: Public key '$PUB_PATH' not found.${CLR_RESET}"
    echo "Please run ./sign_pipeline.sh first or provide a valid --pub path."
    exit 1
fi

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🛡️  COSIGN CONTAINER SIGNATURE & ATTESTATION ADMISSION GATE"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e " Target Image     : ${CLR_BOLD}${IMAGE_TARGET}${CLR_RESET}"
echo -e " Public Key       : ${CLR_GRAY}${PUB_PATH}${CLR_RESET}"
echo -e " Attestation Check: ${CLR_BOLD}${VERIFY_ATTESTATION}${CLR_RESET}"
echo "======================================================================"

# Determine tool availability
USE_NATIVE_COSIGN=false
if command -v cosign >/dev/null 2>&1; then
    USE_NATIVE_COSIGN=true
fi

# Registry reference translation for containerized Cosign
INTERNAL_IMAGE_TARGET="${IMAGE_TARGET/localhost:5001/local-oci-registry:5000}"
PUB_REL_PATH="${PUB_PATH#$SCRIPT_DIR/}"
CONTAINER_PUB_PATH="/workspace/$PUB_REL_PATH"

echo -e "\n${CLR_YELLOW}▶ [1/2] Verifying Cryptographic Container Signature...${CLR_RESET}"
SIGNATURE_VERIFIED=false
RAW_VERIFY_OUTPUT=""

if [ "$USE_NATIVE_COSIGN" = true ]; then
    if RAW_VERIFY_OUTPUT=$(cosign verify \
        --key "$PUB_PATH" \
        --allow-insecure-registry \
        --allow-http-registry \
        "$IMAGE_TARGET" 2>&1); then
        SIGNATURE_VERIFIED=true
    fi
else
    if RAW_VERIFY_OUTPUT=$(docker run --rm \
        --network "$COMPOSE_NETWORK" \
        -v "$SCRIPT_DIR:/workspace" -w /workspace \
        gcr.io/projectsigstore/cosign:latest verify \
        --key "$CONTAINER_PUB_PATH" \
        --allow-insecure-registry \
        --allow-http-registry \
        "$INTERNAL_IMAGE_TARGET" 2>&1); then
        SIGNATURE_VERIFIED=true
    fi
fi

if [ "$SIGNATURE_VERIFIED" = true ]; then
    echo -e "  [${CLR_GREEN}VALID${CLR_RESET}] Cryptographic signature successfully verified against public key!"
    
    # Extract Manifest Digest from Claims
    DIGEST_EXTRACT=$(echo "$RAW_VERIFY_OUTPUT" | grep -o '"docker-manifest-digest":"[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "N/A")
    IDENTITY_EXTRACT=$(echo "$RAW_VERIFY_OUTPUT" | grep -o '"docker-reference":"[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "N/A")
    
    echo -e "  [${CLR_GREEN}CLAIM${CLR_RESET}] Verified Reference: ${CLR_BOLD}${IDENTITY_EXTRACT}${CLR_RESET}"
    echo -e "  [${CLR_GREEN}CLAIM${CLR_RESET}] Manifest Digest   : ${CLR_GRAY}${DIGEST_EXTRACT}${CLR_RESET}"
    echo -e "  [${CLR_GREEN}CLAIM${CLR_RESET}] Cryptographic Key: ${PUB_PATH}"
else
    echo -e "  [${CLR_RED}REJECTED${CLR_RESET}] Signature verification FAILED for image '${IMAGE_TARGET}'!"
    echo -e "  [${CLR_GRAY}DETAIL${CLR_RESET}] $RAW_VERIFY_OUTPUT"
fi

# ------------------------------------------------------------------------------
# STEP 2: Attestation Verification (Optional / Requested)
# ------------------------------------------------------------------------------
ATTESTATION_VERIFIED=false
if [ "$VERIFY_ATTESTATION" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/2] Verifying Cryptographic In-Toto SBOM Attestation...${CLR_RESET}"
    RAW_ATTEST_OUTPUT=""
    
    if [ "$USE_NATIVE_COSIGN" = true ]; then
        if RAW_ATTEST_OUTPUT=$(cosign verify-attestation \
            --key "$PUB_PATH" \
            --type spdxjson \
            --allow-insecure-registry \
            --allow-http-registry \
            "$IMAGE_TARGET" 2>&1); then
            ATTESTATION_VERIFIED=true
        fi
    else
        if RAW_ATTEST_OUTPUT=$(docker run --rm \
            --network "$COMPOSE_NETWORK" \
            -v "$SCRIPT_DIR:/workspace" -w /workspace \
            gcr.io/projectsigstore/cosign:latest verify-attestation \
            --key "$CONTAINER_PUB_PATH" \
            --type spdxjson \
            --allow-insecure-registry \
            --allow-http-registry \
            "$INTERNAL_IMAGE_TARGET" 2>&1); then
            ATTESTATION_VERIFIED=true
        fi
    fi

    if [ "$ATTESTATION_VERIFIED" = true ]; then
        echo -e "  [${CLR_GREEN}VALID${CLR_RESET}] Cryptographic SBOM In-Toto attestation successfully verified!"
        echo -e "  [${CLR_GREEN}PAYLOAD${CLR_RESET}] Predicate Type: https://spdx.dev/Document (SPDX 2.3 JSON)"
    else
        echo -e "  [${CLR_RED}REJECTED${CLR_RESET}] Attestation verification FAILED for image '${IMAGE_TARGET}'!"
        echo -e "  [${CLR_GRAY}DETAIL${CLR_RESET}] $RAW_ATTEST_OUTPUT"
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/2] Skipping In-Toto SBOM attestation check (pass --verify-attestation to enable).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# Admission Gate Policy Decision
# ------------------------------------------------------------------------------
echo ""
echo "======================================================================"
if [ "$SIGNATURE_VERIFIED" = true ] && { [ "$VERIFY_ATTESTATION" = false ] || [ "$ATTESTATION_VERIFIED" = true ]; }; then
    echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 ADMISSION GATE DECISION: APPROVED FOR DEPLOYMENT (ALLOW)${CLR_RESET}"
    echo "======================================================================"
    echo -e " Container '${IMAGE_TARGET}' meets enterprise supply chain provenance standards."
    exit 0
else
    echo -e "${CLR_RED}${CLR_BOLD}  ❌ ADMISSION GATE DECISION: DEPLOYMENT BLOCKED (DENY)${CLR_RESET}"
    echo "======================================================================"
    echo -e " Container '${IMAGE_TARGET}' is unsigned, tampered, or missing valid attestations."
    if [ "$STRICT_MODE" = true ]; then
        exit 1
    else
        exit 0
    fi
fi
