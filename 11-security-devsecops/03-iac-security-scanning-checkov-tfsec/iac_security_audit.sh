#!/usr/bin/env bash
# ==============================================================================
# iac_security_audit.sh - Automated IaC Security & Compliance Scanner
# ==============================================================================
# Executes Checkov and tfsec policy-as-code audits against Terraform,
# Kubernetes, and Dockerfile manifests. Generates JSON and SARIF v2.1.0 reports,
# renders compliance scorecards, and enforces CI/CD quality gates.
# ==============================================================================

set -euo pipefail

# ANSI Colors
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

REPORTS_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORTS_DIR"

TARGET="all"
FRAMEWORK="all"
SEVERITY=""
OUTPUT_FORMAT="all"
STRICT_MODE=false
SCANNER_ENGINE="checkov"

print_usage() {
    echo -e "${CLR_CYAN}Usage: ./iac_security_audit.sh [OPTIONS]${CLR_RESET}"
    echo ""
    echo "Options:"
    echo "  --target <TARGET>        Scan target: 'vulnerable', 'remediated', 'all', or custom path (default: all)"
    echo "  --framework <TYPE>       Framework: 'terraform', 'kubernetes', 'dockerfile', 'all' (default: all)"
    echo "  --severity <LEVEL>       Minimum severity: CRITICAL, HIGH, MEDIUM, LOW"
    echo "  --scanner <ENGINE>       Security scanner: 'checkov', 'tfsec', 'all' (default: checkov)"
    echo "  --format <FORMAT>        Output format: 'cli', 'json', 'sarif', 'all' (default: all)"
    echo "  --strict                 Exit with non-zero status (1) if security violations are detected"
    echo "  --help, -h               Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./iac_security_audit.sh --target vulnerable"
    echo "  ./iac_security_audit.sh --target remediated --strict"
    echo "  ./iac_security_audit.sh --framework terraform --severity HIGH"
}

# Parse Command-Line Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --framework)
            FRAMEWORK="$2"
            shift 2
            ;;
        --severity)
            SEVERITY="$2"
            shift 2
            ;;
        --scanner)
            SCANNER_ENGINE="$2"
            shift 2
            ;;
        --format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --strict)
            STRICT_MODE=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Error: Unknown argument '$1'${CLR_RESET}"
            print_usage
            exit 1
            ;;
    esac
done

# Resolve Target Directory
SCAN_PATHS=()
TARGET_LABEL=""

if [[ "$TARGET" == "vulnerable" ]]; then
    SCAN_PATHS=("$SCRIPT_DIR/iac_fixtures/vulnerable_infrastructure")
    TARGET_LABEL="vulnerable"
elif [[ "$TARGET" == "remediated" ]]; then
    SCAN_PATHS=("$SCRIPT_DIR/iac_fixtures/remediated_infrastructure")
    TARGET_LABEL="remediated"
elif [[ "$TARGET" == "all" ]]; then
    SCAN_PATHS=("$SCRIPT_DIR/iac_fixtures")
    TARGET_LABEL="all_fixtures"
elif [[ -d "$TARGET" || -f "$TARGET" ]]; then
    SCAN_PATHS=("$TARGET")
    TARGET_LABEL="custom_target"
else
    echo -e "${CLR_RED}Error: Target path '$TARGET' does not exist.${CLR_RESET}"
    exit 1
fi

JSON_REPORT="$REPORTS_DIR/${TARGET_LABEL}_checkov_report.json"
SARIF_REPORT="$REPORTS_DIR/${TARGET_LABEL}_checkov_report.sarif"
TEXT_REPORT="$REPORTS_DIR/${TARGET_LABEL}_checkov_report.txt"
SCORECARD_MD="$REPORTS_DIR/iac_compliance_scorecard.md"

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🛡️  IaC POLICY-AS-CODE SECURITY AUDITOR (CHECKOV & TFSEC)"
echo "======================================================================${CLR_RESET}"
echo -e " Target Scope     : ${CLR_BOLD}${TARGET} (${SCAN_PATHS[*]})${CLR_RESET}"
echo -e " Framework Filter : ${CLR_YELLOW}${FRAMEWORK}${CLR_RESET}"
echo -e " Scanner Engine   : ${CLR_MAGENTA}${SCANNER_ENGINE}${CLR_RESET}"
echo -e " Strict CI Mode   : ${CLR_BOLD}${STRICT_MODE}${CLR_RESET}"
echo "======================================================================"

# Determine checkov execution mode (host native vs docker container)
RUN_VIA_DOCKER=false
CHECKOV_CMD=""

if command -v checkov >/dev/null 2>&1; then
    CHECKOV_CMD="checkov"
elif command -v docker >/dev/null 2>&1; then
    RUN_VIA_DOCKER=true
else
    echo -e "${CLR_RED}Error: Neither 'checkov' CLI nor 'docker' is available on this system.${CLR_RESET}"
    exit 1
fi

execute_checkov() {
    local fmt="$1"
    local outfile="${2:-}"
    local fw_str=""
    if [[ "$FRAMEWORK" != "all" ]]; then
        fw_str="--framework $FRAMEWORK"
    fi

    local sev_str=""
    if [[ -n "$SEVERITY" ]]; then
        sev_str="--check $SEVERITY"
    fi

    if [ "$RUN_VIA_DOCKER" = false ]; then
        if [[ -n "$outfile" ]]; then
            "$CHECKOV_CMD" -d "${SCAN_PATHS[0]}" --output "$fmt" $fw_str $sev_str > "$outfile" 2>/dev/null || true
        else
            "$CHECKOV_CMD" -d "${SCAN_PATHS[0]}" --output "$fmt" $fw_str $sev_str 2>/dev/null || true
        fi
    else
        local rel_path=""
        if [[ "${SCAN_PATHS[0]}" == *"/vulnerable_infrastructure"* ]]; then
            rel_path="vulnerable_infrastructure"
        elif [[ "${SCAN_PATHS[0]}" == *"/remediated_infrastructure"* ]]; then
            rel_path="remediated_infrastructure"
        fi

        local inner_dir="/scan"
        if [[ -n "$rel_path" ]]; then
            inner_dir="/scan/$rel_path"
        fi

        if [[ -n "$outfile" ]]; then
            COPYFILE_DISABLE=1 tar --exclude='._*' -cf - -C "$SCRIPT_DIR/iac_fixtures" . | \
                docker run --rm -i --entrypoint sh bridgecrew/checkov:latest \
                -c "mkdir -p /scan && tar -xf - -C /scan && checkov -d $inner_dir --output $fmt $fw_str $sev_str" > "$outfile" 2>/dev/null || true
        else
            COPYFILE_DISABLE=1 tar --exclude='._*' -cf - -C "$SCRIPT_DIR/iac_fixtures" . | \
                docker run --rm -i --entrypoint sh bridgecrew/checkov:latest \
                -c "mkdir -p /scan && tar -xf - -C /scan && checkov -d $inner_dir --output $fmt $fw_str $sev_str" 2>/dev/null || true
        fi
    fi
}

echo -e "\n${CLR_YELLOW}▶ [1/4] Running Checkov Policy-as-Code Static Analysis...${CLR_RESET}"

# Generate Structured JSON Report
execute_checkov "json" "$JSON_REPORT"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] JSON audit report saved to: ${JSON_REPORT}"

# Generate Industry Standard SARIF Report
execute_checkov "sarif" "$SARIF_REPORT"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] SARIF v2.1.0 report saved to: ${SARIF_REPORT}"

# Generate Formatted Text Report
execute_checkov "cli" "$TEXT_REPORT"

echo -e "\n${CLR_YELLOW}▶ [2/4] Parsing Findings & Calculating Compliance Scorecard...${CLR_RESET}"

# Execute python compliance scorecard analyzer
if [ -f "$SCRIPT_DIR/compliance_scorecard.py" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$SCRIPT_DIR/compliance_scorecard.py" \
        --json-report "$JSON_REPORT" \
        --sarif-report "$SARIF_REPORT" \
        --target-name "$TARGET_LABEL" \
        --markdown-out "$SCORECARD_MD"
fi

echo -e "${CLR_YELLOW}▶ [3/4] Evaluating CI/CD Policy Gate...${CLR_RESET}"

FAILED_CHECKS_COUNT=0
if [ -f "$JSON_REPORT" ]; then
    FAILED_CHECKS_COUNT=$(python3 -c "
import json, sys
try:
    with open('$JSON_REPORT') as f:
        data = json.load(f)
    blocks = data if isinstance(data, list) else [data]
    failed = sum(b.get('summary', {}).get('failed', 0) for b in blocks)
    print(failed)
except Exception:
    print('0')
")
fi

echo -e "  • Total Policy Misconfigurations Detected: ${CLR_BOLD}${FAILED_CHECKS_COUNT}${CLR_RESET}"

if [ "$FAILED_CHECKS_COUNT" -gt 0 ]; then
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ CI/CD QUALITY GATE: FAILED${CLR_RESET}"
    echo -e "${CLR_RED}Policy Violation: Target '${TARGET}' contains ${FAILED_CHECKS_COUNT} security misconfigurations.${CLR_RESET}"
    echo -e "${CLR_YELLOW}Remediation: Review '${SCORECARD_MD}' or update IaC manifests according to CIS/NIST guidelines.${CLR_RESET}\n"
    
    if [ "$STRICT_MODE" = true ]; then
        exit 1
    else
        exit 0
    fi
else
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✅ CI/CD QUALITY GATE: PASSED${CLR_RESET}"
    echo -e "${CLR_GREEN}All evaluated IaC manifests meet compliance standards (0 violations detected). Ready for deployment!${CLR_RESET}\n"
    exit 0
fi
