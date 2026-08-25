#!/usr/bin/env python3
"""
Linux Kernel & Sysctl Performance Tuner (Python Edition)
=========================================================
Audits system parameters against production baselines, applies tuned profiles
(Web, Database, HPC), manages automated snapshot backups, and executes instant rollbacks.

Part of: DevOps & SRE Mini-Projects
Domain:  01. Linux Scripting
"""

import argparse
from datetime import datetime, timezone
import json
import os
import re
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

COLOR_RESET = "\033[0m"
COLOR_BOLD = "\033[1m"
COLOR_DIM = "\033[2m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[0;33m"
COLOR_RED = "\033[0;31m"
COLOR_BLUE = "\033[0;34m"
COLOR_CYAN = "\033[0;36m"
COLOR_WHITE = "\033[1;37m"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROFILES_DIR = os.path.join(SCRIPT_DIR, "profiles")
BACKUPS_DIR = os.path.join(SCRIPT_DIR, "backups")


def normalize_val(val: Optional[str]) -> str:
    """Normalizes whitespace and tabs."""
    if val is None:
        return ""
    return re.sub(r"\s+", " ", val.strip())


def read_sysctl_value(key: str) -> Optional[str]:
    """Reads a sysctl value directly from /proc/sys or via sysctl CLI."""
    proc_path = f"/proc/sys/{key.replace('.', '/')}"
    if os.path.exists(proc_path):
        try:
            with open(proc_path, "r", encoding="utf-8", errors="ignore") as f:
                return normalize_val(f.read())
        except Exception:
            pass

    try:
        out = subprocess.check_output(
            ["sysctl", "-n", key],
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
        )
        return normalize_val(out)
    except Exception:
        pass

    return None


def write_sysctl_value(key: str, val: str, dry_run: bool = False) -> bool:
    """Applies a sysctl value to active kernel."""
    if dry_run:
        return True

    # 1. Try sysctl -w
    try:
        res = subprocess.run(
            ["sysctl", "-w", f"{key}={val}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if res.returncode == 0:
            return True
    except Exception:
        pass

    # 2. Try direct /proc/sys write
    proc_path = f"/proc/sys/{key.replace('.', '/')}"
    if os.path.exists(proc_path):
        try:
            with open(proc_path, "w", encoding="utf-8") as f:
                f.write(val + "\n")
            return True
        except Exception:
            pass

    return False


def parse_conf_file(filepath: str) -> List[Tuple[str, str]]:
    """Parses key = value parameters from a sysctl .conf file."""
    params = []
    if not os.path.exists(filepath):
        return params

    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            cleaned = re.sub(r"#.*$", "", line).strip()
            if not cleaned:
                continue
            match = re.match(r"^([a-zA-Z0-9._-]+)\s*=\s*(.*)$", cleaned)
            if match:
                k = match.group(1).strip()
                v = normalize_val(match.group(2))
                params.append((k, v))
    return params


def resolve_profile_path(profile_name_or_path: str) -> str:
    """Resolves profile by name (web, db, hpc) or direct filepath."""
    if os.path.isfile(profile_name_or_path):
        return os.path.abspath(profile_name_or_path)

    candidate = os.path.join(PROFILES_DIR, f"{profile_name_or_path}.conf")
    if os.path.isfile(candidate):
        return candidate

    candidate2 = os.path.join(PROFILES_DIR, profile_name_or_path)
    if os.path.isfile(candidate2):
        return candidate2

    raise FileNotFoundError(f"Profile '{profile_name_or_path}' not found in {PROFILES_DIR}")


def run_audit(profile_path: str) -> Dict[str, Any]:
    """Compares current kernel parameters against target profile."""
    targets = parse_conf_file(profile_path)
    results = []
    optimal_count = 0
    suboptimal_count = 0
    unavailable_count = 0

    for key, target_val in targets:
        current_val = read_sysctl_value(key)
        if current_val is None:
            status = "UNAVAILABLE"
            unavailable_count += 1
        elif current_val == target_val:
            status = "OPTIMAL"
            optimal_count += 1
        else:
            status = "SUBOPTIMAL"
            suboptimal_count += 1

        results.append({
            "parameter": key,
            "current": current_val if current_val is not None else "<not present>",
            "target": target_val,
            "status": status,
        })

    active_probes = len(targets) - unavailable_count
    compliance_pct = round((optimal_count / active_probes) * 100, 2) if active_probes > 0 else 0.0

    return {
        "profile": profile_path,
        "summary": {
            "total": len(targets),
            "optimal": optimal_count,
            "suboptimal": suboptimal_count,
            "unavailable": unavailable_count,
            "compliance_percent": compliance_pct,
        },
        "parameters": results,
    }


def print_cli_table(audit_data: Dict[str, Any]):
    """Renders formatted ANSI comparison table."""
    summary = audit_data["summary"]
    params = audit_data["parameters"]

    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                       LINUX KERNEL SYSCTL PERFORMANCE AUDITOR (PYTHON)                                  {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Profile  : {COLOR_CYAN}{audit_data['profile']}{COLOR_RESET}")
    print(f"Timestamp: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}\n")
    print(f"{COLOR_BOLD}{'KERNEL PARAMETER':<35}  {'CURRENT VALUE':<22}  {'TARGET VALUE':<22}  {'STATUS'}{COLOR_RESET}")
    print(COLOR_DIM + "-" * 104 + COLOR_RESET)

    for p in params:
        st = p["status"]
        if st == "OPTIMAL":
            badge = f"{COLOR_GREEN}[ OPTIMAL ]{COLOR_RESET}"
        elif st == "SUBOPTIMAL":
            badge = f"{COLOR_YELLOW}[SUBOPTIMAL]{COLOR_RESET}"
        else:
            badge = f"{COLOR_DIM}[ N/A     ]{COLOR_RESET}"

        curr_display = p["current"]
        if len(curr_display) > 21:
            curr_display = curr_display[:18] + "..."
        targ_display = p["target"]
        if len(targ_display) > 21:
            targ_display = targ_display[:18] + "..."

        print(f"{p['parameter']:<35}  {curr_display:<22}  {targ_display:<22}  {badge}")

    print(COLOR_DIM + "-" * 104 + COLOR_RESET)
    print(f"\n{COLOR_BOLD}AUDIT SUMMARY & COMPLIANCE:{COLOR_RESET}")
    print(f"  Total Checked   : {COLOR_BOLD}{summary['total']}{COLOR_RESET}")
    print(f"  {COLOR_GREEN}✔ Optimal       {COLOR_RESET}: {summary['optimal']}")
    print(f"  {COLOR_YELLOW}▲ Suboptimal    {COLOR_RESET}: {summary['suboptimal']}")
    print(f"  {COLOR_DIM}○ Unavailable   {COLOR_RESET}: {summary['unavailable']}")
    print(f"  Compliance Score: {COLOR_BOLD}{summary['compliance_percent']}%{COLOR_RESET}\n")


def generate_prometheus_metrics(audit_data: Dict[str, Any]) -> str:
    """Generates Prometheus / OpenMetrics format."""
    summary = audit_data["summary"]
    lines = [
        "# HELP sysctl_compliance_percent SRE compliance percentage against target kernel profile",
        "# TYPE sysctl_compliance_percent gauge",
        f"sysctl_compliance_percent {summary['compliance_percent']}",
        "",
        "# HELP sysctl_parameters_total Total kernel parameters evaluated in profile",
        "# TYPE sysctl_parameters_total gauge",
        f"sysctl_parameters_total {summary['total']}",
        "",
        "# HELP sysctl_parameters_optimal Parameters matching target values",
        "# TYPE sysctl_parameters_optimal gauge",
        f"sysctl_parameters_optimal {summary['optimal']}",
        "",
        "# HELP sysctl_parameters_suboptimal Parameters requiring performance tuning",
        "# TYPE sysctl_parameters_suboptimal gauge",
        f"sysctl_parameters_suboptimal {summary['suboptimal']}",
        "",
        "# HELP sysctl_parameter_state Individual kernel parameter alignment (1=optimal, 0=suboptimal)",
        "# TYPE sysctl_parameter_state gauge",
    ]

    for p in audit_data["parameters"]:
        is_opt = 1 if p["status"] == "OPTIMAL" else 0
        safe_param = p["parameter"]
        lines.append(f'sysctl_parameter_state{{parameter="{safe_param}",status="{p["status"]}"}} {is_opt}')

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Linux Kernel & Sysctl Performance Tuner - Audits, tunes, and manages parameter profiles.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument("--audit", action="store_true", help="Audit kernel parameters against profile (default)")
    parser.add_argument("--apply", action="store_true", help="Apply profile settings to active kernel with backup")
    parser.add_argument("--rollback", nargs="?", const="latest", help="Rollback to specified or latest snapshot backup")
    parser.add_argument("-p", "--profile", default="web", help="Profile name (web, db, hpc) or .conf path (default: web)")
    parser.add_argument("-c", "--config-file", default="/etc/sysctl.d/99-performance.conf", help="Target config file")
    parser.add_argument("-b", "--backup-dir", default=BACKUPS_DIR, help="Backup snapshots directory")
    parser.add_argument("--dry-run", action="store_true", help="Simulate execution without modifying kernel")
    parser.add_argument("-j", "--json", action="store_true", dest="json_output", help="Output report in JSON format")
    parser.add_argument("-m", "--prometheus", action="store_true", dest="prom_output", help="Output in Prometheus metrics format")
    parser.add_argument("-o", "--output", dest="output_file", help="Write output directly to file")
    parser.add_argument("--no-fail", action="store_true", help="Always return exit code 0")

    args = parser.parse_args()

    os.makedirs(args.backup_dir, exist_ok=True)

    # 1. Rollback Mode
    if args.rollback:
        target_backup = args.rollback
        if target_backup == "latest":
            backups = sorted(
                [os.path.join(args.backup_dir, f) for f in os.listdir(args.backup_dir) if f.startswith("sysctl_backup_") and f.endswith(".conf")],
                key=os.path.getmtime,
                reverse=True,
            )
            if not backups:
                print(f"{COLOR_RED}Error: No backup snapshot files found in {args.backup_dir}{COLOR_RESET}", file=sys.stderr)
                return 3
            target_backup = backups[0]

        if not os.path.isfile(target_backup):
            print(f"{COLOR_RED}Error: Backup file not found: {target_backup}{COLOR_RESET}", file=sys.stderr)
            return 3

        print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
        print(f"{COLOR_BOLD}                       REVERTING SYSCTL PARAMETERS (ROLLBACK)                                            {COLOR_RESET}")
        print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
        print(f"Restoring Snapshot: {COLOR_CYAN}{target_backup}{COLOR_RESET}\n")

        params = parse_conf_file(target_backup)
        restored_count = 0
        for k, v in params:
            if write_sysctl_value(k, v, args.dry_run):
                restored_count += 1
                print(f"  - {COLOR_GREEN}[RESTORED]{COLOR_RESET} {k} = {v}")
            else:
                print(f"  - {COLOR_RED}[FAILED]{COLOR_RESET}   {k} = {v}")

        print(f"\n{COLOR_BOLD}ROLLBACK COMPLETE:{COLOR_RESET} Restored {COLOR_GREEN}{restored_count}/{len(params)}{COLOR_RESET} parameters to snapshot state.\n")
        return 0

    # 2. Resolve Profile
    try:
        profile_path = resolve_profile_path(args.profile)
    except FileNotFoundError as e:
        print(f"{COLOR_RED}Error: {e}{COLOR_RESET}", file=sys.stderr)
        return 3

    # 3. Apply Mode
    if args.apply:
        print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
        print(f"{COLOR_BOLD}                       APPLYING SYSCTL PERFORMANCE PROFILE ({args.profile})                             {COLOR_RESET}")
        print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}\n")

        params = parse_conf_file(profile_path)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_file = os.path.join(args.backup_dir, f"sysctl_backup_{timestamp}.conf")

        # Snapshot Backup
        print(f"{COLOR_CYAN}[1/3] Creating snapshot backup of existing values...{COLOR_RESET}")
        with open(backup_file, "w", encoding="utf-8") as bf:
            bf.write(f"# Sysctl Snapshot Backup: {datetime.now(timezone.utc).isoformat()}\n")
            for k, _ in params:
                curr = read_sysctl_value(k)
                if curr is not None:
                    bf.write(f"{k} = {curr}\n")
        print(f"  {COLOR_GREEN}✔ Saved backup to: {COLOR_BOLD}{backup_file}{COLOR_RESET}")

        # Apply Values
        print(f"\n{COLOR_CYAN}[2/3] Applying parameters to active Linux kernel...{COLOR_RESET}")
        applied_count = 0
        for k, v in params:
            if write_sysctl_value(k, v, args.dry_run):
                applied_count += 1
                print(f"  - {COLOR_GREEN}[APPLIED]{COLOR_RESET} {k} = {v}")
            else:
                print(f"  - {COLOR_RED}[FAILED]{COLOR_RESET}  {k} = {v}")

        # Verify
        print(f"\n{COLOR_CYAN}[3/3] Verifying kernel state...{COLOR_RESET}")
        verified_count = sum(1 for k, v in params if read_sysctl_value(k) == v)

        print(f"\n{COLOR_BOLD}APPLICATION SUMMARY:{COLOR_RESET}")
        print(f"  Total Targets  : {len(params)}")
        print(f"  {COLOR_GREEN}✔ Applied      {COLOR_RESET}: {applied_count}")
        print(f"  {COLOR_GREEN}✔ Verified     {COLOR_RESET}: {verified_count}")
        print(f"  Rollback File  : {COLOR_BOLD}{backup_file}{COLOR_RESET}\n")
        return 0

    # 4. Audit Mode (Default)
    audit_data = run_audit(profile_path)

    rendered = ""
    if args.json_output:
        rendered = json.dumps(audit_data, indent=2)
    elif args.prom_output:
        rendered = generate_prometheus_metrics(audit_data)
    else:
        print_cli_table(audit_data)

    if args.output_file and rendered:
        with open(args.output_file, "w", encoding="utf-8") as f:
            f.write(rendered + ("\n" if not rendered.endswith("\n") else ""))
    elif rendered:
        print(rendered)

    if args.no_fail:
        return 0

    if audit_data["summary"]["suboptimal"] > 0:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
