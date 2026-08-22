"""
Unit tests for security_report_parser.py.
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

# Add project root to sys.path
PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR))

from security_report_parser import (
    ReportParser,
    SarifGenerator,
    ReportFormatter,
    evaluate_gate,
    SecurityFinding,
)


class TestSecurityReportParser(unittest.TestCase):
    def setUp(self):
        self.fixtures_dir = PROJECT_DIR / "tests" / "fixtures"
        self.gitleaks_fixture = self.fixtures_dir / "mock_gitleaks.json"
        self.semgrep_fixture = self.fixtures_dir / "mock_semgrep.json"
        self.trivy_fs_fixture = self.fixtures_dir / "mock_trivy_fs.json"
        self.trivy_image_fixture = self.fixtures_dir / "mock_trivy_image.json"

    def test_mask_secret(self):
        self.assertEqual(ReportParser.mask_secret(""), "***")
        self.assertEqual(ReportParser.mask_secret("short"), "*****")
        masked = ReportParser.mask_secret("AKIAIOSFODNN7EXAMPLE")
        self.assertTrue(masked.startswith("AKI"))
        self.assertTrue(masked.endswith("PLE"))
        self.assertNotIn("FODNN", masked)

    def test_parse_gitleaks(self):
        findings = ReportParser.parse_gitleaks(self.gitleaks_fixture)
        self.assertEqual(len(findings), 2)
        self.assertEqual(findings[0].tool, "gitleaks")
        self.assertEqual(findings[0].category, "SECRET")
        self.assertEqual(findings[0].severity, "CRITICAL")
        self.assertEqual(findings[0].rule_id, "aws-access-key-id")
        self.assertEqual(findings[0].line_number, 5)

    def test_parse_semgrep(self):
        findings = ReportParser.parse_semgrep(self.semgrep_fixture)
        self.assertEqual(len(findings), 3)
        self.assertEqual(findings[0].tool, "semgrep")
        self.assertEqual(findings[0].category, "SAST")
        self.assertEqual(findings[0].normalized_severity, "HIGH")
        self.assertIn("formatted-sql-query", findings[0].rule_id)
        self.assertEqual(findings[2].normalized_severity, "MEDIUM")

    def test_parse_trivy_fs(self):
        findings = ReportParser.parse_trivy(self.trivy_fs_fixture, "trivy-fs")
        self.assertEqual(len(findings), 2)
        self.assertEqual(findings[0].tool, "trivy-fs")
        self.assertEqual(findings[0].category, "SCA")
        self.assertEqual(findings[0].cve_id, "CVE-2018-18074")
        self.assertEqual(findings[0].normalized_severity, "HIGH")
        self.assertEqual(findings[1].cve_id, "CVE-2019-11324")
        self.assertEqual(findings[1].normalized_severity, "CRITICAL")

    def test_parse_trivy_image(self):
        findings = ReportParser.parse_trivy(self.trivy_image_fixture, "trivy-image")
        self.assertEqual(len(findings), 2)
        self.assertEqual(findings[0].tool, "trivy-image")
        self.assertEqual(findings[0].category, "CONTAINER")
        self.assertEqual(findings[0].cve_id, "CVE-2023-4911")
        self.assertEqual(findings[0].normalized_severity, "CRITICAL")

    def test_sarif_generation(self):
        findings = (
            ReportParser.parse_gitleaks(self.gitleaks_fixture)
            + ReportParser.parse_semgrep(self.semgrep_fixture)
            + ReportParser.parse_trivy(self.trivy_fs_fixture, "trivy-fs")
        )
        sarif = SarifGenerator.findings_to_sarif(findings)
        self.assertEqual(sarif["version"], "2.1.0")
        self.assertEqual(len(sarif["runs"]), 1)
        run = sarif["runs"][0]
        self.assertEqual(run["tool"]["driver"]["name"], "DevSecOps-MultiStage-Security-Pipeline")
        self.assertEqual(len(run["results"]), len(findings))
        self.assertGreater(len(run["tool"]["driver"]["rules"]), 0)

    def test_quality_gate_evaluation(self):
        findings = [
            SecurityFinding(
                tool="gitleaks",
                category="SECRET",
                rule_id="dummy-key",
                title="Dummy Secret",
                severity="CRITICAL",
                file_path="config.py",
            )
        ]
        # Strict gate should fail on secret
        passed, reasons = evaluate_gate(findings, {"max_critical": 0, "max_high": 0, "max_secrets": 0})
        self.assertFalse(passed)
        self.assertEqual(len(reasons), 2)  # critical count > 0 and secrets count > 0

        # Permissive gate should pass
        passed_loose, _ = evaluate_gate(findings, {"max_critical": 5, "max_high": 5, "max_secrets": 5})
        self.assertTrue(passed_loose)

    def test_empty_reports_handling(self):
        non_existent = PROJECT_DIR / "tests" / "fixtures" / "non_existent.json"
        self.assertEqual(ReportParser.parse_gitleaks(non_existent), [])
        self.assertEqual(ReportParser.parse_semgrep(non_existent), [])
        self.assertEqual(ReportParser.parse_trivy(non_existent), [])

        empty_sarif = SarifGenerator.findings_to_sarif([])
        self.assertEqual(empty_sarif["runs"][0]["results"], [])

    def test_cli_execution_with_breach(self):
        cmd = [
            sys.executable,
            str(PROJECT_DIR / "security_report_parser.py"),
            "--gitleaks", str(self.gitleaks_fixture),
            "--semgrep", str(self.semgrep_fixture),
            "--fail-on-breach",
            "--quiet",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)

    def test_cli_execution_without_breach(self):
        cmd = [
            sys.executable,
            str(PROJECT_DIR / "security_report_parser.py"),
            "--gitleaks", str(self.gitleaks_fixture),
            "--semgrep", str(self.semgrep_fixture),
            "--max-critical", "10",
            "--max-high", "10",
            "--max-secrets", "10",
            "--fail-on-breach",
            "--quiet",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
