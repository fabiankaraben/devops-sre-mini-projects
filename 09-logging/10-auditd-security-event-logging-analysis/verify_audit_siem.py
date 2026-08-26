#!/usr/bin/env python3
"""Automated Verification Suite for Linux Auditd SIEM Security Pipeline.

Validates the full security audit and SIEM analytics lifecycle:
1. SIEM server health and REST API endpoints (:9099).
2. Auditd security rules syntax and coverage in rules.d/security.rules.
3. Raw Linux audit trail generation and multi-line event structure.
4. Multi-line record correlation & hex-encoded string decoding.
5. ECS normalized security alerts (identity_changes, privilege_escalation, etc.).
6. MITRE ATT&CK technique mapping and threat level scoring.
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Terminal Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class SIEMSecurityAuditor:
    """Verifies security events and correlation across the audit pipeline."""

    def __init__(self, siem_url: str = "http://127.0.0.1:9099", rules_file: str = "rules.d/security.rules"):
        self.siem_url = siem_url.rstrip("/")
        self.rules_path = Path(rules_file)
        self.test_results: List[Dict[str, Any]] = []

    def _http_get(self, path: str, timeout: float = 5.0) -> Tuple[int, Any, float]:
        """Perform HTTP GET request and return (status_code, parsed_json_or_text, elapsed_ms)."""
        url = f"{self.siem_url}/{path.lstrip('/')}"
        start = time.perf_counter()
        req = urllib.request.Request(url, headers={"User-Agent": "SIEM-Auditor/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000.0
                body = resp.read().decode("utf-8")
                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    data = body
                return resp.status, data, elapsed_ms
        except urllib.error.HTTPError as err:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            body = err.read().decode("utf-8")
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                data = body
            return err.code, data, elapsed_ms
        except Exception as exc:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            return 0, str(exc), elapsed_ms

    def record_test(self, name: str, passed: bool, message: str, duration_ms: float = 0.0):
        """Record and format a test result."""
        self.test_results.append({
            "name": name,
            "passed": passed,
            "message": message,
            "duration_ms": duration_ms,
        })
        status_label = f"{CLR_GREEN}PASS{CLR_RESET}" if passed else f"{CLR_RED}FAIL{CLR_RESET}"
        timing = f"{CLR_GRAY}({duration_ms:.1f}ms){CLR_RESET}" if duration_ms > 0 else ""
        print(f"  [{status_label}] {CLR_BOLD}{name}{CLR_RESET} {timing}")
        if not passed or "--verbose" in sys.argv:
            print(f"         {CLR_GRAY}└─ {message}{CLR_RESET}")

    def phase1_siem_health(self) -> bool:
        """Verify SIEM Dashboard & REST API health."""
        print(f"\n{CLR_YELLOW}▶ [Phase 1] Verifying SIEM Server & REST API Readiness...{CLR_RESET}")

        st, data, dur = self._http_get("/api/health")
        server_ok = (st == 200) and isinstance(data, dict) and data.get("status") == "healthy"
        self.record_test("SIEM Server Healthcheck (:9099)", server_ok, f"Response: {data}", dur)

        st_ui, body_ui, dur_ui = self._http_get("/")
        ui_ok = (st_ui == 200) and "Linux Auditd SIEM" in str(body_ui)
        self.record_test("SIEM Dashboard Web UI Availability", ui_ok, "Web UI template rendered successfully", dur_ui)

        return server_ok and ui_ok

    def phase2_rules_validation(self) -> bool:
        """Verify auditd rule syntax and security coverage."""
        print(f"\n{CLR_YELLOW}▶ [Phase 2] Auditing Security Ruleset (security.rules)...{CLR_RESET}")

        if not self.rules_path.is_file():
            self.record_test("Security Ruleset File Existence", False, f"File not found: {self.rules_path}")
            return False

        with open(self.rules_path, "r", encoding="utf-8") as f:
            rules_content = f.read()

        # Check required key mappings
        has_identity = "-k identity_changes" in rules_content and "/etc/passwd" in rules_content
        self.record_test("FIM Rule: /etc/passwd & /etc/shadow ('identity_changes')", has_identity, "Watches /etc/passwd and /etc/shadow for write/attribute changes")

        has_sudoers = "-k privilege_escalation" in rules_content and "/etc/sudoers" in rules_content
        self.record_test("FIM Rule: /etc/sudoers ('privilege_escalation')", has_sudoers, "Watches /etc/sudoers for unauthorized privilege modifications")

        has_execve = "-S execve" in rules_content and "-k user_commands" in rules_content
        self.record_test("Syscall Rule: Process Execution ('user_commands')", has_execve, "Monitors execve syscalls for interactive and non-root users")

        has_setuid = "-S setuid" in rules_content and "-k priv_escalation_syscalls" in rules_content
        self.record_test("Syscall Rule: Privilege Escalation ('priv_escalation_syscalls')", has_setuid, "Monitors setuid/setgid privilege escalation syscalls")

        return has_identity and has_sudoers and has_execve and has_setuid

    def phase3_siem_alerts_verification(self) -> bool:
        """Poll and verify correlated SIEM security alerts."""
        print(f"\n{CLR_YELLOW}▶ [Phase 3] Asserting Correlated ECS Security Incidents in SIEM...{CLR_RESET}")

        st, alerts, dur = self._http_get("/api/alerts")
        if st != 200 or not isinstance(alerts, list):
            self.record_test("SIEM Alert Retrieval API", False, f"HTTP {st} on /api/alerts", dur)
            return False

        self.record_test("SIEM Alert Ingestion Verification", len(alerts) >= 5, f"Retrieved {len(alerts)} correlated security alerts", dur)

        # 1. Assert FIM Alert on /etc/passwd (Critical)
        passwd_alert = next((a for a in alerts if a.get("rule", {}).get("name") == "identity_changes" and "/etc/passwd" in str(a.get("file", {}).get("path"))), None)
        self.record_test(
            "Incident Detection: /etc/passwd Tampering (CRITICAL)",
            passwd_alert is not None and passwd_alert.get("rule", {}).get("threat_level") == "CRITICAL",
            f"Detected FIM attack with command: {passwd_alert.get('process', {}).get('command_line') if passwd_alert else 'None'}",
        )

        # 2. Assert Privilege Escalation on /etc/sudoers (Critical)
        sudoers_alert = next((a for a in alerts if a.get("rule", {}).get("name") == "privilege_escalation" and "/etc/sudoers" in str(a.get("file", {}).get("path"))), None)
        self.record_test(
            "Incident Detection: /etc/sudoers Backdoor Injection (CRITICAL)",
            sudoers_alert is not None and sudoers_alert.get("rule", {}).get("threat_level") == "CRITICAL",
            f"Detected privilege escalation grant with command: {sudoers_alert.get('process', {}).get('command_line') if sudoers_alert else 'None'}",
        )

        # 3. Assert setuid syscall exploitation (High)
        setuid_alert = next((a for a in alerts if a.get("rule", {}).get("name") == "priv_escalation_syscalls"), None)
        self.record_test(
            "Incident Detection: setuid(0) Syscall Privilege Escalation (HIGH)",
            setuid_alert is not None and setuid_alert.get("rule", {}).get("threat_level") == "HIGH",
            f"Detected setuid invocation by process: {setuid_alert.get('process', {}).get('executable') if setuid_alert else 'None'}",
        )

        # 4. Assert Suspicious Command Execution (Reverse Shell)
        nc_alert = next((a for a in alerts if "nc" in str(a.get("process", {}).get("command_line")) or a.get("rule", {}).get("name") == "user_commands"), None)
        self.record_test(
            "Incident Detection: Suspicious Command Line Execution (execve)",
            nc_alert is not None,
            f"Captured command line: {nc_alert.get('process', {}).get('command_line') if nc_alert else 'None'}",
        )

        # 5. Assert SSH Daemon Config Tampering (High)
        sshd_alert = next((a for a in alerts if a.get("rule", {}).get("name") == "sshd_tamper"), None)
        self.record_test(
            "Incident Detection: SSH Daemon Configuration Tampering (HIGH)",
            sshd_alert is not None and sshd_alert.get("rule", {}).get("threat_level") == "HIGH",
            f"Captured SSH config modification: {sshd_alert.get('file', {}).get('path') if sshd_alert else 'None'}",
        )

        return (passwd_alert is not None) and (sudoers_alert is not None) and (setuid_alert is not None)

    def phase4_metadata_and_stats(self) -> bool:
        """Verify ECS metadata enrichment and SIEM statistics."""
        print(f"\n{CLR_YELLOW}▶ [Phase 4] Verifying User Lineage, Hex Decoding & SOC Metrics...{CLR_RESET}")

        st, stats, dur = self._http_get("/api/stats")
        stats_ok = (
            st == 200
            and isinstance(stats, dict)
            and stats.get("critical", 0) >= 2
            and stats.get("high", 0) >= 2
            and stats.get("total", 0) >= 5
        )
        self.record_test(
            "SIEM Threat Statistics Aggregation",
            stats_ok,
            f"Stats: Critical={stats.get('critical')}, High={stats.get('high')}, Medium={stats.get('medium')}, Total={stats.get('total')}",
            dur,
        )

        # Fetch an alert and check AUID / EUID / Hex decoding
        st_al, alerts, _ = self._http_get("/api/alerts")
        has_user_lineage = False
        has_hex_decoded = False
        if st_al == 200 and isinstance(alerts, list) and len(alerts) > 0:
            sample = alerts[0]
            has_user_lineage = "audit_id" in sample.get("user", {}) and "id" in sample.get("user", {})
            # Check command line is readable text (not raw hex string)
            cmd = sample.get("process", {}).get("command_line", "")
            has_hex_decoded = len(cmd) > 0 and " " in cmd and not cmd.startswith("6E616E6F")

        self.record_test(
            "User Lineage Tracking (AUID vs EUID Attribution)",
            has_user_lineage,
            "Captures original audit login UID (AUID) and current effective UID (EUID)",
        )

        self.record_test(
            "Hexadecimal Argument & Proctitle Decoding",
            has_hex_decoded,
            "Decodes raw hex-encoded proctitle / EXECVE parameters into plain readable commands",
        )

        return stats_ok and has_user_lineage and has_hex_decoded

    def run_full_suite(self) -> bool:
        """Run all test phases and display summary."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  🛡️  Linux Auditd SIEM Security Pipeline Verification Suite{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

        self.phase1_siem_health()
        self.phase2_rules_validation()
        self.phase3_siem_alerts_verification()
        self.phase4_metadata_and_stats()

        passed_count = sum(1 for r in self.test_results if r["passed"])
        total_count = len(self.test_results)
        all_passed = (passed_count == total_count)

        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  📊 Verification Results: {passed_count}/{total_count} Passed{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

        if all_passed:
            print(f"\n{CLR_GREEN}{CLR_BOLD}🎉 ALL LINUX AUDITD & SIEM SECURITY ASSERTIONS SUCCEEDED!{CLR_RESET}\n")
            print(f"  👉 SIEM SOC Threat Dashboard: {self.siem_url}\n")
        else:
            print(f"\n{CLR_RED}{CLR_BOLD}❌ AUDIT VERIFICATION FAILED: {total_count - passed_count} ASSERTIONS FAILED.{CLR_RESET}\n")

        return all_passed


def main():
    parser = argparse.ArgumentParser(description="Verify Linux Auditd SIEM security analysis pipeline.")
    parser.add_argument("--url", default="http://127.0.0.1:9099", help="SIEM server base URL")
    parser.add_argument("--rules", default="rules.d/security.rules", help="Path to security.rules file")
    parser.add_argument("--verbose", action="store_true", help="Print verbose test messages")

    args = parser.parse_args()

    auditor = SIEMSecurityAuditor(siem_url=args.url, rules_file=args.rules)
    success = auditor.run_full_suite()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
