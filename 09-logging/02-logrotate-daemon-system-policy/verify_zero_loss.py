#!/usr/bin/env python3
"""Zero-Loss Log Verification & Sequence Continuity Auditor.

Inspects active log files and rotated/compressed gzip archives to verify that
100% of log entries were persisted with zero dropped lines and zero duplicates.
"""

import argparse
import gzip
import json
import os
import re
import sys
from typing import Dict, List, Set, Tuple

# ANSI Terminal Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class ZeroLossLogVerifier:
    """Audits log files and rotated archives for strict sequence continuity."""

    def __init__(self, log_dir: str, base_name: str = "app.log"):
        self.log_dir = os.path.abspath(log_dir)
        self.base_name = base_name

        self.discovered_files: List[Tuple[str, int]] = []  # (filepath, sort_index)
        self.file_stats: List[Dict] = []
        self.all_sequences: Set[int] = set()
        self.duplicate_sequences: Set[int] = set()
        self.reopen_events: List[Dict] = []
        self.total_records: int = 0
        self.min_seq: int = sys.maxsize
        self.max_seq: int = 0

    def discover_log_files(self) -> None:
        """Scan target directory and identify active and rotated log files."""
        if not os.path.exists(self.log_dir):
            print(
                f"{CLR_RED}[FAIL] Directory does not exist: {self.log_dir}{CLR_RESET}",
                file=sys.stderr,
            )
            sys.exit(1)

        pattern = re.compile(rf"^{re.escape(self.base_name)}(\.(\d+))?(\.gz)?$")
        found = []

        for fname in os.listdir(self.log_dir):
            match = pattern.match(fname)
            if match:
                fpath = os.path.join(self.log_dir, fname)
                # Determine rotation order index (0 for active file, N for .N or .N.gz)
                rot_num = int(match.group(2)) if match.group(2) else 0
                found.append((fpath, rot_num, fname))

        # Sort files: active (0) first, then .1, .2, .3...
        found.sort(key=lambda x: x[1])
        self.discovered_files = [(item[0], item[1]) for item in found]

    def _read_file_lines(self, fpath: str) -> List[str]:
        """Read lines from plaintext or gzip-compressed log file."""
        if fpath.endswith(".gz"):
            with gzip.open(fpath, "rt", encoding="utf-8", errors="replace") as f:
                return f.readlines()
        else:
            with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                return f.readlines()

    def audit(self) -> bool:
        """Parse all discovered log files and evaluate zero-loss criteria."""
        self.discover_log_files()

        if not self.discovered_files:
            print(
                f"{CLR_RED}[FAIL] No log files matching '{self.base_name}' found in {self.log_dir}{CLR_RESET}",
                file=sys.stderr,
            )
            return False

        for fpath, rot_idx in self.discovered_files:
            fname = os.path.basename(fpath)
            fsize = os.path.getsize(fpath)
            is_compressed = fpath.endswith(".gz")

            lines = self._read_file_lines(fpath)
            file_seqs: List[int] = []
            file_inodes: Set[int] = set()

            for line in lines:
                stripped = line.strip()
                if not stripped:
                    continue

                try:
                    data = json.loads(stripped)
                except json.JSONDecodeError:
                    continue

                self.total_records += 1
                seq = data.get("seq")
                if isinstance(seq, int):
                    if seq in self.all_sequences:
                        self.duplicate_sequences.add(seq)
                    self.all_sequences.add(seq)
                    file_seqs.append(seq)
                    self.min_seq = min(self.min_seq, seq)
                    self.max_seq = max(self.max_seq, seq)

                if "inode" in data and isinstance(data["inode"], int):
                    file_inodes.add(data["inode"])

                if data.get("event") == "log_file_reopened":
                    self.reopen_events.append(data)

            min_fseq = min(file_seqs) if file_seqs else None
            max_fseq = max(file_seqs) if file_seqs else None

            self.file_stats.append(
                {
                    "filename": fname,
                    "rotation_index": rot_idx,
                    "size_bytes": fsize,
                    "is_compressed": is_compressed,
                    "record_count": len(file_seqs),
                    "min_seq": min_fseq,
                    "max_seq": max_fseq,
                    "inodes": list(file_inodes),
                }
            )

        return True

    def print_report(self) -> bool:
        """Render a formatted, colored verification audit report."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 72)
        print("  📊 LOGROTATE ZERO-LOSS SEQUENCE CONTINUITY AUDIT REPORT")
        print("=" * 72 + f"{CLR_RESET}\n")

        print(f"  {CLR_BOLD}Target Log Directory:{CLR_RESET} {self.log_dir}")
        print(f"  {CLR_BOLD}Base Log File:{CLR_RESET}        {self.base_name}")
        print(f"  {CLR_BOLD}Total Files Audited:{CLR_RESET}  {len(self.discovered_files)}")
        print(f"  {CLR_BOLD}Total Log Records:{CLR_RESET}    {self.total_records}")

        if self.min_seq <= self.max_seq:
            print(f"  {CLR_BOLD}Sequence Range:{CLR_RESET}       [#{self.min_seq} → #{self.max_seq}]")

        print(f"\n  {CLR_BOLD}Discovered Log Archives & Inodes Breakdown:{CLR_RESET}")
        print(
            f"  {CLR_GRAY}┌──────────────────────┬──────────┬────────────┬──────────────┬──────────────┐{CLR_RESET}"
        )
        print(
            f"  {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}File Name{CLR_RESET}            {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}Size (B){CLR_RESET} {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}Gzip Enc?{CLR_RESET}  {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}Record Count{CLR_RESET} {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}Sequence Range{CLR_RESET} {CLR_GRAY}│{CLR_RESET}"
        )
        print(
            f"  {CLR_GRAY}├──────────────────────┼──────────┼────────────┼──────────────┼──────────────┤{CLR_RESET}"
        )

        for stat in self.file_stats:
            seq_range_str = (
                f"#{stat['min_seq']:>4} - #{stat['max_seq']:<4}"
                if stat["min_seq"] is not None
                else "Empty"
            )
            gz_label = (
                f"{CLR_GREEN}Yes (gzip){CLR_RESET}"
                if stat["is_compressed"]
                else f"{CLR_YELLOW}No (plain){CLR_RESET}"
            )
            print(
                f"  {CLR_GRAY}│{CLR_RESET} {stat['filename']:<20} {CLR_GRAY}│{CLR_RESET} {stat['size_bytes']:>8} {CLR_GRAY}│{CLR_RESET} {gz_label:<18} {CLR_GRAY}│{CLR_RESET} {stat['record_count']:>12} {CLR_GRAY}│{CLR_RESET} {seq_range_str:<12} {CLR_GRAY}│{CLR_RESET}"
            )

        print(
            f"  {CLR_GRAY}└──────────────────────┴──────────┴────────────┴──────────────┴──────────────┘{CLR_RESET}\n"
        )

        # Evaluate Zero-Loss Assertion
        passed = True
        missing_sequences = []

        if self.min_seq <= self.max_seq:
            expected_range = set(range(self.min_seq, self.max_seq + 1))
            missing_set = expected_range - self.all_sequences
            missing_sequences = sorted(list(missing_set))

        print(f"  {CLR_BOLD}Integrity Assertions:{CLR_RESET}")

        if not missing_sequences:
            print(f"  • Dropped / Missing Entries:  {CLR_GREEN}0 (Zero Loss Verified!){CLR_RESET}")
        else:
            passed = False
            print(
                f"  • Dropped / Missing Entries:  {CLR_RED}{len(missing_sequences)} DROPPED RECORDS!{CLR_RESET}"
            )
            print(
                f"    {CLR_RED}Missing IDs: {missing_sequences[:10]}{' ...' if len(missing_sequences)>10 else ''}{CLR_RESET}"
            )

        if not self.duplicate_sequences:
            print(f"  • Duplicate Sequence IDs:     {CLR_GREEN}0 (Unique Monotonic Indexing){CLR_RESET}")
        else:
            passed = False
            print(f"  • Duplicate Sequence IDs:     {CLR_RED}{len(self.duplicate_sequences)} Duplicates!{CLR_RESET}")

        print(f"  • SIGHUP Reopen Events Logged: {CLR_CYAN}{len(self.reopen_events)} Transitions{CLR_RESET}")
        for evt in self.reopen_events:
            print(
                f"    ↳ Inode {evt.get('old_inode')} → {evt.get('new_inode')} (Seq #{evt.get('seq')})"
            )

        print(f"\n{CLR_CYAN}" + "=" * 72 + f"{CLR_RESET}\n")

        if passed and self.total_records > 0:
            print(
                f"{CLR_GREEN}{CLR_BOLD}✅ VERIFICATION PASSED: Zero log entries dropped during rotation cycles!{CLR_RESET}\n"
            )
            return True
        else:
            print(
                f"{CLR_RED}{CLR_BOLD}❌ VERIFICATION FAILED: Log continuity violations detected.{CLR_RESET}\n"
            )
            return False


# ------------------------------------------------------------------------------
# CLI Entrypoint
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Audit logrotate directories for zero dropped logs and sequence continuity."
    )
    parser.add_argument(
        "--log-dir",
        default="/var/log/custom-app",
        help="Directory containing active and rotated log files (default: /var/log/custom-app)",
    )
    parser.add_argument(
        "--base-name",
        default="app.log",
        help="Base name of the application log file (default: app.log)",
    )
    args = parser.parse_args()

    verifier = ZeroLossLogVerifier(log_dir=args.log_dir, base_name=args.base_name)
    if not verifier.audit():
        sys.exit(1)

    success = verifier.print_report()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
