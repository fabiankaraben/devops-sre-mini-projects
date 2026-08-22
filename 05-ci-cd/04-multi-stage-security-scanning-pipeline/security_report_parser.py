#!/usr/bin/env python3
"""
Multi-Stage Security Report Aggregator & Policy Gate Parser.

Aggregates findings from Gitleaks (Secrets), Semgrep (SAST), and Trivy (SCA & Container),
generates unified OASIS SARIF v2.1.0 reports, prints formatted terminal summaries,
outputs GitHub Actions Markdown summaries, and enforces Security Quality Gates.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


@dataclass
class SecurityFinding:
    tool: str  # gitleaks, semgrep, trivy-fs, trivy-image
    category: str  # SECRET, SAST, SCA, CONTAINER
    rule_id: str
    title: str
    severity: str  # CRITICAL, HIGH, MEDIUM, LOW, INFO
    file_path: str
    line_number: int = 1
    end_line: int = 1
    description: str = ""
    remediation: str = ""
    cve_id: Optional[str] = None
    cwe_ids: List[str] = field(default_factory=list)
    package_name: Optional[str] = None
    installed_version: Optional[str] = None
    fixed_version: Optional[str] = None
    fingerprint: Optional[str] = None

    @property
    def normalized_severity(self) -> str:
        s = (self.severity or "").strip().upper()
        if s in ("CRITICAL", "FATAL"):
            return "CRITICAL"
        if s in ("HIGH", "ERROR"):
            return "HIGH"
        if s in ("MEDIUM", "WARNING", "MODERATE"):
            return "MEDIUM"
        if s in ("LOW", "NOTE"):
            return "LOW"
        return "INFO"


class ReportParser:
    """Parses individual scanner JSON reports into a standardized list of SecurityFindings."""

    @staticmethod
    def mask_secret(secret_text: str) -> str:
        """Masks sensitive token values for safe display in summaries and logs."""
        if not secret_text:
            return "***"
        if len(secret_text) <= 6:
            return "*" * len(secret_text)
        return secret_text[:3] + "*" * (len(secret_text) - 6) + secret_text[-3:]

    @classmethod
    def parse_gitleaks(cls, report_path: Path) -> List[SecurityFinding]:
        findings: List[SecurityFinding] = []
        if not report_path.exists() or report_path.stat().st_size == 0:
            return findings

        try:
            with open(report_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as err:
            sys.stderr.write(f"[WARN] Failed to parse Gitleaks JSON at {report_path}: {err}\n")
            return findings

        if not isinstance(data, list):
            return findings

        for item in data:
            rule_id = item.get("RuleID") or item.get("Description") or "gitleaks-detected-secret"
            description = item.get("Description") or "Hardcoded secret detected"
            file_path = item.get("File") or item.get("SymlinkFile") or "unknown"
            start_line = int(item.get("StartLine", 1))
            end_line = int(item.get("EndLine", start_line))
            secret = item.get("Secret", "")
            masked = cls.mask_secret(secret)
            fingerprint = item.get("Fingerprint")

            findings.append(
                SecurityFinding(
                    tool="gitleaks",
                    category="SECRET",
                    rule_id=rule_id,
                    title=f"Hardcoded Secret: {description}",
                    severity="CRITICAL",
                    file_path=file_path,
                    line_number=max(1, start_line),
                    end_line=max(1, end_line),
                    description=f"Detected leaked credential pattern '{rule_id}' (value: {masked}). Remove immediately and rotate the secret.",
                    remediation="Revoke/rotate the leaked secret immediately. Store credentials in a secrets manager or CI/CD environment variables.",
                    fingerprint=fingerprint,
                )
            )
        return findings

    @classmethod
    def parse_semgrep(cls, report_path: Path) -> List[SecurityFinding]:
        findings: List[SecurityFinding] = []
        if not report_path.exists() or report_path.stat().st_size == 0:
            return findings

        try:
            with open(report_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as err:
            sys.stderr.write(f"[WARN] Failed to parse Semgrep JSON at {report_path}: {err}\n")
            return findings

        results = data.get("results", []) if isinstance(data, dict) else []

        for item in results:
            check_id = item.get("check_id", "semgrep-rule")
            path = item.get("path", "unknown")
            start = item.get("start", {})
            end = item.get("end", {})
            start_line = int(start.get("line", 1))
            end_line = int(end.get("line", start_line))
            extra = item.get("extra", {})
            raw_severity = extra.get("severity", "WARNING")
            message = extra.get("message", "Semgrep security finding")
            metadata = extra.get("metadata", {})
            cwe_list = metadata.get("cwe", [])
            if isinstance(cwe_list, str):
                cwe_list = [cwe_list]

            # Determine title and remediation
            short_id = check_id.split(".")[-1].replace("-", " ").title()
            remediation = "Refactor code to follow secure patterns, sanitize user inputs, or use parameterized queries."
            if "sql" in check_id.lower():
                remediation = "Use parameterized SQL queries (e.g. cursor.execute(query, params)) instead of string concatenation/formatting."
            elif "subprocess" in check_id.lower() or "shell" in check_id.lower():
                remediation = "Set shell=False and pass arguments as a list of strings to prevent command injection."
            elif "md5" in check_id.lower() or "sha1" in check_id.lower():
                remediation = "Upgrade to SHA-256 or a dedicated password hashing algorithm like bcrypt or argon2."
            elif "pickle" in check_id.lower():
                remediation = "Avoid pickle for untrusted input. Use safe data formats like JSON or Protocol Buffers."

            findings.append(
                SecurityFinding(
                    tool="semgrep",
                    category="SAST",
                    rule_id=check_id,
                    title=f"SAST: {short_id}",
                    severity=raw_severity,
                    file_path=path,
                    line_number=max(1, start_line),
                    end_line=max(1, end_line),
                    description=message,
                    remediation=remediation,
                    cwe_ids=cwe_list,
                )
            )
        return findings

    @classmethod
    def parse_trivy(cls, report_path: Path, tool_type: str = "trivy-fs") -> List[SecurityFinding]:
        findings: List[SecurityFinding] = []
        if not report_path.exists() or report_path.stat().st_size == 0:
            return findings

        try:
            with open(report_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as err:
            sys.stderr.write(f"[WARN] Failed to parse Trivy JSON at {report_path}: {err}\n")
            return findings

        results = data.get("Results", []) if isinstance(data, dict) else []
        category = "CONTAINER" if tool_type == "trivy-image" else "SCA"

        for res in results:
            target = res.get("Target", "unknown")
            # 1. Parse Package Vulnerabilities
            vulns = res.get("Vulnerabilities", []) or []
            for vuln in vulns:
                vuln_id = vuln.get("VulnerabilityID", "CVE-UNKNOWN")
                pkg_name = vuln.get("PkgName", "unknown-pkg")
                installed_ver = vuln.get("InstalledVersion", "unknown")
                fixed_ver = vuln.get("FixedVersion")
                severity = vuln.get("Severity", "UNKNOWN")
                title = vuln.get("Title") or f"Vulnerability in {pkg_name}"
                description = vuln.get("Description") or f"{vuln_id} affecting {pkg_name} {installed_ver}"
                cwe_ids = vuln.get("CweIDs") or []
                primary_url = vuln.get("PrimaryURL")

                rem_msg = f"Upgrade package '{pkg_name}' from {installed_ver} to {fixed_ver or 'latest secure version'}."
                if primary_url:
                    rem_msg += f" Advisory: {primary_url}"

                findings.append(
                    SecurityFinding(
                        tool=tool_type,
                        category=category,
                        rule_id=vuln_id,
                        title=f"{vuln_id} ({pkg_name}@{installed_ver})",
                        severity=severity,
                        file_path=target,
                        line_number=1,
                        end_line=1,
                        description=f"{title}: {description}",
                        remediation=rem_msg,
                        cve_id=vuln_id,
                        cwe_ids=cwe_ids,
                        package_name=pkg_name,
                        installed_version=installed_ver,
                        fixed_version=fixed_ver,
                    )
                )

            # 2. Parse Misconfigurations (e.g. running as root)
            misconfigs = res.get("Misconfigurations", []) or []
            for mis in misconfigs:
                rule_id = mis.get("ID", "MISCONF-UNKNOWN")
                title = mis.get("Title", "Container Misconfiguration")
                severity = mis.get("Severity", "MEDIUM")
                desc = mis.get("Description", "")
                resolution = mis.get("Resolution", "Follow Docker hardening guidelines.")

                findings.append(
                    SecurityFinding(
                        tool=tool_type,
                        category=category,
                        rule_id=rule_id,
                        title=f"Misconfiguration: {title}",
                        severity=severity,
                        file_path=target,
                        line_number=1,
                        end_line=1,
                        description=desc,
                        remediation=resolution,
                    )
                )

        return findings


class SarifGenerator:
    """Generates OASIS SARIF v2.1.0 JSON documents from aggregated security findings."""

    @staticmethod
    def findings_to_sarif(findings: List[SecurityFinding]) -> Dict[str, Any]:
        rules_map: Dict[str, Dict[str, Any]] = {}
        sarif_results: List[Dict[str, Any]] = []

        # Map severity to SARIF level
        severity_to_level = {
            "CRITICAL": "error",
            "HIGH": "error",
            "MEDIUM": "warning",
            "LOW": "note",
            "INFO": "note",
        }

        for finding in findings:
            rule_id = finding.rule_id
            if rule_id not in rules_map:
                rule_def: Dict[str, Any] = {
                    "id": rule_id,
                    "name": finding.title.split(":")[0].strip() if ":" in finding.title else finding.title,
                    "shortDescription": {"text": finding.title},
                    "fullDescription": {"text": finding.description[:500]},
                    "defaultConfiguration": {
                        "level": severity_to_level.get(finding.normalized_severity, "warning")
                    },
                    "properties": {
                        "tags": [finding.category.lower(), finding.tool],
                        "precision": "high",
                    },
                }
                if finding.remediation:
                    rule_def["help"] = {
                        "text": finding.remediation,
                        "markdown": f"**Remediation:** {finding.remediation}",
                    }
                rules_map[rule_id] = rule_def

            sarif_result: Dict[str, Any] = {
                "ruleId": rule_id,
                "level": severity_to_level.get(finding.normalized_severity, "warning"),
                "message": {"text": f"{finding.title} - {finding.description[:300]}"},
                "locations": [
                    {
                        "physicalLocation": {
                            "artifactLocation": {
                                "uri": finding.file_path.replace("\\", "/"),
                                "uriBaseId": "%SRCROOT%",
                            },
                            "region": {
                                "startLine": finding.line_number,
                                "endLine": finding.end_line,
                            },
                        }
                    }
                ],
                "properties": {
                    "tool": finding.tool,
                    "category": finding.category,
                    "severity": finding.normalized_severity,
                },
            }
            if finding.fingerprint:
                sarif_result["fingerprints"] = {"primary": finding.fingerprint}

            sarif_results.append(sarif_result)

        return {
            "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
            "version": "2.1.0",
            "runs": [
                {
                    "tool": {
                        "driver": {
                            "name": "DevSecOps-MultiStage-Security-Pipeline",
                            "semanticVersion": "1.0.0",
                            "informationUri": "https://github.com/fabiankaraben/devops-sre-mini-projects",
                            "rules": list(rules_map.values()),
                        }
                    },
                    "results": sarif_results,
                }
            ],
        }


class ReportFormatter:
    """Formats findings for Terminal and GitHub Step Summary Markdown."""

    ANSI_COLORS = {
        "RESET": "\033[0m",
        "BOLD": "\033[1m",
        "RED": "\033[1;31m",
        "YELLOW": "\033[1;33m",
        "BLUE": "\033[1;34m",
        "MAGENTA": "\033[1;35m",
        "CYAN": "\033[1;36m",
        "GREEN": "\033[1;32m",
        "GRAY": "\033[0;90m",
    }

    @classmethod
    def get_summary_stats(cls, findings: List[SecurityFinding]) -> Dict[str, int]:
        stats = {
            "CRITICAL": 0,
            "HIGH": 0,
            "MEDIUM": 0,
            "LOW": 0,
            "INFO": 0,
            "SECRETS": 0,
            "SAST": 0,
            "SCA": 0,
            "CONTAINER": 0,
            "TOTAL": len(findings),
        }
        for f in findings:
            sev = f.normalized_severity
            stats[sev] = stats.get(sev, 0) + 1
            cat = f.category.upper()
            if cat == "SECRET":
                stats["SECRETS"] += 1
            elif cat == "SAST":
                stats["SAST"] += 1
            elif cat == "SCA":
                stats["SCA"] += 1
            elif cat == "CONTAINER":
                stats["CONTAINER"] += 1
        return stats

    @classmethod
    def format_terminal(cls, findings: List[SecurityFinding], thresholds: Dict[str, int]) -> str:
        c = cls.ANSI_COLORS
        stats = cls.get_summary_stats(findings)

        out: List[str] = []
        out.append(f"\n{c['BOLD']}{c['CYAN']}================================================================================{c['RESET']}")
        out.append(f"{c['BOLD']}{c['CYAN']}🛡️  MULTI-STAGE DEVSECOPS SECURITY SCAN REPORT & QUALITY GATE{c['RESET']}")
        out.append(f"{c['BOLD']}{c['CYAN']}================================================================================{c['RESET']}")

        out.append(f"\n{c['BOLD']}📊 Findings Breakdown by Severity:{c['RESET']}")
        out.append(f"  • {c['RED']}CRITICAL: {stats['CRITICAL']}{c['RESET']} (Threshold limit: {thresholds.get('max_critical', 0)})")
        out.append(f"  • {c['YELLOW']}HIGH:     {stats['HIGH']}{c['RESET']} (Threshold limit: {thresholds.get('max_high', 0)})")
        out.append(f"  • {c['BLUE']}MEDIUM:   {stats['MEDIUM']}{c['RESET']}")
        out.append(f"  • {c['GRAY']}LOW/INFO: {stats['LOW'] + stats['INFO']}{c['RESET']}")
        out.append(f"  • {c['BOLD']}TOTAL:    {stats['TOTAL']}{c['RESET']}")

        out.append(f"\n{c['BOLD']}🔍 Findings Breakdown by Category:{c['RESET']}")
        out.append(f"  • 🔑 Secret Scanning (Gitleaks): {stats['SECRETS']} (Limit: {thresholds.get('max_secrets', 0)})")
        out.append(f"  • 🔎 Static Code Analysis (Semgrep): {stats['SAST']}")
        out.append(f"  • 📦 Software Composition (Trivy FS): {stats['SCA']}")
        out.append(f"  • 🐳 Container Image (Trivy Image): {stats['CONTAINER']}")

        if findings:
            out.append(f"\n{c['BOLD']}{c['MAGENTA']}📋 Top Detected Security Findings:{c['RESET']}")
            out.append(f"{'TOOL':<12} {'SEV':<10} {'RULE/CVE':<22} {'LOCATION':<30}")
            out.append("-" * 78)
            for f in findings[:25]:
                sev_color = c['RED'] if f.normalized_severity in ('CRITICAL', 'HIGH') else c['YELLOW']
                loc = f"{f.file_path}:{f.line_number}"
                if len(loc) > 28:
                    loc = "..." + loc[-25:]
                rule = f.rule_id
                if len(rule) > 20:
                    rule = rule[:18] + ".."
                out.append(f"{f.tool:<12} {sev_color}{f.normalized_severity:<10}{c['RESET']} {rule:<22} {loc:<30}")
                if f.remediation:
                    out.append(f"  {c['GRAY']}↳ Fix: {f.remediation[:80]}{c['RESET']}")

            if len(findings) > 25:
                out.append(f"{c['GRAY']}... and {len(findings) - 25} more findings omitted from console.{c['RESET']}")

        return "\n".join(out)

    @classmethod
    def format_markdown(cls, findings: List[SecurityFinding], thresholds: Dict[str, int], passed: bool) -> str:
        stats = cls.get_summary_stats(findings)
        status_badge = "🟢 **QUALITY GATE PASSED**" if passed else "🔴 **QUALITY GATE FAILED**"

        lines: List[str] = [
            "# 🛡️ DevSecOps Security Scan Summary",
            "",
            f"> **Status**: {status_badge}  ",
            f"> **Total Findings**: {stats['TOTAL']} (Critical: {stats['CRITICAL']}, High: {stats['HIGH']}, Medium: {stats['MEDIUM']}, Low: {stats['LOW']})",
            "",
            "## 📊 Security Metrics Overview",
            "",
            "| Security Category | Scanner | Detected Issues | Threshold Limit | Gate Status |",
            "| :--- | :--- | :---: | :---: | :---: |",
            f"| 🔑 **Secrets Detected** | Gitleaks | **{stats['SECRETS']}** | Max {thresholds.get('max_secrets', 0)} | {'✅ PASS' if stats['SECRETS'] <= thresholds.get('max_secrets', 0) else '❌ FAIL'} |",
            f"| 💥 **Critical CVEs** | Trivy / Semgrep | **{stats['CRITICAL']}** | Max {thresholds.get('max_critical', 0)} | {'✅ PASS' if stats['CRITICAL'] <= thresholds.get('max_critical', 0) else '❌ FAIL'} |",
            f"| ⚠️ **High Vulnerabilities** | Trivy / Semgrep | **{stats['HIGH']}** | Max {thresholds.get('max_high', 0)} | {'✅ PASS' if stats['HIGH'] <= thresholds.get('max_high', 0) else '❌ FAIL'} |",
            f"| 🔍 **Medium / Low Issues** | All Scanners | **{stats['MEDIUM'] + stats['LOW']}** | Info Only | ℹ️ INFO |",
            "",
            "## 📋 Detailed Findings List",
            "",
        ]

        if not findings:
            lines.append("🎉 **No security vulnerabilities or leaked secrets detected! Codebase is compliant.**")
        else:
            lines.extend([
                "| Category | Tool | Severity | Rule / Vulnerability | File & Line | Remediation |",
                "| :--- | :--- | :---: | :--- | :--- | :--- |",
            ])
            for f in findings:
                sev_icon = "🔴 CRITICAL" if f.normalized_severity == "CRITICAL" else ("🟠 HIGH" if f.normalized_severity == "HIGH" else "🟡 " + f.normalized_severity)
                loc = f"`{f.file_path}:{f.line_number}`"
                rule_display = f"**{f.rule_id}**"
                rem_display = f.remediation.replace("|", "/") if f.remediation else "Follow security guidelines."
                lines.append(
                    f"| {f.category} | `{f.tool}` | {sev_icon} | {rule_display} | {loc} | {rem_display} |"
                )

        lines.append("")
        lines.append("---")
        lines.append("*Generated automatically by DevSecOps Security Report Aggregator.*")
        return "\n".join(lines)


def evaluate_gate(findings: List[SecurityFinding], thresholds: Dict[str, int]) -> Tuple[bool, List[str]]:
    """Evaluates findings against Quality Gate thresholds and returns (passed, reasons)."""
    stats = ReportFormatter.get_summary_stats(findings)
    failures: List[str] = []

    if stats["CRITICAL"] > thresholds.get("max_critical", 0):
        failures.append(
            f"Critical vulnerabilities count ({stats['CRITICAL']}) exceeds allowed threshold ({thresholds.get('max_critical', 0)})."
        )

    if stats["HIGH"] > thresholds.get("max_high", 0):
        failures.append(
            f"High vulnerabilities count ({stats['HIGH']}) exceeds allowed threshold ({thresholds.get('max_high', 0)})."
        )

    if stats["SECRETS"] > thresholds.get("max_secrets", 0):
        failures.append(
            f"Hardcoded secrets count ({stats['SECRETS']}) exceeds allowed threshold ({thresholds.get('max_secrets', 0)})."
        )

    passed = len(failures) == 0
    return passed, failures


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate Gitleaks, Semgrep, and Trivy security scans into SARIF & enforce quality gates."
    )
    parser.add_argument("--gitleaks", type=Path, help="Path to Gitleaks JSON report")
    parser.add_argument("--semgrep", type=Path, help="Path to Semgrep JSON report")
    parser.add_argument("--trivy-fs", type=Path, help="Path to Trivy Filesystem JSON report")
    parser.add_argument("--trivy-image", type=Path, help="Path to Trivy Container Image JSON report")
    parser.add_argument("--sarif-output", type=Path, help="Path to write consolidated SARIF v2.1.0 output")
    parser.add_argument("--markdown-output", type=Path, help="Path to write Markdown summary output")
    parser.add_argument("--max-critical", type=int, default=0, help="Maximum allowed CRITICAL findings before failure (default: 0)")
    parser.add_argument("--max-high", type=int, default=0, help="Maximum allowed HIGH findings before failure (default: 0)")
    parser.add_argument("--max-secrets", type=int, default=0, help="Maximum allowed hardcoded secrets before failure (default: 0)")
    parser.add_argument("--fail-on-breach", action="store_true", help="Exit with code 1 if quality gate threshold is breached")
    parser.add_argument("--quiet", action="store_true", help="Suppress terminal report output")

    args = parser.parse_args()

    findings: List[SecurityFinding] = []

    if args.gitleaks:
        findings.extend(ReportParser.parse_gitleaks(args.gitleaks))
    if args.semgrep:
        findings.extend(ReportParser.parse_semgrep(args.semgrep))
    if args.trivy_fs:
        findings.extend(ReportParser.parse_trivy(args.trivy_fs, "trivy-fs"))
    if args.trivy_image:
        findings.extend(ReportParser.parse_trivy(args.trivy_image, "trivy-image"))

    thresholds = {
        "max_critical": args.max_critical,
        "max_high": args.max_high,
        "max_secrets": args.max_secrets,
    }

    passed, failure_reasons = evaluate_gate(findings, thresholds)

    # Output Terminal Summary
    if not args.quiet:
        print(ReportFormatter.format_terminal(findings, thresholds))
        if passed:
            print("\n\033[1;32m✅ QUALITY GATE PASSED: All metrics meet security policy requirements.\033[0m\n")
        else:
            print("\n\033[1;31m❌ QUALITY GATE FAILED: Policy threshold breaches detected:\033[0m")
            for r in failure_reasons:
                print(f"  \033[1;31m✖ {r}\033[0m")
            print()

    # Output Markdown
    if args.markdown_output:
        args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        md_content = ReportFormatter.format_markdown(findings, thresholds, passed)
        with open(args.markdown_output, "w", encoding="utf-8") as f:
            f.write(md_content)
        if not args.quiet:
            print(f"📝 Markdown summary generated: {args.markdown_output}")

    # Output SARIF
    if args.sarif_output:
        args.sarif_output.parent.mkdir(parents=True, exist_ok=True)
        sarif_data = SarifGenerator.findings_to_sarif(findings)
        with open(args.sarif_output, "w", encoding="utf-8") as f:
            json.dump(sarif_data, f, indent=2)
        if not args.quiet:
            print(f"📑 OASIS SARIF v2.1.0 generated: {args.sarif_output}")

    if args.fail_on_breach and not passed:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
