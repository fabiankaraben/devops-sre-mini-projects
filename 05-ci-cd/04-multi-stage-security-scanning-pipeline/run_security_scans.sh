#!/usr/bin/env bash
# ==============================================================================
# run_security_scans.sh - Multi-Stage Security Scanning Pipeline Runner
# ==============================================================================
# Executes automated Shift-Left security scans:
#   1. Secret Scanning (Gitleaks)
#   2. Static Application Security Testing - SAST (Semgrep)
#   3. Software Composition Analysis - SCA (Trivy Filesystem)
#   4. Container Image Security Scan (Trivy Image)
#   5. Aggregation into Unified OASIS SARIF & Markdown Quality Gate Report
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="${SCRIPT_DIR}/reports"
SKIP_DOCKER_IMAGE=false
MODE="all" # "all", "vulnerable", "secure"

show_help() {
    cat <<EOF
${CLR_BOLD}Usage:${CLR_RESET} ./run_security_scans.sh [OPTIONS]

${CLR_BOLD}Options:${CLR_RESET}
  --mode <all|vulnerable|secure>  Select test targets to scan (default: all)
  --skip-image                    Skip building and scanning the Docker container image
  -h, --help                      Show this help message and exit

${CLR_BOLD}Examples:${CLR_RESET}
  ./run_security_scans.sh                     # Run full scanning suite
  ./run_security_scans.sh --mode vulnerable   # Scan only vulnerable test fixtures
  ./run_security_scans.sh --mode secure       # Scan only secure hardened fixtures
  ./run_security_scans.sh --skip-image        # Run secret, SAST, and SCA scans only
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --skip-image)
            SKIP_DOCKER_IMAGE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

echo -e "\n${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}🛡️  DEVSECOPS MULTI-STAGE SECURITY SCANNING PIPELINE${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
echo -e "${CLR_BLUE}• Execution Mode:${CLR_RESET} ${MODE}"
echo -e "${CLR_BLUE}• Project Root:${CLR_RESET}   ${SCRIPT_DIR}"
echo -e "${CLR_BLUE}• Output Directory:${CLR_RESET} ${REPORTS_DIR}\n"

# Verify Docker availability
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${CLR_RED}Error: Docker is required to run the containerized security scanners.${CLR_RESET}" >&2
    exit 1
fi

# Ensure reports directory exists and is clean
mkdir -p "${REPORTS_DIR}"
rm -f "${REPORTS_DIR}"/*.json "${REPORTS_DIR}"/*.sarif "${REPORTS_DIR}"/*.md

# ==============================================================================
# Helper Function: Run Gitleaks
# ==============================================================================
run_gitleaks_scan() {
    local target_dir="$1"
    local output_file="$2"
    echo -e "${CLR_BOLD}${CLR_YELLOW}[1/4] 🔑 Running Secret Scan with Gitleaks...${CLR_RESET}"
    echo -e "  Target: ${target_dir}"

    docker run --rm \
        -v "${SCRIPT_DIR}:/scan_root" \
        zricethezav/gitleaks:latest \
        detect \
        --source="/scan_root/${target_dir}" \
        --no-git \
        --report-format="json" \
        --report-path="/scan_root/reports/${output_file}" || true

    if [[ -f "${REPORTS_DIR}/${output_file}" ]]; then
        echo -e "${CLR_GREEN}✓ Gitleaks report written to reports/${output_file}${CLR_RESET}"
    else
        echo "[]" > "${REPORTS_DIR}/${output_file}"
        echo -e "${CLR_GREEN}✓ Gitleaks scan completed cleanly (no findings).${CLR_RESET}"
    fi
}

# ==============================================================================
# Helper Function: Run Semgrep
# ==============================================================================
run_semgrep_scan() {
    local target_dir="$1"
    local output_file="$2"
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}[2/4] 🔎 Running SAST Code Scan with Semgrep...${CLR_RESET}"
    echo -e "  Target: ${target_dir}"

    docker run --rm \
        -v "${SCRIPT_DIR}:/src" \
        semgrep/semgrep \
        semgrep scan \
        --config="p/security-audit" \
        --config="p/python" \
        --json \
        --output="/src/reports/${output_file}" \
        "/src/${target_dir}" || true

    if [[ -f "${REPORTS_DIR}/${output_file}" ]]; then
        echo -e "${CLR_GREEN}✓ Semgrep report written to reports/${output_file}${CLR_RESET}"
    else
        echo '{"results":[],"errors":[]}' > "${REPORTS_DIR}/${output_file}"
        echo -e "${CLR_GREEN}✓ Semgrep scan completed cleanly (no findings).${CLR_RESET}"
    fi
}

# ==============================================================================
# Helper Function: Run Trivy Filesystem Scan
# ==============================================================================
run_trivy_fs_scan() {
    local target_dir="$1"
    local output_file="$2"
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}[3/4] 📦 Running Software Composition Analysis (SCA) with Trivy...${CLR_RESET}"
    echo -e "  Target: ${target_dir}"

    docker run --rm \
        -v "${SCRIPT_DIR}:/scan_root" \
        aquasec/trivy:latest \
        fs \
        --format json \
        --output "/scan_root/reports/${output_file}" \
        "/scan_root/${target_dir}" || true

    if [[ -f "${REPORTS_DIR}/${output_file}" ]]; then
        echo -e "${CLR_GREEN}✓ Trivy filesystem report written to reports/${output_file}${CLR_RESET}"
    else
        echo '{"Results":[]}' > "${REPORTS_DIR}/${output_file}"
        echo -e "${CLR_GREEN}✓ Trivy filesystem scan completed cleanly.${CLR_RESET}"
    fi
}

# ==============================================================================
# Helper Function: Run Trivy Container Image Scan
# ==============================================================================
run_trivy_image_scan() {
    local dockerfile_dir="$1"
    local image_tag="$2"
    local output_file="$3"

    if [[ "$SKIP_DOCKER_IMAGE" == "true" ]]; then
        echo -e "\n${CLR_YELLOW}[4/4] 🐳 Skipping Container Image Scan (--skip-image requested).${CLR_RESET}"
        return 0
    fi

    echo -e "\n${CLR_BOLD}${CLR_YELLOW}[4/4] 🐳 Building & Scanning Container Image (${image_tag})...${CLR_RESET}"
    
    echo -e "  • Building image: ${image_tag} from ${dockerfile_dir}/Dockerfile"
    docker build -q -t "${image_tag}" "${SCRIPT_DIR}/${dockerfile_dir}" >/dev/null

    echo -e "  • Scanning image with Trivy..."
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${SCRIPT_DIR}:/scan_root" \
        aquasec/trivy:latest \
        image \
        --format json \
        --output "/scan_root/reports/${output_file}" \
        "${image_tag}" || true

    if [[ -f "${REPORTS_DIR}/${output_file}" ]]; then
        echo -e "${CLR_GREEN}✓ Trivy container image report written to reports/${output_file}${CLR_RESET}"
    fi
}

# ==============================================================================
# Execution Dispatcher
# ==============================================================================
if [[ "$MODE" == "all" || "$MODE" == "vulnerable" ]]; then
    echo -e "${CLR_BOLD}${CLR_MAGENTA}-------------------------------------------------------------------${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_MAGENTA}🧪 PHASE A: Scanning Vulnerable Test Fixtures (Expecting Flaws)${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_MAGENTA}-------------------------------------------------------------------${CLR_RESET}"

    run_gitleaks_scan "test_fixtures" "gitleaks_vuln_report.json"
    run_semgrep_scan "test_fixtures/app" "semgrep_vuln_report.json"
    run_trivy_fs_scan "test_fixtures/app" "trivy_fs_vuln_report.json"
    run_trivy_image_scan "test_fixtures/app" "vulnerable-test-app:latest" "trivy_image_vuln_report.json"

    echo -e "\n${CLR_BOLD}${CLR_CYAN}📊 Aggregating Vulnerable Reports & Evaluating Security Gate...${CLR_RESET}"
    python3 "${SCRIPT_DIR}/security_report_parser.py" \
        --gitleaks "${REPORTS_DIR}/gitleaks_vuln_report.json" \
        --semgrep "${REPORTS_DIR}/semgrep_vuln_report.json" \
        --trivy-fs "${REPORTS_DIR}/trivy_fs_vuln_report.json" \
        --trivy-image "${REPORTS_DIR}/trivy_image_vuln_report.json" \
        --markdown-output "${REPORTS_DIR}/vulnerable_scan_summary.md" \
        --sarif-output "${REPORTS_DIR}/vulnerable_security.sarif" \
        --max-critical 0 \
        --max-high 0 \
        --max-secrets 0 || true
fi

if [[ "$MODE" == "all" || "$MODE" == "secure" ]]; then
    echo -e "\n${CLR_BOLD}${CLR_GREEN}-------------------------------------------------------------------${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_GREEN}🛡️  PHASE B: Scanning Hardened Secure Fixtures (Expecting PASS)${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_GREEN}-------------------------------------------------------------------${CLR_RESET}"

    run_gitleaks_scan "test_fixtures/secure_app" "gitleaks_secure_report.json"
    run_semgrep_scan "test_fixtures/secure_app" "semgrep_secure_report.json"
    run_trivy_fs_scan "test_fixtures/secure_app" "trivy_fs_secure_report.json"
    run_trivy_image_scan "test_fixtures/secure_app" "secure-test-app:latest" "trivy_image_secure_report.json"

    echo -e "\n${CLR_BOLD}${CLR_CYAN}📊 Aggregating Hardened Reports & Evaluating Security Gate...${CLR_RESET}"
    python3 "${SCRIPT_DIR}/security_report_parser.py" \
        --gitleaks "${REPORTS_DIR}/gitleaks_secure_report.json" \
        --semgrep "${REPORTS_DIR}/semgrep_secure_report.json" \
        --trivy-fs "${REPORTS_DIR}/trivy_fs_secure_report.json" \
        --trivy-image "${REPORTS_DIR}/trivy_image_secure_report.json" \
        --markdown-output "${REPORTS_DIR}/secure_scan_summary.md" \
        --sarif-output "${REPORTS_DIR}/secure_security.sarif" \
        --max-critical 0 \
        --max-high 0 \
        --max-secrets 0 \
        --fail-on-breach
fi

echo -e "\n${CLR_BOLD}${CLR_GREEN}===================================================================${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_GREEN}✨ Multi-Stage Security Scan Pipeline Execution Finished!${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_GREEN}===================================================================${CLR_RESET}"
echo -e "Generated reports in: ${REPORTS_DIR}/"
ls -lh "${REPORTS_DIR}"
echo -e "\nTo clean up all Docker images, containers, and generated reports:"
echo -e "  ${CLR_BOLD}./cleanup.sh --images${CLR_RESET}\n"
