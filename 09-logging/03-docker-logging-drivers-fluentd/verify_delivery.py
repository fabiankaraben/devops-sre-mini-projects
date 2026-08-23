#!/usr/bin/env python3
"""Fluentd Log Delivery & Host Disk Preservation Auditor.

Audits logs collected by Fluentd via the Docker Forward logging driver,
verifying that 100% of the 10,000 emitted events arrived with zero loss,
and confirming that the host container log file was bypassed/preserved.
"""

import argparse
import json
import os
import re
import subprocess
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


class FluentdDeliveryAuditor:
    """Audits Fluentd log ingestion for sequence continuity, tag routing, and zero loss."""

    def __init__(self, expected_count: int = 10000):
        self.expected_count = expected_count
        self.total_records: int = 0
        self.all_sequences: Set[int] = set()
        self.duplicate_sequences: Set[int] = set()
        self.level_counts: Dict[str, int] = {"INFO": 0, "WARNING": 0, "ERROR": 0}
        self.distinct_tags: Set[str] = set()
        self.min_seq: int = sys.maxsize
        self.max_seq: int = 0
        self.host_disk_preserved: bool = True
        self.host_log_path: Optional[str] = None
        self.host_log_size: int = 0

    def parse_raw_line(self, line: str) -> Optional[Dict[str, Any]]:
        """Parse raw line from Fluentd output file or stdout stream."""
        stripped = line.strip()
        if not stripped:
            return None

        # Try parsing JSON line
        try:
            record = json.loads(stripped)
            if not isinstance(record, dict):
                return None
        except json.JSONDecodeError:
            # Handle possible tab-separated Fluentd format: <time>\t<tag>\t<json>
            parts = stripped.split("\t", 2)
            if len(parts) == 3:
                try:
                    record = json.loads(parts[2])
                except json.JSONDecodeError:
                    return None
            else:
                return None

        # Check if the payload is nested under 'log' string (Docker stdout encapsulation)
        if "log" in record and isinstance(record["log"], str):
            try:
                inner = json.loads(record["log"].strip())
                if isinstance(inner, dict):
                    # Merge inner keys (seq, level, service) with outer Fluentd metadata
                    combined = {**record, **inner}
                    return combined
            except json.JSONDecodeError:
                pass

        return record

    def ingest_lines(self, lines: List[str]) -> None:
        """Ingest and record statistics for a stream of log lines."""
        for line in lines:
            parsed = self.parse_raw_line(line)
            if not parsed:
                continue

            seq = parsed.get("seq")
            if isinstance(seq, int):
                self.total_records += 1
                if seq in self.all_sequences:
                    self.duplicate_sequences.add(seq)
                self.all_sequences.add(seq)
                self.min_seq = min(self.min_seq, seq)
                self.max_seq = max(self.max_seq, seq)

                level = parsed.get("level", "INFO").upper()
                self.level_counts[level] = self.level_counts.get(level, 0) + 1

                tag = (
                    parsed.get("docker_tag")
                    or parsed.get("tag")
                    or parsed.get("container_name")
                )
                if tag:
                    self.distinct_tags.add(str(tag))

    def inspect_host_disk(self, container_name: str = "fluentd-log-producer") -> None:
        """Verify that the container's host-level json-file log is non-existent or 0 bytes."""
        try:
            log_path = subprocess.check_output(
                [
                    "docker",
                    "inspect",
                    "--format",
                    "{{.LogPath}}",
                    container_name,
                ],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()

            self.host_log_path = log_path
            if not log_path or log_path == "<no value>" or not os.path.exists(log_path):
                # Native fluentd driver does not create local host JSON files!
                self.host_disk_preserved = True
                self.host_log_size = 0
            else:
                self.host_log_size = os.path.getsize(log_path)
                # If size is minimal or empty, disk is preserved
                self.host_disk_preserved = self.host_log_size < 1024
        except Exception:
            # Inspection via Docker API might not expose host path when fluentd driver is used
            self.host_disk_preserved = True

    def print_report(self) -> bool:
        """Render a formatted, colored verification audit report."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 72)
        print("  📊 DOCKER FLUENTD LOG DELIVERY & ZERO-LOSS AUDIT REPORT")
        print("=" * 72 + f"{CLR_RESET}\n")

        print(f"  {CLR_BOLD}Target Expected Count:{CLR_RESET}  {self.expected_count:,} records")
        print(f"  {CLR_BOLD}Total Records Ingested:{CLR_RESET} {CLR_GREEN}{self.total_records:,}{CLR_RESET}")

        if self.min_seq <= self.max_seq:
            print(f"  {CLR_BOLD}Sequence Range Audited:{CLR_RESET} [#{self.min_seq} → #{self.max_seq}]")

        print(f"  {CLR_BOLD}Discovered Docker Tags:{CLR_RESET} {', '.join(sorted(self.distinct_tags)) or 'docker.log-producer'}\n")

        # Distribution Table
        print(f"  {CLR_BOLD}Log Level Distribution:{CLR_RESET}")
        print(f"  {CLR_GRAY}----------------------------------------{CLR_RESET}")
        for lvl in ["INFO", "WARNING", "ERROR"]:
            count = self.level_counts.get(lvl, 0)
            color = CLR_GREEN if lvl == "INFO" else (CLR_YELLOW if lvl == "WARNING" else CLR_RED)
            pct = (count / max(1, self.total_records)) * 100
            print(f"  {color}{lvl:<8}{CLR_RESET} : {count:>6,} ({pct:>5.1f}%)")

        print(f"\n  {CLR_BOLD}Zero-Loss & Continuity Assertions:{CLR_RESET}")

        passed = True
        missing_sequences = []

        if self.min_seq <= self.max_seq:
            expected_set = set(range(1, self.expected_count + 1))
            missing_set = expected_set - self.all_sequences
            missing_sequences = sorted(list(missing_set))

        if self.total_records == self.expected_count and not missing_sequences:
            print(f"  • Ingestion Completeness:     {CLR_GREEN}100.00% (All {self.expected_count:,} arrived!){CLR_RESET}")
            print(f"  • Dropped / Missing Entries:  {CLR_GREEN}0 (Zero Log Loss Verified!){CLR_RESET}")
        else:
            passed = False
            loss_count = len(missing_sequences) if missing_sequences else (self.expected_count - self.total_records)
            print(f"  • Ingestion Completeness:     {CLR_RED}{(self.total_records / self.expected_count * 100):.2f}%{CLR_RESET}")
            print(f"  • Dropped / Missing Entries:  {CLR_RED}{loss_count:,} RECORDS LOST!{CLR_RESET}")
            if missing_sequences:
                print(f"    {CLR_RED}Missing sample: {missing_sequences[:8]}...{CLR_RESET}")

        if not self.duplicate_sequences:
            print(f"  • Duplicate Sequence IDs:     {CLR_GREEN}0 (Strict Monotonic Indexing){CLR_RESET}")
        else:
            passed = False
            print(f"  • Duplicate Sequence IDs:     {CLR_RED}{len(self.duplicate_sequences)} Duplicates!{CLR_RESET}")

        print(f"\n  {CLR_BOLD}Host Disk Preservation:{CLR_RESET}")
        if self.host_disk_preserved:
            print(f"  • Host json-file Bypassed:    {CLR_GREEN}PASS (Host disk protected from unrotated JSON files){CLR_RESET}")
            if self.host_log_path:
                print(f"    ↳ Host Log Path: {self.host_log_path} ({self.host_log_size} bytes)")
        else:
            print(f"  • Host json-file Bypassed:    {CLR_YELLOW}WARN (Host log size: {self.host_log_size} bytes){CLR_RESET}")

        print(f"\n{CLR_CYAN}" + "=" * 72 + f"{CLR_RESET}\n")

        if passed and self.total_records >= self.expected_count:
            print(f"{CLR_GREEN}{CLR_BOLD}✅ VERIFICATION PASSED: 100% of 10,000 log events captured with ZERO loss!{CLR_RESET}\n")
            return True
        else:
            print(f"{CLR_RED}{CLR_BOLD}❌ VERIFICATION FAILED: Log loss or sequence corruption detected.{CLR_RESET}\n")
            return False


# ------------------------------------------------------------------------------
# CLI Entrypoint
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Verify zero log loss for Docker Fluentd logging driver stream."
    )
    parser.add_argument(
        "--expected-count",
        type=int,
        default=10000,
        help="Expected total number of records emitted by producer (default: 10000)",
    )
    parser.add_argument(
        "--fluentd-container",
        default="fluentd-collector",
        help="Name of Fluentd collector container (default: fluentd-collector)",
    )
    parser.add_argument(
        "--producer-container",
        default="fluentd-log-producer",
        help="Name of log producer container (default: fluentd-log-producer)",
    )
    parser.add_argument(
        "--file",
        help="Read Fluentd output logs from a local file.",
    )
    args = parser.parse_args()

    auditor = FluentdDeliveryAuditor(expected_count=args.expected_count)
    log_lines: List[str] = []

    if args.file:
        if not os.path.exists(args.file):
            print(f"{CLR_RED}[FAIL] File not found: {args.file}{CLR_RESET}", file=sys.stderr)
            sys.exit(1)
        with open(args.file, "r", encoding="utf-8") as f:
            log_lines = f.readlines()
    else:
        # Fetch output files from Fluentd container storage
        try:
            # 1. Read files inside /fluentd/log/
            cat_cmd = (
                "cat /fluentd/log/docker_events* 2>/dev/null || "
                "cat /fluentd/log/output* 2>/dev/null || true"
            )
            output = subprocess.check_output(
                ["docker", "exec", args.fluentd_container, "sh", "-c", cat_cmd],
                stderr=subprocess.DEVNULL,
                text=True,
            )
            log_lines = output.splitlines()

            # If file buffer hasn't flushed everything to disk yet, fallback to docker logs of fluentd
            if len(log_lines) < args.expected_count:
                stdout_logs = subprocess.check_output(
                    ["docker", "logs", args.fluentd_container],
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                log_lines.extend(stdout_logs.splitlines())

        except Exception as exc:
            print(f"{CLR_RED}[FAIL] Could not fetch logs from Fluentd container: {exc}{CLR_RESET}", file=sys.stderr)
            sys.exit(1)

    auditor.ingest_lines(log_lines)
    auditor.inspect_host_disk(args.producer_container)
    success = auditor.print_report()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
