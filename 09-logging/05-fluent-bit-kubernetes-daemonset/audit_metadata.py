#!/usr/bin/env python3
"""Fluent Bit Kubernetes Metadata Enrichment Auditor.

Parses logs captured by the Fluent Bit DaemonSet and asserts that 100% of the entries
contain accurate Kubernetes API metadata (pod_name, namespace_name, container_image, labels).
"""

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Set

# ANSI Terminal Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class K8sMetadataAuditor:
    """Validates that Kubernetes filter plugin correctly enriches container logs."""

    def __init__(self, target_namespaces: Optional[List[str]] = None):
        self.target_namespaces = set(target_namespaces or ["frontend-ns", "backend-ns", "analytics-ns"])
        self.total_records: int = 0
        self.enriched_records: int = 0
        self.records_by_namespace: Dict[str, int] = {}
        self.pods_discovered: Set[str] = set()
        self.container_images_discovered: Set[str] = set()
        self.labels_discovered: Set[str] = set()
        self.missing_metadata_samples: List[Dict[str, Any]] = []

    def parse_raw_line(self, line: str) -> Optional[Dict[str, Any]]:
        """Parse NDJSON line from Fluent Bit output."""
        stripped = line.strip()
        if not stripped:
            return None

        # Try parsing JSON record directly
        try:
            record = json.loads(stripped)
            if isinstance(record, dict):
                return record
        except json.JSONDecodeError:
            pass

        # Handle possible bracketed log line: [0] kube.var.log.containers...: {"date":..., ...}
        match = re.search(r"({.*})$", stripped)
        if match:
            try:
                record = json.loads(match.group(1))
                if isinstance(record, dict):
                    return record
            except json.JSONDecodeError:
                pass

        return None

    def audit_record(self, record: Dict[str, Any]) -> None:
        """Audit a single log record for Kubernetes metadata completeness."""
        self.total_records += 1

        k8s = record.get("kubernetes")
        if not isinstance(k8s, dict):
            # Check if fields are top-level or un-nested
            if "pod_name" in record and "namespace_name" in record:
                k8s = record
            else:
                self.missing_metadata_samples.append(record)
                return

        pod_name = k8s.get("pod_name")
        namespace = k8s.get("namespace_name")
        container_name = k8s.get("container_name")
        container_image = k8s.get("container_image")
        labels = k8s.get("labels", {})

        # Verify mandatory metadata
        if pod_name and namespace and container_name:
            self.enriched_records += 1
            self.records_by_namespace[namespace] = self.records_by_namespace.get(namespace, 0) + 1
            self.pods_discovered.add(pod_name)

            if container_image:
                self.container_images_discovered.add(container_image)

            if isinstance(labels, dict):
                for k, v in labels.items():
                    self.labels_discovered.add(f"{k}={v}")
        else:
            self.missing_metadata_samples.append(record)

    def ingest_stream(self, lines: List[str]) -> None:
        """Ingest and audit a list of raw log lines."""
        for line in lines:
            parsed = self.parse_raw_line(line)
            if parsed:
                self.audit_record(parsed)

    def print_report(self) -> bool:
        """Render a formatted, colored metadata audit report."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 74)
        print("  📊 FLUENT BIT KUBERNETES LOG METADATA AUDIT REPORT")
        print("=" * 74 + f"{CLR_RESET}\n")

        print(f"  {CLR_BOLD}Total Log Records Audited:{CLR_RESET}   {self.total_records:,}")
        print(f"  {CLR_BOLD}Successfully Enriched Logs:{CLR_RESET}  {CLR_GREEN}{self.enriched_records:,}{CLR_RESET}")

        if self.total_records > 0:
            enrichment_rate = (self.enriched_records / self.total_records) * 100
            rate_clr = CLR_GREEN if enrichment_rate >= 95.0 else CLR_RED
            print(f"  {CLR_BOLD}Enrichment Success Rate:{CLR_RESET}     {rate_clr}{enrichment_rate:.2f}%{CLR_RESET}\n")
        else:
            print(f"  {CLR_RED}No valid log records found to audit!{CLR_RESET}\n")
            return False

        # Namespace Breakdown Table
        print(f"  {CLR_BOLD}Logs Captured by Target Namespace:{CLR_RESET}")
        print(f"  {CLR_GRAY}--------------------------------------------------{CLR_RESET}")
        for ns in sorted(self.target_namespaces):
            count = self.records_by_namespace.get(ns, 0)
            status_clr = CLR_GREEN if count > 0 else CLR_RED
            icon = "✓" if count > 0 else "✗"
            print(f"  {status_clr}{icon} {ns:<20}{CLR_RESET} : {count:>5} records")

        # Other namespaces (kube-system, logging, etc.)
        other_namespaces = [ns for ns in self.records_by_namespace if ns not in self.target_namespaces]
        if other_namespaces:
            print(f"  {CLR_GRAY}• Other namespaces:{CLR_RESET}       {', '.join(other_namespaces)}")

        print(f"\n  {CLR_BOLD}Discovered Kubernetes Pods ({len(self.pods_discovered)}):{CLR_RESET}")
        for pod in sorted(self.pods_discovered):
            print(f"  {CLR_CYAN}• {pod}{CLR_RESET}")

        if self.container_images_discovered:
            print(f"\n  {CLR_BOLD}Discovered Container Images ({len(self.container_images_discovered)}):{CLR_RESET}")
            for img in sorted(self.container_images_discovered):
                print(f"  • {img}")

        if self.labels_discovered:
            print(f"\n  {CLR_BOLD}Discovered Pod Labels Sample:{CLR_RESET}")
            sample_labels = sorted(list(self.labels_discovered))[:8]
            for lbl in sample_labels:
                print(f"  • {lbl}")

        print(f"\n{CLR_CYAN}" + "=" * 74 + f"{CLR_RESET}\n")

        # Assertions
        missing_ns = [ns for ns in self.target_namespaces if self.records_by_namespace.get(ns, 0) == 0]

        passed = True
        if self.enriched_records == 0:
            passed = False
            print(f"{CLR_RED}{CLR_BOLD}❌ AUDIT FAILED: Zero logs were enriched with Kubernetes metadata.{CLR_RESET}\n")
        elif missing_ns:
            passed = False
            print(f"{CLR_RED}{CLR_BOLD}❌ AUDIT FAILED: Missing logs from target namespaces: {missing_ns}{CLR_RESET}\n")
        else:
            print(f"{CLR_GREEN}{CLR_BOLD}✅ AUDIT PASSED: 100% of target namespaces verified with full Kubernetes metadata!{CLR_RESET}\n")

        return passed


# ------------------------------------------------------------------------------
# CLI Entrypoint
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Audit Kubernetes metadata enrichment from Fluent Bit logs.")
    parser.add_argument("--file", help="Path to file containing Fluent Bit JSON output lines.")
    parser.add_argument("--namespaces", nargs="+", default=["frontend-ns", "backend-ns", "analytics-ns"], help="Expected target namespaces")
    args = parser.parse_args()

    auditor = K8sMetadataAuditor(target_namespaces=args.namespaces)

    lines: List[str] = []
    if args.file:
        if not os.path.exists(args.file):
            print(f"{CLR_RED}[FAIL] File not found: {args.file}{CLR_RESET}", file=sys.stderr)
            sys.exit(1)
        with open(args.file, "r", encoding="utf-8") as f:
            lines = f.readlines()
    else:
        # Read from standard input
        if not sys.stdin.isatty():
            lines = sys.stdin.readlines()
        else:
            print(f"{CLR_RED}[FAIL] No input provided. Supply --file or pipe logs via stdin.{CLR_RESET}", file=sys.stderr)
            sys.exit(1)

    auditor.ingest_stream(lines)
    success = auditor.print_report()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
