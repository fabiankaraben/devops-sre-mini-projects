#!/usr/bin/env bash
# ==============================================================================
# test_cosign_pipeline.sh - Automated E2E Test Suite for Mini-Project 11-06
# ==============================================================================
# End-to-end verification of container image signing, SBOM generation,
# cryptographic attestation, admission verification, and tamper detection.
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

PASSED_TESTS=0
FAILED_TESTS=0

log_header() {
    echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
    echo "  $1"
    echo "======================================================================${CLR_RESET}"
}

log_step() {
    echo -e "${CLR_YELLOW}▶ $1${CLR_RESET}"
}

assert_test() {
    local test_name="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] $test_name (Exit Code: $exit_code)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

log_header "🧪 STARTING COSIGN IMAGE SIGNING & SBOM AUTOMATED TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/7] Validating runtime dependencies..."

if command -v docker >/dev/null 2>&1; then
    assert_test "Docker CLI is available" 0
else
    assert_test "Docker CLI is available" 1
fi

if command -v python3 >/dev/null 2>&1; then
    assert_test "Python 3 is available" 0
else
    assert_test "Python 3 is available" 1
fi

# ------------------------------------------------------------------------------
# STEP 1: Launch Local OCI Registry
# ------------------------------------------------------------------------------
log_step "[Step 1/7] Ensuring local OCI registry is running..."

COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

if [[ -n "$COMPOSE_CMD" ]]; then
    $COMPOSE_CMD up -d local-registry >/dev/null 2>&1
    sleep 2
    if docker ps --format '{{.Names}}' | grep -q "local-oci-registry"; then
        assert_test "Local OCI Registry (Docker Compose) is active on port 5001" 0
    else
        assert_test "Local OCI Registry (Docker Compose) is active on port 5001" 1
    fi
fi

# ------------------------------------------------------------------------------
# STEP 2: Execute sign_pipeline.sh on Target Microservice
# ------------------------------------------------------------------------------
log_step "[Step 2/7] Executing sign_pipeline.sh (Keygen, Build, SBOM, Sign, Attest)..."

if ./sign_pipeline.sh --image localhost:5001/secure-app:1.0.0 >/dev/null 2>&1; then
    assert_test "sign_pipeline.sh executed successfully" 0
else
    assert_test "sign_pipeline.sh executed successfully" 1
fi

# Assert Artifact Creation
if [[ -f "$SCRIPT_DIR/cosign.key" && -f "$SCRIPT_DIR/cosign.pub" ]]; then
    assert_test "Cosign ECDSA keypair generated (cosign.key, cosign.pub)" 0
else
    assert_test "Cosign ECDSA keypair generated (cosign.key, cosign.pub)" 1
fi

if [[ -f "$SCRIPT_DIR/reports/sbom.spdx.json" && -f "$SCRIPT_DIR/reports/sbom.cyclonedx.json" ]]; then
    assert_test "Multi-format SBOMs generated (SPDX 2.3 & CycloneDX 1.5)" 0
else
    assert_test "Multi-format SBOMs generated (SPDX 2.3 & CycloneDX 1.5)" 1
fi

if [[ -f "$SCRIPT_DIR/reports/signing_manifest.json" ]]; then
    assert_test "Signing manifest created (reports/signing_manifest.json)" 0
else
    assert_test "Signing manifest created (reports/signing_manifest.json)" 1
fi

# ------------------------------------------------------------------------------
# STEP 3: Verify Genuine Signed Image Signature
# ------------------------------------------------------------------------------
log_step "[Step 3/7] Verifying signature of genuine image (Expecting PASS)..."

if ./verify_image_signature.sh localhost:5001/secure-app:1.0.0 >/dev/null 2>&1; then
    assert_test "Signature verification for localhost:5001/secure-app:1.0.0 passed" 0
else
    assert_test "Signature verification for localhost:5001/secure-app:1.0.0 passed" 1
fi

# ------------------------------------------------------------------------------
# STEP 4: Verify In-Toto SBOM Attestation
# ------------------------------------------------------------------------------
log_step "[Step 4/7] Verifying attached SBOM attestation (Expecting PASS)..."

if ./verify_image_signature.sh --verify-attestation localhost:5001/secure-app:1.0.0 >/dev/null 2>&1; then
    assert_test "In-Toto SPDX SBOM attestation verification passed" 0
else
    assert_test "In-Toto SPDX SBOM attestation verification passed" 1
fi

# ------------------------------------------------------------------------------
# STEP 5: Tamper Detection & Unsigned Image Security Gate (Expecting REJECT)
# ------------------------------------------------------------------------------
log_step "[Step 5/7] Simulating container tampering & verifying rejection (Expecting FAIL/REJECT)..."

# Build and push a modified container with a malicious payload
docker build -t localhost:5001/secure-app:tampered -q -f - . >/dev/null 2>&1 << 'EOF'
FROM localhost:5001/secure-app:1.0.0
USER root
RUN echo "malicious_backdoor_payload" > /app/backdoor.sh
USER 10001:10001
EOF
docker push localhost:5001/secure-app:tampered >/dev/null 2>&1

if ./verify_image_signature.sh localhost:5001/secure-app:tampered >/dev/null 2>&1; then
    assert_test "Security Gate blocked tampered unsigned image (localhost:5001/secure-app:tampered)" 1
else
    assert_test "Security Gate blocked tampered unsigned image (localhost:5001/secure-app:tampered)" 0
fi

# ------------------------------------------------------------------------------
# STEP 6: Verify Rejection with Invalid/Forged Public Key
# ------------------------------------------------------------------------------
log_step "[Step 6/7] Testing signature verification with invalid public key..."

# Generate a temporary fake key
FAKE_PUB="$SCRIPT_DIR/reports/fake_test.pub"
echo "-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9Z5v5n3u7v8x0y1z2a3b4c5d6e7f
8g9h0i1j2k3l4m5n6o7p8q9r0s1t2u3v4w5x6y7z8a9b0c1d2e3f4g==
-----END PUBLIC KEY-----" > "$FAKE_PUB"

if ./verify_image_signature.sh --pub "$FAKE_PUB" localhost:5001/secure-app:1.0.0 >/dev/null 2>&1; then
    assert_test "Security Gate rejected verification with unauthorized public key" 1
else
    assert_test "Security Gate rejected verification with unauthorized public key" 0
fi
rm -f "$FAKE_PUB"

# ------------------------------------------------------------------------------
# STEP 7: Execute sbom_analyzer.py & Validate Compliance Output
# ------------------------------------------------------------------------------
log_step "[Step 7/7] Validating sbom_analyzer.py report generation..."

if python3 sbom_analyzer.py -f reports/sbom.spdx.json -o reports/sbom_analysis.md >/dev/null 2>&1; then
    assert_test "sbom_analyzer.py executed successfully on SPDX SBOM" 0
else
    assert_test "sbom_analyzer.py executed successfully on SPDX SBOM" 1
fi

if [[ -f "$SCRIPT_DIR/reports/sbom_analysis.md" ]]; then
    assert_test "Executive SBOM Markdown compliance report created" 0
else
    assert_test "Executive SBOM Markdown compliance report created" 1
fi

# ------------------------------------------------------------------------------
# Test Suite Summary
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY"
echo -e "  Tests Passed : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Tests Failed : ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
echo -e "  Total Tests  : $((PASSED_TESTS + FAILED_TESTS))"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL COSIGN & SBOM TESTS PASSED SUCCESSFULLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. PLEASE CHECK LOGS ABOVE.${CLR_RESET}\n"
    exit 1
fi
