#!/usr/bin/env bash
# ==============================================================================
# sign_pipeline.sh - Container Signing & SBOM Generation with Cosign & Syft
# ==============================================================================
# Automates cryptographic keypair generation, Software Bill of Materials (SBOM)
# extraction using Anchore Syft (SPDX & CycloneDX), and container image signing
# plus in-toto SBOM attestation using Sigstore Cosign against an OCI registry.
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
IMAGE_TARGET="localhost:5001/secure-app:1.0.0"
KEY_PATH="$SCRIPT_DIR/cosign.key"
PUB_PATH="$SCRIPT_DIR/cosign.pub"
REPORTS_DIR="$SCRIPT_DIR/reports"
REGISTRY_CONTAINER="local-oci-registry"
REGISTRY_PORT="5001"
COMPOSE_NETWORK="06-cosign-image-signing-sbom_default"
SKIP_BUILD=false
COSIGN_PASSWORD="${COSIGN_PASSWORD:-SecureDevSecOps2026!}"
export COSIGN_PASSWORD

print_usage() {
    echo -e "${CLR_CYAN}Usage: ./sign_pipeline.sh [OPTIONS] [IMAGE_NAME]${CLR_RESET}"
    echo ""
    echo "Options:"
    echo "  --image <NAME:TAG>     Target image reference (default: localhost:5001/secure-app:1.0.0)"
    echo "  --key <PATH>           Path to Cosign private key (default: ./cosign.key)"
    echo "  --pub <PATH>           Path to Cosign public key (default: ./cosign.pub)"
    echo "  --output-dir <DIR>     Directory for generated SBOMs & reports (default: ./reports)"
    echo "  --skip-build           Skip Docker build and push step"
    echo "  --password <PASS>      Password for encrypting the Cosign private key"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./sign_pipeline.sh"
    echo "  ./sign_pipeline.sh --image localhost:5001/custom-app:2.0.0"
    echo "  ./sign_pipeline.sh --output-dir ./custom-reports"
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            IMAGE_TARGET="$2"
            shift 2
            ;;
        --key)
            KEY_PATH="$2"
            shift 2
            ;;
        --pub)
            PUB_PATH="$2"
            shift 2
            ;;
        --output-dir)
            REPORTS_DIR="$2"
            shift 2
            ;;
        --password)
            COSIGN_PASSWORD="$2"
            export COSIGN_PASSWORD
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            if [[ "$1" != --* ]] && [[ "$IMAGE_TARGET" == "localhost:5001/secure-app:1.0.0" ]]; then
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

mkdir -p "$REPORTS_DIR"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔒 SIGSTORE COSIGN & SYFT CONTAINER SIGNING PIPELINE"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e " Target Image     : ${CLR_BOLD}${IMAGE_TARGET}${CLR_RESET}"
echo -e " Private Key      : ${CLR_GRAY}${KEY_PATH}${CLR_RESET}"
echo -e " Public Key       : ${CLR_GRAY}${PUB_PATH}${CLR_RESET}"
echo -e " Reports Directory: ${CLR_GRAY}${REPORTS_DIR}${CLR_RESET}"
echo "======================================================================"

# Determine Docker Compose command
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

# Ensure local OCI registry is running
echo -e "\n${CLR_YELLOW}▶ [1/6] Verifying Local OCI Registry Status...${CLR_RESET}"
if ! docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_CONTAINER}$"; then
    echo -e "  [${CLR_MAGENTA}INFO${CLR_RESET}] Local OCI Registry container not detected. Starting via Docker Compose..."
    if [[ -n "$COMPOSE_CMD" ]]; then
        $COMPOSE_CMD up -d local-registry >/dev/null 2>&1
    else
        docker run -d --name "$REGISTRY_CONTAINER" -p 5001:5000 \
            -e REGISTRY_STORAGE_DELETE_ENABLED=true \
            registry:2 >/dev/null 2>&1
    fi
    # Wait for registry to respond
    sleep 2
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local OCI Registry is active on port ${REGISTRY_PORT}."

# Determine tool availability (Native binary vs Dockerized fallback)
USE_NATIVE_COSIGN=false
USE_NATIVE_SYFT=false

if command -v cosign >/dev/null 2>&1; then
    USE_NATIVE_COSIGN=true
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Found native Cosign binary: $(cosign version 2>&1 | head -n 1)"
else
    echo -e "  [${CLR_MAGENTA}INFO${CLR_RESET}] Using containerized Cosign (gcr.io/projectsigstore/cosign:latest)"
fi

if command -v syft >/dev/null 2>&1; then
    USE_NATIVE_SYFT=true
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Found native Syft binary: $(syft version 2>&1 | head -n 1)"
else
    echo -e "  [${CLR_MAGENTA}INFO${CLR_RESET}] Using containerized Syft (anchore/syft:latest)"
fi

# ------------------------------------------------------------------------------
# STEP 2: Generate Cosign Cryptographic Keypair
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/6] Generating / Validating ECDSA-P256 Keypair...${CLR_RESET}"
if [[ ! -f "$KEY_PATH" || ! -f "$PUB_PATH" ]]; then
    echo -e "  [${CLR_MAGENTA}KEYGEN${CLR_RESET}] Creating new Cosign cryptographic keypair..."
    if [ "$USE_NATIVE_COSIGN" = true ]; then
        COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign generate-key-pair >/dev/null 2>&1
    else
        docker run --rm -e HOME=/tmp -e COSIGN_PASSWORD="$COSIGN_PASSWORD" \
            -v "$SCRIPT_DIR:/workspace" -w /workspace \
            gcr.io/projectsigstore/cosign:latest generate-key-pair >/dev/null 2>&1
    fi
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Private Key: $KEY_PATH (ECDSA P-256, encrypted with password)"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Public Key : $PUB_PATH"
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Keypair already exists. Reusing $KEY_PATH and $PUB_PATH"
fi

# ------------------------------------------------------------------------------
# STEP 3: Build and Push Target Container Image
# ------------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
    echo -e "\n${CLR_YELLOW}▶ [3/6] Building and Pushing Container Image to Local Registry...${CLR_RESET}"
    echo -e "  [${CLR_GRAY}DOCKER${CLR_RESET}] Building image '$IMAGE_TARGET'..."
    docker build -t "$IMAGE_TARGET" -f Dockerfile . >/dev/null 2>&1
    echo -e "  [${CLR_GRAY}DOCKER${CLR_RESET}] Pushing image to local registry..."
    docker push "$IMAGE_TARGET" >/dev/null 2>&1
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Image built and pushed successfully."
else
    echo -e "\n${CLR_YELLOW}▶ [3/6] Skipping Docker build and push (--skip-build specified).${CLR_RESET}"
fi

# Retrieve Image Digest
IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE_TARGET" 2>/dev/null || echo "")
if [[ -z "$IMAGE_DIGEST" ]]; then
    IMAGE_DIGEST="$IMAGE_TARGET"
fi
echo -e "  [${CLR_BOLD}DIGEST${CLR_RESET}] $IMAGE_DIGEST"

# ------------------------------------------------------------------------------
# STEP 4: Generate Software Bill of Materials (SBOM) using Syft
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/6] Generating Multi-Format Software Bill of Materials (SBOM)...${CLR_RESET}"
SPDX_REPORT="$REPORTS_DIR/sbom.spdx.json"
CYCLONEDX_REPORT="$REPORTS_DIR/sbom.cyclonedx.json"
TABLE_REPORT="$REPORTS_DIR/sbom.txt"

if [ "$USE_NATIVE_SYFT" = true ]; then
    syft scan "docker:$IMAGE_TARGET" \
        -o "spdx-json=$SPDX_REPORT" \
        -o "cyclonedx-json=$CYCLONEDX_REPORT" \
        -o "syft-table=$TABLE_REPORT" >/dev/null 2>&1
else
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$SCRIPT_DIR:/workspace" \
        -w /workspace \
        anchore/syft:latest scan "docker:$IMAGE_TARGET" \
        -o "spdx-json=/workspace/reports/sbom.spdx.json" \
        -o "cyclonedx-json=/workspace/reports/sbom.cyclonedx.json" \
        -o "syft-table=/workspace/reports/sbom.txt" >/dev/null 2>&1
fi

TOTAL_PKGS=$(python3 -c "import json; print(len(json.load(open('$SPDX_REPORT')).get('packages', [])))" 2>/dev/null || grep -c '"SPDXID":' "$SPDX_REPORT" 2>/dev/null || echo "0")
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] SPDX 2.3 JSON SBOM      : $SPDX_REPORT"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] CycloneDX 1.5 JSON SBOM : $CYCLONEDX_REPORT"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Human-Readable Table SBOM: $TABLE_REPORT"
echo -e "  [${CLR_MAGENTA}INVENTORY${CLR_RESET}] Cataloged Packages: ${CLR_BOLD}${TOTAL_PKGS}${CLR_RESET} components detected."

# ------------------------------------------------------------------------------
# STEP 5: Attach & Sign SBOM Attestation with Cosign
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/6] Attaching In-Toto Cryptographic SBOM Attestation...${CLR_RESET}"

# Registry reference translation for containerized Cosign
INTERNAL_IMAGE_TARGET="${IMAGE_TARGET/localhost:5001/local-oci-registry:5000}"

if [ "$USE_NATIVE_COSIGN" = true ]; then
    COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign attest \
        --yes \
        --key "$KEY_PATH" \
        --type spdxjson \
        --predicate "$SPDX_REPORT" \
        --allow-insecure-registry \
        --allow-http-registry \
        "$IMAGE_TARGET" >/dev/null 2>&1
else
    docker run --rm -e HOME=/tmp -e COSIGN_PASSWORD="$COSIGN_PASSWORD" \
        --network "$COMPOSE_NETWORK" \
        -v "$SCRIPT_DIR:/workspace" -w /workspace \
        gcr.io/projectsigstore/cosign:latest attest \
        --yes \
        --key /workspace/cosign.key \
        --type spdxjson \
        --predicate /workspace/reports/sbom.spdx.json \
        --allow-insecure-registry \
        --allow-http-registry \
        "$INTERNAL_IMAGE_TARGET" >/dev/null 2>&1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] In-Toto SPDX Attestation cryptographically attached to image in OCI registry."

# ------------------------------------------------------------------------------
# STEP 6: Cryptographically Sign the Container Image with Cosign
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [6/6] Cryptographically Signing Container Image Digest with Cosign...${CLR_RESET}"

if [ "$USE_NATIVE_COSIGN" = true ]; then
    COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign sign \
        --yes \
        --key "$KEY_PATH" \
        --allow-insecure-registry \
        --allow-http-registry \
        "$IMAGE_TARGET" >/dev/null 2>&1
else
    docker run --rm -e HOME=/tmp -e COSIGN_PASSWORD="$COSIGN_PASSWORD" \
        --network "$COMPOSE_NETWORK" \
        -v "$SCRIPT_DIR:/workspace" -w /workspace \
        gcr.io/projectsigstore/cosign:latest sign \
        --yes \
        --key /workspace/cosign.key \
        --allow-insecure-registry \
        --allow-http-registry \
        "$INTERNAL_IMAGE_TARGET" >/dev/null 2>&1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Signature generated and uploaded to OCI registry."

# Generate Signing Manifest Metadata
SIGNING_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat <<EOF > "$REPORTS_DIR/signing_manifest.json"
{
  "timestamp": "$SIGNING_TIMESTAMP",
  "image": "$IMAGE_TARGET",
  "digest": "$IMAGE_DIGEST",
  "key_public": "$PUB_PATH",
  "sbom_spdx": "$SPDX_REPORT",
  "sbom_cyclonedx": "$CYCLONEDX_REPORT",
  "packages_cataloged": $TOTAL_PKGS,
  "signature_algorithm": "ECDSA-P256-SHA256",
  "status": "SIGNED_AND_ATTESTED"
}
EOF

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================"
echo "  ✅ SIGNING & SBOM PIPELINE COMPLETED SUCCESSFULLY"
echo "======================================================================${CLR_RESET}"
echo -e " Signed Target    : ${CLR_BOLD}${IMAGE_TARGET}${CLR_RESET}"
echo -e " Digest           : ${CLR_GRAY}${IMAGE_DIGEST}${CLR_RESET}"
echo -e " Public Key       : ${CLR_GRAY}${PUB_PATH}${CLR_RESET}"
echo -e " Signing Manifest : ${CLR_GRAY}${REPORTS_DIR}/signing_manifest.json${CLR_RESET}"
echo -e " Run Verification : ${CLR_CYAN}./verify_image_signature.sh ${IMAGE_TARGET}${CLR_RESET}"
echo "======================================================================"
