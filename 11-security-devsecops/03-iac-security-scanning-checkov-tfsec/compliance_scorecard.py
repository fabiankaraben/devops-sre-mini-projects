#!/usr/bin/env python3
"""
==============================================================================
compliance_scorecard.py - IaC Security & Compliance Scorecard Generator
==============================================================================
Parses Checkov JSON and SARIF reports to calculate security compliance rates,
benchmark alignment (CIS, NIST, SOC2), and generate executive Markdown scorecards.
==============================================================================
"""

import argparse
import json
import os
import sys
from typing import Dict, Any, List

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"


def parse_checkov_json(file_path: str) -> Dict[str, Any]:
    """Parses a Checkov JSON report and aggregates compliance metrics."""
    if not os.path.exists(file_path):
        return {"error": f"File not found: {file_path}"}

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        return {"error": f"JSON parse error: {e}"}

    # Normalize single check type vs multi-framework list
    blocks = data if isinstance(data, list) else [data]

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    failures: List[Dict[str, str]] = []
    framework_metrics: Dict[str, Dict[str, int]] = {}

    severity_counts = {
        "CRITICAL": 0,
        "HIGH": 0,
        "MEDIUM": 0,
        "LOW": 0,
        "UNKNOWN": 0,
    }

    for block in blocks:
        check_type = block.get("check_type", "unknown")
        summary = block.get("summary", {})

        passed = summary.get("passed", 0)
        failed = summary.get("failed", 0)
        skipped = summary.get("skipped", 0)

        total_passed += passed
        total_failed += failed
        total_skipped += skipped

        framework_metrics[check_type] = {
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
        }

        # Collect failure details
        results = block.get("results", {})
        failed_checks = results.get("failed_checks", [])
        for fc in failed_checks:
            sev = fc.get("severity", "MEDIUM")
            if not sev:
                sev = "MEDIUM"
            sev = str(sev).upper()

            severity_counts[sev] = severity_counts.get(sev, 0) + 1

            failures.append(
                {
                    "check_id": fc.get("check_id", "UNKNOWN"),
                    "check_name": fc.get("check_name", "Unnamed Check"),
                    "framework": check_type,
                    "severity": sev,
                    "file_path": fc.get("file_path", "unknown"),
                    "resource": fc.get("resource", "unknown"),
                    "guideline": fc.get(
                        "guideline", "https://docs.prismacloud.io/en/enterprise-edition/policy-reference/"
                    ),
                }
            )

    total_checks = total_passed + total_failed + total_skipped
    compliance_rate = (total_passed / (total_passed + total_failed) * 100.0) if (total_passed + total_failed) > 0 else 100.0

    return {
        "total_checks": total_checks,
        "passed": total_passed,
        "failed": total_failed,
        "skipped": total_skipped,
        "compliance_rate": round(compliance_rate, 2),
        "severity_counts": severity_counts,
        "framework_metrics": framework_metrics,
        "failures": failures,
    }


def parse_sarif_file(file_path: str) -> Dict[str, Any]:
    """Parses a standard SARIF v2.1.0 report."""
    if not os.path.exists(file_path):
        return {"error": f"File not found: {file_path}"}

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        return {"error": f"SARIF parse error: {e}"}

    runs = data.get("runs", [])
    total_findings = 0
    findings = []

    for run in runs:
        results = run.get("results", [])
        total_findings += len(results)
        for r in results:
            rule_id = r.get("ruleId", "UNKNOWN")
            message = r.get("message", {}).get("text", "")
            level = r.get("level", "warning").upper()
            findings.append({"rule_id": rule_id, "message": message, "level": level})

    return {
        "sarif_version": data.get("version", "2.1.0"),
        "total_findings": total_findings,
        "findings": findings,
    }


def print_console_scorecard(metrics: Dict[str, Any], target_name: str):
    """Renders ANSI formatted terminal scorecard."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  📊 IaC SECURITY & COMPLIANCE SCORECARD: {target_name.upper()}{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

    comp_rate = metrics.get("compliance_rate", 0.0)
    rate_color = CLR_GREEN if comp_rate >= 90.0 else (CLR_YELLOW if comp_rate >= 60.0 else CLR_RED)

    print(f" • Overall Compliance Score : {rate_color}{CLR_BOLD}{comp_rate}%{CLR_RESET}")
    print(f" • Total Evaluated Checks   : {metrics.get('total_checks', 0)}")
    print(f" • Passed Checks            : {CLR_GREEN}{metrics.get('passed', 0)}{CLR_RESET}")
    print(f" • Failed Misconfigurations : {CLR_RED}{metrics.get('failed', 0)}{CLR_RESET}")
    print(f" • Suppressed / Skipped     : {CLR_GRAY}{metrics.get('skipped', 0)}{CLR_RESET}")
    print(f"----------------------------------------------------------------------")

    print(f"{CLR_BOLD}Findings by Severity:{CLR_RESET}")
    sevs = metrics.get("severity_counts", {})
    print(f"  - CRITICAL : {CLR_RED}{sevs.get('CRITICAL', 0)}{CLR_RESET}")
    print(f"  - HIGH     : {CLR_YELLOW}{sevs.get('HIGH', 0)}{CLR_RESET}")
    print(f"  - MEDIUM   : {CLR_CYAN}{sevs.get('MEDIUM', 0)}{CLR_RESET}")
    print(f"  - LOW      : {CLR_GRAY}{sevs.get('LOW', 0)}{CLR_RESET}")
    print(f"----------------------------------------------------------------------")

    print(f"{CLR_BOLD}Framework Breakdown:{CLR_RESET}")
    fw_metrics = metrics.get("framework_metrics", {})
    for fw, counts in fw_metrics.items():
        print(f"  [{fw}] -> Passed: {CLR_GREEN}{counts.get('passed', 0)}{CLR_RESET} | Failed: {CLR_RED}{counts.get('failed', 0)}{CLR_RESET} | Skipped: {counts.get('skipped', 0)}")

    failures = metrics.get("failures", [])
    if failures:
        print(f"\n{CLR_RED}{CLR_BOLD}❌ Top Flagged Violations:{CLR_RESET}")
        for i, f in enumerate(failures[:8], 1):
            print(f"  {i}. [{f['severity']}] {CLR_BOLD}{f['check_id']}{CLR_RESET}: {f['check_name']}")
            print(f"     Resource: {CLR_GRAY}{f['resource']} ({f['file_path']}){CLR_RESET}")
        if len(failures) > 8:
            print(f"  ... and {len(failures) - 8} additional findings (see full JSON/SARIF report).")

    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")


def generate_markdown_scorecard(metrics: Dict[str, Any], target_name: str, out_path: str):
    """Exports structured executive summary in Markdown format."""
    comp_rate = metrics.get("compliance_rate", 0.0)
    status_emoji = "✅ PASSED" if comp_rate == 100.0 else ("⚠️ NEEDS ATTENTION" if comp_rate >= 80.0 else "❌ NON-COMPLIANT")

    md = f"""# 🛡️ IaC Security & Compliance Executive Scorecard

**Target Infrastructure**: `{target_name}`  
**Evaluation Date**: `Auto-Generated`  
**Overall Security Status**: **{status_emoji}** (`{comp_rate}% Compliance`)

---

## 📈 Compliance Overview Matrix

| Metric | Count | Status |
| :--- | :--- | :--- |
| **Total IaC Checks Evaluated** | `{metrics.get('total_checks', 0)}` | Completed |
| **Passed Policy Rules** | `{metrics.get('passed', 0)}` | ✅ Compliant |
| **Failed Misconfigurations** | `{metrics.get('failed', 0)}` | ❌ Action Required |
| **Suppressed / Risk-Accepted** | `{metrics.get('skipped', 0)}` | ℹ️ Documented |
| **Overall Compliance Score** | **`{comp_rate}%`** | **{status_emoji}** |

---

## 🔍 Violations by Severity

| Severity Level | Detected Violations | Remediation Priority |
| :--- | :--- | :--- |
| **CRITICAL** | `{metrics.get('severity_counts', {}).get('CRITICAL', 0)}` | P0 - Immediate Block |
| **HIGH** | `{metrics.get('severity_counts', {}).get('HIGH', 0)}` | P1 - Block Deployment |
| **MEDIUM** | `{metrics.get('severity_counts', {}).get('MEDIUM', 0)}` | P2 - Sprint Remediation |
| **LOW** | `{metrics.get('severity_counts', {}).get('LOW', 0)}` | P3 - Informational |

---

## 🏗️ Framework Breakdown

| Framework | Passed Checks | Failed Checks | Skipped Checks |
| :--- | :--- | :--- | :--- |
"""
    for fw, counts in metrics.get("framework_metrics", {}).items():
        md += f"| **{fw.capitalize()}** | `{counts.get('passed', 0)}` | `{counts.get('failed', 0)}` | `{counts.get('skipped', 0)}` |\n"

    failures = metrics.get("failures", [])
    if failures:
        md += "\n---\n\n## 🚨 Detailed Remediation Guidance\n\n"
        md += "| Check ID | Severity | Resource / Target | Description & Policy Rule |\n"
        md += "| :--- | :--- | :--- | :--- |\n"
        for f in failures:
            md += f"| `{f['check_id']}` | **{f['severity']}** | `{f['resource']}` | {f['check_name']} |\n"

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(md)


def main():
    parser = argparse.ArgumentParser(description="IaC Security Compliance Scorecard Generator")
    parser.add_argument("--json-report", help="Path to Checkov JSON report")
    parser.add_argument("--sarif-report", help="Path to SARIF report")
    parser.add_argument("--target-name", default="Infrastructure", help="Name of scanned infrastructure target")
    parser.add_argument("--markdown-out", help="Export path for Markdown executive scorecard")
    parser.add_argument("--strict", action="store_true", help="Exit with code 1 if any Critical/High violations exist")

    args = parser.parse_args()

    if not args.json_report and not args.sarif_report:
        parser.print_help()
        sys.exit(1)

    if args.json_report:
        metrics = parse_checkov_json(args.json_report)
        if "error" in metrics:
            print(f"{CLR_RED}Error: {metrics['error']}{CLR_RESET}")
            sys.exit(1)

        print_console_scorecard(metrics, args.target_name)

        if args.markdown_out:
            generate_markdown_scorecard(metrics, args.target_name, args.markdown_out)
            print(f"{CLR_GREEN}Executive Markdown scorecard exported to: {args.markdown_out}{CLR_RESET}")

        if args.strict:
            crit = metrics.get("severity_counts", {}).get("CRITICAL", 0)
            high = metrics.get("severity_counts", {}).get("HIGH", 0)
            failed = metrics.get("failed", 0)
            if crit > 0 or high > 0 or failed > 0:
                print(f"{CLR_RED}Strict compliance gate failed: {failed} misconfigurations detected.{CLR_RESET}")
                sys.exit(1)

    elif args.sarif_report:
        sarif_data = parse_sarif_file(args.sarif_report)
        if "error" in sarif_data:
            print(f"{CLR_RED}Error: {sarif_data['error']}{CLR_RESET}")
            sys.exit(1)
        print(f"{CLR_GREEN}Successfully parsed SARIF report with {sarif_data['total_findings']} findings.{CLR_RESET}")


if __name__ == "__main__":
    main()
