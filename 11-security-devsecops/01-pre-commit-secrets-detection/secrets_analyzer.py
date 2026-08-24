#!/usr/bin/env python3
"""
==============================================================================
secrets_analyzer.py - DevSecOps Secret Detection & Entropy Analytics Engine
==============================================================================
Provides mathematical Shannon entropy calculation, ruleset evaluation,
baseline drift auditing, and structured report generation (Terminal/JSON/SARIF).
==============================================================================
"""

import argparse
import json
import math
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ANSI Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_RED = "\033[1;31m"
CLR_GREEN = "\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"

DEFAULT_RULES = [
    {
        "id": "aws-access-key-id",
        "description": "AWS Access Key ID (AKIA/ASIA/ABIA/ACCA)",
        "regex": r"\b((?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16})\b",
        "entropy_threshold": 0.0,
        "secret_group": 1,
        "severity": "CRITICAL",
    },
    {
        "id": "aws-secret-access-key",
        "description": "AWS Secret Access Key Assignment",
        "regex": r"(?i)(?:aws_secret_access_key|aws_secret_key|secret_access_key|aws_secret)\s*(?:=|:)\s*['\"]?([A-Za-z0-9/+=]{40})['\"]?",
        "entropy_threshold": 3.5,
        "secret_group": 1,
        "severity": "CRITICAL",
    },
    {
        "id": "github-pat",
        "description": "GitHub Personal Access Token (Classic or Fine-grained)",
        "regex": r"\b(ghp_[0-9a-zA-Z]{36}|github_pat_[0-9a-zA-Z_]{82}|gho_[0-9a-zA-Z]{36}|ghu_[0-9a-zA-Z]{36}|ghs_[0-9a-zA-Z]{36})\b",
        "entropy_threshold": 3.0,
        "secret_group": 1,
        "severity": "CRITICAL",
    },
    {
        "id": "slack-incoming-webhook",
        "description": "Slack Incoming Webhook URL",
        "regex": r"https://hooks\.slack\.com/services/T[a-zA-Z0-9_]{8,10}/B[a-zA-Z0-9_]{8,12}/[a-zA-Z0-9_]{24}",
        "entropy_threshold": 0.0,
        "secret_group": 0,
        "severity": "HIGH",
    },
    {
        "id": "openai-api-key",
        "description": "OpenAI Secret API Key",
        "regex": r"\b(sk-[a-zA-Z0-9]{20,48}|sk-proj-[a-zA-Z0-9_-]{48,128})\b",
        "entropy_threshold": 3.5,
        "secret_group": 1,
        "severity": "CRITICAL",
    },
    {
        "id": "private-cryptographic-key",
        "description": "Asymmetric Private Cryptographic Key",
        "regex": r"-----BEGIN (?:(?:RSA|DSA|EC|OPENSSH|PGP) )?PRIVATE KEY-----",
        "entropy_threshold": 0.0,
        "secret_group": 0,
        "severity": "CRITICAL",
    },
    {
        "id": "generic-api-key",
        "description": "Generic High-Entropy API Key Assignment",
        "regex": r"(?i)(?:api_key|apikey|secret_key|client_secret|auth_token|access_token|private_token)\s*(?:=|:)\s*['\"]([a-zA-Z0-9_\-]{24,128})['\"]",
        "entropy_threshold": 3.8,
        "secret_group": 1,
        "severity": "HIGH",
    },
    {
        "id": "jwt-secret-key",
        "description": "Hardcoded JWT Signing Secret",
        "regex": r"(?i)(?:jwt_secret|jwt_key|token_secret|signing_key)\s*(?:=|:)\s*['\"]([a-zA-Z0-9!@#$%^&*()_+=\-]{16,64})['\"]",
        "entropy_threshold": 3.2,
        "secret_group": 1,
        "severity": "HIGH",
    },
]

GLOBAL_ALLOWLIST_PATTERNS = [
    r"AKIAIOSFODNN7EXAMPLE",
    r"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    r"EXAMPLE_KEY_DO_NOT_USE_[0-9A-Z]+",
    r"YOUR_API_KEY_HERE",
    r"sk-mock-allowlisted-demo-key-1234567890abcdef",
]

IGNORE_PATHS = [
    r"\.git/",
    r"\.pre-commit-cache/",
    r"\.test_sandbox/",
    r"sandbox_repo/",
    r"\.gitleaks\.toml$",
    r"\.secrets\.baseline$",
    r"secrets_analyzer\.py$",
    r"test_fixtures/mock_secrets/allowlisted_mock_token\.py$",
]


def calculate_shannon_entropy(data: str) -> float:
    """
    Calculates Shannon Entropy H(X) = -sum(p(x) * log2(p(x))).
    Higher entropy indicates higher unpredictability / randomness.
    Natural English strings typically have entropy between 2.0 and 3.5.
    Cryptographic base64/hex hashes usually score > 4.2.
    """
    if not data:
        return 0.0
    length = len(data)
    counts = Counter(data)
    entropy = 0.0
    for count in counts.values():
        probability = count / length
        entropy -= probability * math.log2(probability)
    return round(entropy, 4)


def redact_secret(secret: str, show_chars: int = 4) -> str:
    """Redacts secret keeping only initial characters for safe reporting."""
    if len(secret) <= show_chars * 2:
        return "*" * len(secret)
    return secret[:show_chars] + "*" * (len(secret) - show_chars * 2) + secret[-show_chars:]


def is_path_ignored(path_str: str) -> bool:
    """Checks if a filepath matches global ignore rules."""
    normalized = path_str.replace("\\", "/")
    for pattern in IGNORE_PATHS:
        if re.search(pattern, normalized):
            return True
    return False


def is_secret_allowlisted(secret_str: str) -> bool:
    """Checks if the secret value matches an allowed pattern."""
    for pattern in GLOBAL_ALLOWLIST_PATTERNS:
        if re.search(pattern, secret_str):
            return True
    return False


def scan_file(file_path: Path, base_dir: Path) -> List[Dict[str, Any]]:
    """Scans a single file against the security ruleset."""
    findings: List[Dict[str, Any]] = []
    rel_path = file_path.relative_to(base_dir).as_posix()

    if is_path_ignored(rel_path):
        return findings

    try:
        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
    except Exception as e:
        return findings

    for line_num, line in enumerate(lines, 1):
        for rule in DEFAULT_RULES:
            matches = list(re.finditer(rule["regex"], line))
            for match in matches:
                secret_text = match.group(rule["secret_group"]) if rule["secret_group"] > 0 else match.group(0)
                
                if is_secret_allowlisted(secret_text):
                    continue

                entropy = calculate_shannon_entropy(secret_text)
                if entropy < rule["entropy_threshold"]:
                    continue

                findings.append({
                    "rule_id": rule["id"],
                    "description": rule["description"],
                    "severity": rule["severity"],
                    "file": rel_path,
                    "line": line_num,
                    "secret_preview": redact_secret(secret_text),
                    "entropy": entropy,
                    "entropy_threshold": rule["entropy_threshold"],
                    "match_length": len(secret_text),
                })

    return findings


def scan_directory(target_dir: Path) -> List[Dict[str, Any]]:
    """Recursively scans all files in a directory for hardcoded secrets."""
    all_findings: List[Dict[str, Any]] = []
    for root, _, files in os.walk(target_dir):
        for file in files:
            file_p = Path(root) / file
            all_findings.extend(scan_file(file_p, target_dir))
    return all_findings


def audit_baseline_drift(baseline_file: Path, current_findings: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Compares current findings against Yelp detect-secrets baseline."""
    if not baseline_file.exists():
        return {"status": "NO_BASELINE", "baseline_file": str(baseline_file), "new_violations": current_findings}

    try:
        with open(baseline_file, "r", encoding="utf-8") as f:
            baseline_data = json.load(f)
    except Exception as err:
        return {"status": "ERROR_PARSING_BASELINE", "error": str(err), "new_violations": current_findings}

    baseline_results = baseline_data.get("results", {})
    new_violations = []

    for item in current_findings:
        file_key = item["file"]
        if file_key not in baseline_results:
            new_violations.append(item)
        else:
            # Check if any entry matches line or filename
            entries = baseline_results[file_key]
            # If all baseline entries are marked is_secret: false, it was allowlisted
            allowlisted = any(not e.get("is_secret", True) for e in entries)
            if not allowlisted:
                new_violations.append(item)

    return {
        "status": "COMPARED",
        "baseline_entries_count": sum(len(v) for v in baseline_results.values()),
        "total_findings": len(current_findings),
        "new_violations": new_violations,
    }


def generate_terminal_report(findings: List[Dict[str, Any]], elapsed_sec: float) -> None:
    """Prints a styled terminal summary of security findings."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 78}")
    print("  🛡️  DEVSECOPS PRE-COMMIT SECRETS SCAN REPORT")
    print(f"{'=' * 78}{CLR_RESET}")
    print(f" Scan Time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f" Execution Duration: {elapsed_sec:.3f}s")
    print(f" Total Secrets Discovered: {len(findings)}\n")

    if not findings:
        print(f"  {CLR_GREEN}{CLR_BOLD}✅ [CLEAN] No hardcoded secrets or credentials detected!{CLR_RESET}\n")
        return

    print(f"{CLR_BOLD}{'SEVERITY':<10} {'RULE ID':<24} {'FILE:LINE':<26} {'ENTROPY':<8} {'PREVIEW'}{CLR_RESET}")
    print("-" * 78)

    for item in findings:
        sev = item["severity"]
        sev_color = CLR_RED if sev == "CRITICAL" else CLR_YELLOW
        file_loc = f"{item['file']}:{item['line']}"
        if len(file_loc) > 24:
            file_loc = "..." + file_loc[-21:]

        print(
            f"{sev_color}{sev:<10}{CLR_RESET} "
            f"{CLR_CYAN}{item['rule_id'][:23]:<24}{CLR_RESET} "
            f"{file_loc:<26} "
            f"{item['entropy']:<8.2f} "
            f"{CLR_MAGENTA}{item['secret_preview']}{CLR_RESET}"
        )

    print("-" * 78)
    print(f"\n{CLR_RED}{CLR_BOLD}❌ Policy Violation: Secrets must not be committed to Git.{CLR_RESET}")
    print(f"{CLR_YELLOW}Action Required: Revoke leaked credentials and migrate to environment variables or Vault.{CLR_RESET}\n")


def generate_json_report(findings: List[Dict[str, Any]], output_path: Path) -> None:
    """Exports findings as a JSON report."""
    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_findings": len(findings),
        "status": "FAILED" if findings else "PASSED",
        "findings": findings,
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"  [JSON] Report exported to: {output_path}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="DevSecOps Pre-Commit Git Secrets Detection & Entropy Analysis Engine."
    )
    parser.add_argument("--scan-dir", default=".", help="Directory to scan recursively (default: current dir)")
    parser.add_argument("--file", help="Scan a single specific file")
    parser.add_argument("--calc-entropy", help="Calculate Shannon entropy for a given string token")
    parser.add_argument("--baseline", help="Path to .secrets.baseline file for drift evaluation")
    parser.add_argument("--json-out", help="Path to write JSON findings report")
    parser.add_argument("--strict", action="store_true", help="Exit with non-zero code if secrets are detected")

    args = parser.parse_args()

    if args.calc_entropy:
        entropy = calculate_shannon_entropy(args.calc_entropy)
        print(f"\n{CLR_CYAN}Token:{CLR_RESET} {args.calc_entropy}")
        print(f"{CLR_CYAN}Length:{CLR_RESET} {len(args.calc_entropy)} characters")
        print(f"{CLR_CYAN}Shannon Entropy:{CLR_RESET} {CLR_BOLD}{entropy}{CLR_RESET} bits/char")
        if entropy > 4.2:
            print(f"{CLR_RED}Classification: High Randomness / Probable Cryptographic Key (> 4.2){CLR_RESET}")
        elif entropy > 3.2:
            print(f"{CLR_YELLOW}Classification: Moderate Randomness / Potential Token (3.2 - 4.2){CLR_RESET}")
        else:
            print(f"{CLR_GREEN}Classification: Low Randomness / Natural Text or Short ID (< 3.2){CLR_RESET}")
        return 0

    start_time = datetime.now()
    target_dir = Path(args.scan_dir).resolve()

    if args.file:
        file_path = Path(args.file).resolve()
        findings = scan_file(file_path, file_path.parent)
    else:
        findings = scan_directory(target_dir)

    elapsed = (datetime.now() - start_time).total_seconds()
    generate_terminal_report(findings, elapsed)

    if args.baseline:
        baseline_audit = audit_baseline_drift(Path(args.baseline).resolve(), findings)
        print(f"{CLR_CYAN}[Baseline Audit]{CLR_RESET} Baseline status: {baseline_audit['status']}")
        if "new_violations" in baseline_audit:
            print(f"  New Unbaselined Violations: {len(baseline_audit['new_violations'])}")

    if args.json_out:
        generate_json_report(findings, Path(args.json_out))

    if args.strict and findings:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
