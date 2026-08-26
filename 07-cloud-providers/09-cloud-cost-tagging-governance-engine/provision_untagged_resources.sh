#!/usr/bin/env bash
# ==============================================================================
# provision_untagged_resources.sh - Test Resource Provisioner for Project 09
# ==============================================================================
# Generates synthetic and cloud resources with intentional tag compliance gaps
# to trigger, test, and verify the FinOps Cost Governance & Tag Compliance Engine.
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

URL="http://localhost:8080"
USE_MOCK=false
VERBOSE=false

show_help() {
    echo "Usage: ./provision_untagged_resources.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --url URL      Target governance engine endpoint (default: http://localhost:8080)"
    echo "  --mock         Execute tests against offline Python simulator"
    echo "  --verbose, -v  Show detailed request and response payloads"
    echo "  --help, -h     Show this help message"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            URL="$2"
            shift 2
            ;;
        --mock)
            USE_MOCK=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if [[ "$USE_MOCK" == true ]]; then
    echo -e "${CLR_BLUE}${CLR_BOLD}▶ Running offline provisioning test...${CLR_RESET}"
    python3 "$SCRIPT_DIR/governance_simulator.py" ${VERBOSE:+--verbose}
    exit $?
fi

echo -e "${CLR_BLUE}${CLR_BOLD}"
echo "======================================================================"
echo "  🏷️ Provisioning Synthetic Test Resources for Tag Audit"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Test payload containing a mix of compliant and non-compliant cloud resources
PAYLOAD='{
  "resources": [
    {
      "id": "i-09988776655443321",
      "type": "ec2",
      "name": "prod-k8s-worker-node-01",
      "tags": {
        "Name": "prod-k8s-worker-node-01",
        "Environment": "production",
        "Owner": "platform-sre@company.com",
        "CostCenter": "CC-1001",
        "Project": "kubernetes-platform",
        "InstanceType": "c5.xlarge"
      }
    },
    {
      "id": "i-09988776655443322",
      "type": "ec2",
      "name": "dev-shadow-it-mining-box",
      "tags": {
        "Name": "dev-shadow-it-mining-box",
        "InstanceType": "m5.large"
      }
    },
    {
      "id": "i-09988776655443323",
      "type": "ec2",
      "name": "staging-misconfigured-app",
      "tags": {
        "Name": "staging-misconfigured-app",
        "Environment": "preprod",
        "Owner": "john_invalid_handle",
        "CostCenter": "9999",
        "Project": "mobile-backend",
        "InstanceType": "t3.medium"
      }
    },
    {
      "id": "arn:aws:s3:::prod-customer-invoice-vault",
      "type": "s3",
      "name": "prod-customer-invoice-vault",
      "tags": {
        "Environment": "production",
        "Owner": "finance-ops@company.com",
        "CostCenter": "CC-2002",
        "Project": "billing-engine"
      }
    },
    {
      "id": "arn:aws:s3:::untracked-log-dumpster-tmp",
      "type": "s3",
      "name": "untracked-log-dumpster-tmp",
      "tags": {}
    },
    {
      "id": "db-PROD-CUSTOMER-POSTGRES-PRIMARY",
      "type": "rds",
      "name": "db-PROD-CUSTOMER-POSTGRES-PRIMARY",
      "tags": {
        "Environment": "production",
        "Owner": "database-lead@company.com",
        "CostCenter": "CC-1001",
        "Project": "customer-data"
      }
    },
    {
      "id": "db-dev-temp-unowned-mysql",
      "type": "rds",
      "name": "db-dev-temp-unowned-mysql",
      "tags": {
        "Environment": "development"
      }
    }
  ]
}'

echo "Dispatching test cloud inventory to Governance Engine at $URL/api/scan..."
HTTP_STATUS=$(curl -s -o "$SCRIPT_DIR/compliance_report.json" -w "%{http_code}" -X POST "$URL/api/scan" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

if [[ "$HTTP_STATUS" == "200" ]]; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Governance audit completed successfully (HTTP 200)!"
    echo ""
    python3 - "$SCRIPT_DIR/compliance_report.json" << 'EOF'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
report = data.get('report', data)
s = report['summary']
print(f"  • Total Resources Scanned  : {s['total_resources']}")
print(f"  • Compliant Resources      : {s['compliant_resources']}")
print(f"  • Non-Compliant Resources  : {s['non_compliant_resources']}")
print(f"  • FinOps Compliance Score  : {s['compliance_score_percent']} %")
print(f"  • Untracked Spend Risk     : ${s['untracked_at_risk_spend_usd']:.2f} / month")
print(f"  • Total Estimated Spend    : ${s['total_estimated_monthly_spend_usd']:.2f} / month")
EOF
    echo ""
    echo -e "Detailed JSON report saved to ${CLR_CYAN}compliance_report.json${CLR_RESET}"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Error calling Governance Engine (HTTP $HTTP_STATUS)!"
    cat "$SCRIPT_DIR/compliance_report.json"
    exit 1
fi
