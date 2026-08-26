#!/usr/bin/env python3
"""
Cloud Cost Governance & Tag Compliance - Offline Simulator
==========================================================
Deterministic Python engine modeling AWS Cloud Cost Governance, Tag Compliance
auditing, Cloud Custodian policy enforcement, FinOps score calculation,
and automated remediation scheduling.

Zero cloud dependencies - runs instantly anywhere for local development and CI/CD.
"""

import argparse
import json
import os
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_BLUE = "\033[1;34m"
CLR_GRAY = "\033[0;90m"

EMAIL_REGEX = re.compile(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$")
COST_CENTER_REGEX = re.compile(r"^CC-\d{3,6}$")


@dataclass
class CloudResource:
    id: str
    type: str  # ec2, s3, rds, ebs
    name: str
    monthly_cost_usd: float
    tags: Dict[str, str] = field(default_factory=dict)
    applied_remediations: Dict[str, str] = field(default_factory=dict)


@dataclass
class TestResult:
    test_id: str
    name: str
    category: str
    expected: str
    actual: str
    passed: bool
    details: str


class FinOpsGovernanceSimulator:
    """Simulates Cloud Cost Tag Governance, Policy Evaluation, and Remediation."""

    def __init__(
        self,
        mandatory_tags: Optional[List[str]] = None,
        allowed_environments: Optional[List[str]] = None,
        grace_period_days: int = 7,
        verbose: bool = False,
    ):
        self.mandatory_tags = mandatory_tags or ["Environment", "Owner", "CostCenter", "Project"]
        self.allowed_environments = allowed_environments or ["production", "staging", "development", "sandbox"]
        self.grace_period_days = grace_period_days
        self.verbose = verbose

        self.resources: List[CloudResource] = []
        self.audit_records: List[Dict[str, Any]] = []
        self.test_results: List[TestResult] = []
        self.execution_logs: List[str] = []

        self._initialize_mock_inventory()

    def log(self, message: str, level: str = "INFO"):
        timestamp = datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]
        log_entry = f"[{timestamp}] [{level:5s}] {message}"
        self.execution_logs.append(log_entry)
        if self.verbose:
            color = CLR_CYAN if level == "INFO" else (CLR_YELLOW if level == "WARN" else CLR_GREEN)
            print(f"  {CLR_GRAY}[{timestamp}]{CLR_RESET} {color}[{level:5s}]{CLR_RESET} {message}")

    def _initialize_mock_inventory(self):
        """Populate realistic heterogeneous cloud resources with varying tag compliance."""
        self.resources = [
            # 1. Compliant Production Web EC2
            CloudResource(
                id="i-01122334455aabb01",
                type="ec2",
                name="prod-web-fleet-01",
                monthly_cost_usd=69.12,  # m5.large
                tags={
                    "Name": "prod-web-fleet-01",
                    "Environment": "production",
                    "Owner": "web-team@company.com",
                    "CostCenter": "CC-1001",
                    "Project": "storefront-api",
                },
            ),
            # 2. Non-Compliant Dev EC2 (Missing Owner & CostCenter)
            CloudResource(
                id="i-01122334455aabb02",
                type="ec2",
                name="dev-experimental-ml-gpu",
                monthly_cost_usd=245.00,  # g4dn.xlarge
                tags={
                    "Name": "dev-experimental-ml-gpu",
                    "Environment": "development",
                    "Project": "ml-poc",
                },
            ),
            # 3. Invalid Tags EC2 (Invalid Email & Bad Environment enum)
            CloudResource(
                id="i-01122334455aabb03",
                type="ec2",
                name="test-legacy-batch-runner",
                monthly_cost_usd=30.36,
                tags={
                    "Name": "test-legacy-batch-runner",
                    "Environment": "local_dev",  # Invalid enum
                    "Owner": "alex_no_domain",  # Invalid email
                    "CostCenter": "999",  # Invalid format
                    "Project": "batch-etl",
                },
            ),
            # 4. Compliant Production S3
            CloudResource(
                id="arn:aws:s3:::prod-customer-documents-archive",
                type="s3",
                name="prod-customer-documents-archive",
                monthly_cost_usd=45.00,
                tags={
                    "Environment": "production",
                    "Owner": "sec-ops@company.com",
                    "CostCenter": "CC-2002",
                    "Project": "doc-archive",
                },
            ),
            # 5. Untagged S3 Bucket (Poison Pill)
            CloudResource(
                id="arn:aws:s3:::orphan-temp-scratch-dumps",
                type="s3",
                name="orphan-temp-scratch-dumps",
                monthly_cost_usd=85.00,
                tags={},
            ),
            # 6. Compliant RDS Instance
            CloudResource(
                id="db-PROD-AURORA-CLUSTER-01",
                type="rds",
                name="db-PROD-AURORA-CLUSTER-01",
                monthly_cost_usd=180.00,
                tags={
                    "Environment": "production",
                    "Owner": "dba-lead@company.com",
                    "CostCenter": "CC-1001",
                    "Project": "payment-service",
                },
            ),
            # 7. Non-Compliant RDS Instance (Missing Project)
            CloudResource(
                id="db-stage-catalog-replica",
                type="rds",
                name="db-stage-catalog-replica",
                monthly_cost_usd=49.60,
                tags={
                    "Environment": "staging",
                    "Owner": "catalog-team@company.com",
                    "CostCenter": "CC-3003",
                },
            ),
        ]
        self.log(f"Initialized mock cloud inventory with {len(self.resources)} resources across EC2, S3, RDS.")

    def evaluate_resource_compliance(self, res: CloudResource) -> Dict[str, Any]:
        """Evaluates a single resource against tag compliance rules."""
        missing = [t for t in self.mandatory_tags if t not in res.tags or not res.tags[t].strip()]
        invalid = []

        if "Environment" in res.tags and res.tags["Environment"].lower() not in self.allowed_environments:
            invalid.append(f"Environment='{res.tags['Environment']}' not in {self.allowed_environments}")

        if "Owner" in res.tags and not EMAIL_REGEX.match(res.tags["Owner"].strip()):
            invalid.append(f"Owner='{res.tags['Owner']}' is not a valid email")

        if "CostCenter" in res.tags and not COST_CENTER_REGEX.match(res.tags["CostCenter"].strip()):
            invalid.append(f"CostCenter='{res.tags['CostCenter']}' must match 'CC-XXXX'")

        is_compliant = len(missing) == 0 and len(invalid) == 0

        term_date = (datetime.now(timezone.utc) + timedelta(days=self.grace_period_days)).strftime("%Y-%m-%d") if not is_compliant else None

        return {
            "id": res.id,
            "name": res.name,
            "type": res.type,
            "is_compliant": is_compliant,
            "missing_tags": missing,
            "invalid_tags": invalid,
            "monthly_cost_usd": res.monthly_cost_usd,
            "termination_date": term_date,
        }

    # --------------------------------------------------------------------------
    # Test Scenario Suite
    # --------------------------------------------------------------------------
    def test_inventory_discovery(self) -> TestResult:
        """GOV-01: Multi-service cloud inventory scanning."""
        ec2_count = sum(1 for r in self.resources if r.type == "ec2")
        s3_count = sum(1 for r in self.resources if r.type == "s3")
        rds_count = sum(1 for r in self.resources if r.type == "rds")

        passed = ec2_count >= 3 and s3_count >= 2 and rds_count >= 2
        res = TestResult(
            test_id="GOV-01",
            name="Multi-Service Inventory Discovery",
            category="Discovery & Ingestion",
            expected="Discover EC2 (>=3), S3 (>=2), and RDS (>=2) instances",
            actual=f"Found {len(self.resources)} total (EC2: {ec2_count}, S3: {s3_count}, RDS: {rds_count})",
            passed=passed,
            details="Engine successfully enumerated resources across distinct AWS service APIs.",
        )
        self.test_results.append(res)
        self.log(f"Test GOV-01: {res.actual} -> Passed={passed}")
        return res

    def test_tag_presence_validation(self) -> TestResult:
        """GOV-02: Mandatory tag presence auditing."""
        audits = [self.evaluate_resource_compliance(r) for r in self.resources]
        missing_count = sum(1 for a in audits if len(a["missing_tags"]) > 0)

        passed = missing_count == 3  # dev-experimental-ml-gpu, orphan-temp-scratch-dumps, db-stage-catalog-replica
        res = TestResult(
            test_id="GOV-02",
            name="Mandatory Tag Presence Auditing",
            category="Policy Enforcement",
            expected="Flag 3 resources missing mandatory tags (Environment, Owner, CostCenter, Project)",
            actual=f"Detected {missing_count} resources with missing mandatory tags",
            passed=passed,
            details="Identified resources lacking required cost allocation keys.",
        )
        self.test_results.append(res)
        self.log(f"Test GOV-02: {res.actual} -> Passed={passed}")
        return res

    def test_format_and_enum_validation(self) -> TestResult:
        """GOV-03: Tag value syntax and enum validation."""
        audits = [self.evaluate_resource_compliance(r) for r in self.resources]
        invalid_res = next((a for a in audits if a["name"] == "test-legacy-batch-runner"), None)

        passed = (
            invalid_res is not None
            and any("Environment" in inv for inv in invalid_res["invalid_tags"])
            and any("Owner" in inv for inv in invalid_res["invalid_tags"])
            and any("CostCenter" in inv for inv in invalid_res["invalid_tags"])
        )
        res = TestResult(
            test_id="GOV-03",
            name="Tag Value Syntax & Enum Validation",
            category="Data Quality",
            expected="Catch invalid environment enum, malformed email, and bad CostCenter format",
            actual=f"Caught {len(invalid_res['invalid_tags']) if invalid_res else 0} syntax violations on test node",
            passed=passed,
            details="Regex and enum filters prevent malformed tag injection into billing pipelines.",
        )
        self.test_results.append(res)
        self.log(f"Test GOV-03: {res.actual} -> Passed={passed}")
        return res

    def test_finops_spend_attribution(self) -> TestResult:
        """GOV-04: FinOps Score & Untracked Spend Calculation."""
        audits = [self.evaluate_resource_compliance(r) for r in self.resources]
        total_spend = sum(a["monthly_cost_usd"] for a in audits)
        untracked_spend = sum(a["monthly_cost_usd"] for a in audits if not a["is_compliant"])
        compliant_count = sum(1 for a in audits if a["is_compliant"])
        score = round(compliant_count / len(audits) * 100.0, 1)

        # 3 compliant out of 7 = 42.9%
        passed = compliant_count == 3 and untracked_spend > 350.0 and score < 50.0
        res = TestResult(
            test_id="GOV-04",
            name="FinOps Score & Untracked Spend Calculation",
            category="FinOps Metrics",
            expected="Calculate compliance score (42.9%) and quantify untracked spend risk (> $350/mo)",
            actual=f"Score: {score}%, Untracked: ${untracked_spend:.2f}/mo (Total: ${total_spend:.2f}/mo)",
            passed=passed,
            details="Accurately mapped untagged assets to financial risk and cost attribution gap.",
        )
        self.test_results.append(res)
        self.log(f"Test GOV-04: {res.actual} -> Passed={passed}")
        return res

    def test_auto_remediation_tagging(self) -> TestResult:
        """GOV-05: Automated Remediation Tagging & Scheduled Termination."""
        applied_tags_count = 0
        expected_term_date = (datetime.now(timezone.utc) + timedelta(days=self.grace_period_days)).strftime("%Y-%m-%d")

        for r in self.resources:
            audit = self.evaluate_resource_compliance(r)
            if not audit["is_compliant"]:
                r.applied_remediations["CustodianCompliance"] = "NonCompliant"
                r.applied_remediations["TerminationDate"] = audit["termination_date"]
                applied_tags_count += 1

        passed = applied_tags_count == 4 and all(
            r.applied_remediations.get("TerminationDate") == expected_term_date
            for r in self.resources
            if r.applied_remediations
        )
        res = TestResult(
            test_id="GOV-05",
            name="Automated Remediation & Deletion Tagging",
            category="Auto-Remediation",
            expected=f"Apply CustodianCompliance=NonCompliant and TerminationDate={expected_term_date} to 4 resources",
            actual=f"Remediated {applied_tags_count} resources with {self.grace_period_days}-day grace window",
            passed=passed,
            details="Remediation tags establish a verifiable audit trail before automated shutdown.",
        )
        self.test_results.append(res)
        self.log(f"Test GOV-05: {res.actual} -> Passed={passed}")
        return res

    def test_slack_and_audit_report_generation(self) -> TestResult:
        """GOV-06: Slack Digest & JSON Audit Report Generation."""
        audits = [self.evaluate_resource_compliance(r) for r in self.resources]
        total_spend = sum(a["monthly_cost_usd"] for a in audits)
        untracked_spend = sum(a["monthly_cost_usd"] for a in audits if not a["is_compliant"])
        compliant_count = sum(1 for a in audits if a["is_compliant"])

        report = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "summary": {
                "total_resources": len(audits),
                "compliant_resources": compliant_count,
                "compliance_score_percent": round(compliant_count / len(audits) * 100.0, 1),
                "untracked_at_risk_spend_usd": round(untracked_spend, 2),
            },
            "resources": audits,
        }

        # Check report serialization
        json_str = json.dumps(report)
        passed = len(json_str) > 500 and "untracked_at_risk_spend_usd" in report["summary"]
        res = TestResult(
            test_id="GOV-06",
            name="Executive Slack Digest & Audit Log Export",
            category="Reporting & Alerting",
            expected="Generate valid JSON audit report and executive summary blocks",
            actual=f"Generated {len(json_str)} bytes report with {len(audits)} resource audit records",
            passed=passed,
            details="Structured data stream ready for S3 archive and Slack webhook consumption.",
        )
        self.test_results.append(res)
        self.log(f"Test GOV-06: {res.actual} -> Passed={passed}")
        return res

    def run_all_tests(self) -> bool:
        """Execute full test suite."""
        print(f"\n{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_BLUE}{CLR_BOLD}  🏷️ Running Cloud Cost Governance & Tag Compliance Simulation{CLR_RESET}")
        print(f"{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}\n")

        self.test_inventory_discovery()
        self.test_tag_presence_validation()
        self.test_format_and_enum_validation()
        self.test_finops_spend_attribution()
        self.test_auto_remediation_tagging()
        self.test_slack_and_audit_report_generation()

        print(f"\n{CLR_BOLD}Simulation Verification Results:{CLR_RESET}")
        print(f"{'ID':<8} {'Category':<22} {'Test Case':<44} {'Status':<10}")
        print("-" * 88)

        all_passed = True
        for r in self.test_results:
            status_badge = f"{CLR_GREEN}PASSED{CLR_RESET}" if r.passed else f"{CLR_RED}FAILED{CLR_RESET}"
            if not r.passed:
                all_passed = False
            print(f"{r.test_id:<8} {r.category:<22} {r.name:<44} {status_badge}")
            if self.verbose:
                print(f"   {CLR_GRAY}Expected: {r.expected}{CLR_RESET}")
                print(f"   {CLR_GRAY}Actual:   {r.actual}{CLR_RESET}")
                print(f"   {CLR_GRAY}Details:  {r.details}{CLR_RESET}\n")

        print("-" * 88)
        return all_passed

    def export_json_report(self, filepath: str):
        """Export full test run summary to JSON."""
        report = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "configuration": {
                "mandatory_tags": self.mandatory_tags,
                "allowed_environments": self.allowed_environments,
                "grace_period_days": self.grace_period_days,
            },
            "summary": {
                "total_tests": len(self.test_results),
                "passed_tests": sum(1 for r in self.test_results if r.passed),
                "failed_tests": sum(1 for r in self.test_results if not r.passed),
                "all_passed": all(r.passed for r in self.test_results),
            },
            "test_results": [asdict(r) for r in self.test_results],
            "execution_logs": self.execution_logs,
        }
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        self.log(f"Exported test report to {filepath}")


def main():
    parser = argparse.ArgumentParser(description="FinOps Cloud Cost Governance & Tag Compliance Simulator")
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose trace logs")
    parser.add_argument("--json-output", type=str, default="", help="Path to write JSON summary report")

    args = parser.parse_args()

    simulator = FinOpsGovernanceSimulator(verbose=args.verbose)
    success = simulator.run_all_tests()

    if args.json_output:
        simulator.export_json_report(args.json_output)

    if success:
        print(f"\n{CLR_GREEN}{CLR_BOLD}🎉 All Cloud Cost Governance & Tag Compliance Tests Passed!{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"\n{CLR_RED}{CLR_BOLD}❌ Some Simulation Tests Failed. Review logs above.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
