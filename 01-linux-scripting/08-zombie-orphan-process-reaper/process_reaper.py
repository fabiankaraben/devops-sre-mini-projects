#!/usr/bin/env python3
"""
Zombie and Orphan Process Reaper
=================================
A diagnostic and automated remediation utility for Linux systems that inspects
/proc and process tables, identifies Zombie (defunct) and Orphan processes,
traces process ancestry, and safely reaps them using POSIX signals and PID 1 inheritance.

Part of: DevOps & SRE Mini-Projects
Domain:  01. Linux Scripting
"""

import argparse
from datetime import datetime, timezone
import json
import os
import re
import signal
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Set, Tuple

# Terminal ANSI Color Codes
COLOR_RESET = "\033[0m"
COLOR_BOLD = "\033[1m"
COLOR_DIM = "\033[2m"
COLOR_RED = "\033[0;31m"
COLOR_BOLD_RED = "\033[1;31m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[0;33m"
COLOR_BLUE = "\033[0;34m"
COLOR_MAGENTA = "\033[0;35m"
COLOR_CYAN = "\033[0;36m"
COLOR_WHITE = "\033[1;37m"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# System daemons that normally run with PPID 1 and should not be flagged as rogue orphans
SYSTEM_INIT_NAMES = {
    "systemd", "init", "launchd", "kthreadd", "dockerd", "containerd",
    "sshd", "rsyslogd", "cron", "crond", "dbus-daemon", "udevd",
    "kernel_task", "syslogd", "orbstack", "dumb-init", "tini",
}


class ProcessInfo:
    def __init__(self, pid: int, ppid: int, state: str, name: str, cmdline: str):
        self.pid = pid
        self.ppid = ppid
        self.state = state  # R, S, D, Z, T, etc.
        self.name = name
        self.cmdline = cmdline
        self.children: List[int] = []

    def is_zombie(self) -> bool:
        return self.state.upper().startswith("Z") or "defunct" in self.cmdline.lower() or "defunct" in self.name.lower()

    def to_dict(self) -> Dict[str, Any]:
        return {
            "pid": self.pid,
            "ppid": self.ppid,
            "state": self.state,
            "name": self.name,
            "cmdline": self.cmdline,
            "is_zombie": self.is_zombie(),
        }


def read_proc_stat(pid: int) -> Optional[Tuple[int, int, str, str]]:
    """Directly reads /proc/[pid]/stat on Linux."""
    stat_path = f"/proc/{pid}/stat"
    try:
        with open(stat_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read().strip()
        # The comm field is enclosed in parentheses: e.g. "1234 (my process) Z 1230 ..."
        match = re.match(r"^(\d+)\s+\((.+)\)\s+([A-Za-z])\s+(\d+)", content)
        if match:
            pid_val = int(match.group(1))
            comm_val = match.group(2)
            state_val = match.group(3)
            ppid_val = int(match.group(4))
            return pid_val, ppid_val, state_val, comm_val
    except Exception:
        pass
    return None


def read_proc_cmdline(pid: int) -> str:
    """Reads /proc/[pid]/cmdline."""
    cmd_path = f"/proc/{pid}/cmdline"
    try:
        with open(cmd_path, "rb") as f:
            raw = f.read()
        parts = raw.split(b"\x00")
        cmd = " ".join(p.decode("utf-8", errors="ignore") for p in parts if p)
        return cmd if cmd else ""
    except Exception:
        return ""


def get_all_processes_proc() -> Dict[int, ProcessInfo]:
    """Inspects Linux /proc virtual filesystem directly."""
    processes: Dict[int, ProcessInfo] = {}
    if not os.path.exists("/proc"):
        return processes

    for entry in os.listdir("/proc"):
        if entry.isdigit():
            pid = int(entry)
            stat_res = read_proc_stat(pid)
            if stat_res:
                p_pid, p_ppid, p_state, p_name = stat_res
                cmdline = read_proc_cmdline(p_pid) or p_name
                processes[p_pid] = ProcessInfo(p_pid, p_ppid, p_state, p_name, cmdline)

    return processes


def get_all_processes_ps() -> Dict[int, ProcessInfo]:
    """Fallback using POSIX ps command on macOS / BSD."""
    processes: Dict[int, ProcessInfo] = {}
    try:
        # ps -axo pid,ppid,state,comm,command
        cmd = ["ps", "-axo", "pid,ppid,state,comm,command"]
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, universal_newlines=True)
        lines = out.strip().splitlines()
        if not lines:
            return processes

        # Skip header
        for line in lines[1:]:
            parts = line.strip().split(None, 4)
            if len(parts) >= 4:
                try:
                    pid = int(parts[0])
                    ppid = int(parts[1])
                    state = parts[2]
                    comm = parts[3]
                    cmdline = parts[4] if len(parts) > 4 else comm
                    processes[pid] = ProcessInfo(pid, ppid, state, comm, cmdline)
                except ValueError:
                    continue
    except Exception:
        pass
    return processes


def get_system_process_table() -> Dict[int, ProcessInfo]:
    """Retrieves all system processes via /proc or ps fallback and builds parent-child links."""
    if os.path.exists("/proc/1/stat"):
        procs = get_all_processes_proc()
    else:
        procs = get_all_processes_ps()

    # Link children
    for pid, proc in procs.items():
        if proc.ppid in procs:
            procs[proc.ppid].children.append(pid)

    return procs


def get_pid_max() -> int:
    """Reads Linux kernel /proc/sys/kernel/pid_max."""
    pid_max_path = "/proc/sys/kernel/pid_max"
    if os.path.exists(pid_max_path):
        try:
            with open(pid_max_path, "r", encoding="utf-8") as f:
                return int(f.read().strip())
        except Exception:
            pass
    return 32768  # Standard POSIX default


def trace_ancestry(pid: int, procs: Dict[int, ProcessInfo]) -> List[Dict[str, Any]]:
    """Traces full ancestry from PID back to Root (PID 1)."""
    ancestry = []
    curr_pid = pid
    visited = set()

    while curr_pid in procs and curr_pid not in visited:
        visited.add(curr_pid)
        p = procs[curr_pid]
        ancestry.append({
            "pid": p.pid,
            "name": p.name,
            "state": p.state,
            "cmdline": p.cmdline,
        })
        if p.ppid == 0 or p.ppid == curr_pid:
            break
        curr_pid = p.ppid

    return ancestry


def is_system_daemon(proc: ProcessInfo) -> bool:
    """Identifies legitimate OS background daemons that run with PPID 1."""
    base_name = proc.name.lower().split("/")[-1]
    cmd_lower = proc.cmdline.lower()
    if base_name in SYSTEM_INIT_NAMES or base_name.startswith("kworker") or base_name.startswith("systemd"):
        return True
    if any(cmd_lower.startswith(p) for p in ("/system/", "/usr/libexec/", "/usr/sbin/", "/library/apple/", "/system/library/")):
        return True
    return False


def classify_processes(procs: Dict[int, ProcessInfo]) -> Tuple[List[ProcessInfo], List[ProcessInfo], Dict[int, List[ProcessInfo]]]:
    """
    Classifies processes into:
      - zombies: List of zombie (defunct) processes
      - orphans: List of orphaned processes (PPID 1, not standard system daemons)
      - negligent_parents: Dict of parent PID -> List of its zombie children
    """
    zombies: List[ProcessInfo] = []
    orphans: List[ProcessInfo] = []
    negligent_parents: Dict[int, List[ProcessInfo]] = {}

    for pid, proc in procs.items():
        if proc.is_zombie():
            zombies.append(proc)
            if proc.ppid not in negligent_parents:
                negligent_parents[proc.ppid] = []
            negligent_parents[proc.ppid].append(proc)
        elif proc.ppid == 1 and proc.pid != 1:
            if not is_system_daemon(proc):
                orphans.append(proc)

    zombies.sort(key=lambda x: x.pid)
    orphans.sort(key=lambda x: x.pid)
    return zombies, orphans, negligent_parents


def reap_via_sigchld(negligent_parents: Dict[int, List[ProcessInfo]], procs: Dict[int, ProcessInfo]) -> List[Dict[str, Any]]:
    """Sends SIGCHLD signal to parents of zombie processes to trigger waitpid() handling."""
    actions = []
    for ppid, z_children in negligent_parents.items():
        pname = procs[ppid].name if ppid in procs else "Unknown"
        try:
            os.kill(ppid, signal.SIGCHLD)
            actions.append({
                "parent_pid": ppid,
                "parent_name": pname,
                "signal": "SIGCHLD",
                "status": "SENT",
                "affected_zombies": [z.pid for z in z_children],
                "message": f"Sent SIGCHLD to parent PID {ppid} ({pname}) to prompt waitpid()",
            })
        except ProcessLookupError:
            actions.append({
                "parent_pid": ppid,
                "parent_name": pname,
                "signal": "SIGCHLD",
                "status": "NOT_FOUND",
                "affected_zombies": [z.pid for z in z_children],
                "message": f"Parent PID {ppid} already exited",
            })
        except PermissionError:
            actions.append({
                "parent_pid": ppid,
                "parent_name": pname,
                "signal": "SIGCHLD",
                "status": "PERMISSION_DENIED",
                "affected_zombies": [z.pid for z in z_children],
                "message": f"Permission denied sending signal to parent PID {ppid}",
            })
    return actions


def reap_via_kill_parent(negligent_parents: Dict[int, List[ProcessInfo]], procs: Dict[int, ProcessInfo], force: bool = False) -> List[Dict[str, Any]]:
    """
    Terminates negligent parents with SIGTERM/SIGKILL, forcing the Linux kernel
    to re-parent zombie children to PID 1 (init/systemd) which reaps them immediately.
    """
    actions = []
    sig = signal.SIGKILL if force else signal.SIGTERM
    sig_name = "SIGKILL" if force else "SIGTERM"

    for ppid, z_children in negligent_parents.items():
        # Do not kill init (PID 1) or system roots
        if ppid <= 1:
            continue

        pname = procs[ppid].name if ppid in procs else "Unknown"
        try:
            os.kill(ppid, sig)
            actions.append({
                "parent_pid": ppid,
                "parent_name": pname,
                "signal": sig_name,
                "status": "TERMINATED",
                "affected_zombies": [z.pid for z in z_children],
                "message": f"Killed negligent parent PID {ppid} ({pname}) with {sig_name}. Kernel will re-parent zombies to PID 1.",
            })
        except ProcessLookupError:
            actions.append({
                "parent_pid": ppid,
                "parent_name": pname,
                "signal": sig_name,
                "status": "NOT_FOUND",
                "affected_zombies": [z.pid for z in z_children],
                "message": f"Parent PID {ppid} already terminated",
            })
        except PermissionError:
            actions.append({
                "parent_pid": ppid,
                "parent_name": pname,
                "signal": sig_name,
                "status": "PERMISSION_DENIED",
                "affected_zombies": [z.pid for z in z_children],
                "message": f"Permission denied terminating parent PID {ppid}",
            })

    return actions


def kill_orphan_processes(orphans: List[ProcessInfo], match_name: Optional[str] = None) -> List[Dict[str, Any]]:
    """Terminates rogue orphan processes."""
    actions = []
    for o in orphans:
        if match_name and match_name.lower() not in o.name.lower() and match_name.lower() not in o.cmdline.lower():
            continue

        # Prevent killing system critical processes
        if o.pid <= 1 or o.name in SYSTEM_INIT_NAMES:
            continue

        try:
            os.kill(o.pid, signal.SIGTERM)
            actions.append({
                "pid": o.pid,
                "name": o.name,
                "signal": "SIGTERM",
                "status": "TERMINATED",
                "message": f"Terminated orphan process PID {o.pid} ({o.name})",
            })
        except Exception as e:
            actions.append({
                "pid": o.pid,
                "name": o.name,
                "signal": "SIGTERM",
                "status": "ERROR",
                "message": str(e),
            })
    return actions


def print_cli_report(
    procs: Dict[int, ProcessInfo],
    zombies: List[ProcessInfo],
    orphans: List[ProcessInfo],
    negligent_parents: Dict[int, List[ProcessInfo]],
    pid_max: int,
    actions_taken: Optional[List[Dict[str, Any]]] = None,
):
    """Renders ANSI colorized process diagnostics and ancestry trees."""
    total_procs = len(procs)
    utilization_pct = round((total_procs / pid_max) * 100, 2) if pid_max > 0 else 0.0

    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                         ZOMBIE & ORPHAN PROCESS DIAGNOSTIC REPORT                                      {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Timestamp : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"PID Table : {COLOR_BOLD}{total_procs}{COLOR_RESET} active / {COLOR_DIM}{pid_max} max{COLOR_RESET} (Utilization: {COLOR_GREEN if utilization_pct < 50 else COLOR_RED}{utilization_pct}%{COLOR_RESET})\n")

    # 1. Zombie Processes Section
    print(f"{COLOR_BOLD}1. ZOMBIE (DEFUNCT) PROCESSES ({len(zombies)} found):{COLOR_RESET}")
    if zombies:
        print(f"  {COLOR_BOLD}{'PID':<8} {'PPID':<8} {'PARENT NAME':<22} {'PROCESS NAME':<24} {'ANCESTRY TREE':<30}{COLOR_RESET}")
        print(COLOR_DIM + "  " + "-" * 98 + COLOR_RESET)
        for z in zombies:
            parent_name = procs[z.ppid].name if z.ppid in procs else "Unknown (Exited)"
            ancestry = trace_ancestry(z.pid, procs)
            tree_str = " -> ".join(f"{a['name']}({a['pid']})" for a in reversed(ancestry))
            if len(tree_str) > 35:
                tree_str = "..." + tree_str[-32:]
            print(f"  {COLOR_BOLD_RED}{z.pid:<8}{COLOR_RESET} {z.ppid:<8} {parent_name:<22} {z.name:<24} {COLOR_CYAN}{tree_str}{COLOR_RESET}")
    else:
        print(f"  {COLOR_GREEN}✔ No zombie processes detected. Process table is clean.{COLOR_RESET}")
    print()

    # 2. Negligent Parents Section
    print(f"{COLOR_BOLD}2. NEGLIGENT PARENT PROCESSES ({len(negligent_parents)} found):{COLOR_RESET}")
    if negligent_parents:
        print(f"  {COLOR_BOLD}{'PPID':<8} {'PARENT NAME':<25} {'ZOMBIE CHILDREN PIDs':<30} {'REMEDIATION HINT'}{COLOR_RESET}")
        print(COLOR_DIM + "  " + "-" * 98 + COLOR_RESET)
        for ppid, z_list in negligent_parents.items():
            p_name = procs[ppid].name if ppid in procs else "Exited / Nonexistent"
            z_pids_str = ", ".join(str(z.pid) for z in z_list)
            if len(z_pids_str) > 28:
                z_pids_str = z_pids_str[:25] + "..."
            hint = f"Send SIGCHLD: 'kill -17 {ppid}' or Kill: 'kill -9 {ppid}'"
            print(f"  {COLOR_YELLOW}{ppid:<8}{COLOR_RESET} {p_name:<25} {z_pids_str:<30} {COLOR_DIM}{hint}{COLOR_RESET}")
    else:
        print(f"  {COLOR_GREEN}✔ No negligent parents detected.{COLOR_RESET}")
    print()

    # 3. Orphan Processes Section
    print(f"{COLOR_BOLD}3. UNTRACKED ORPHAN PROCESSES ({len(orphans)} detected):{COLOR_RESET}")
    if orphans:
        print(f"  {COLOR_BOLD}{'PID':<8} {'PPID':<8} {'PROCESS NAME':<25} {'COMMAND / ARGS'}{COLOR_RESET}")
        print(COLOR_DIM + "  " + "-" * 98 + COLOR_RESET)
        for o in orphans[:10]:
            cmd = o.cmdline
            if len(cmd) > 50:
                cmd = cmd[:47] + "..."
            print(f"  {COLOR_MAGENTA}{o.pid:<8}{COLOR_RESET} {o.ppid:<8} {o.name:<25} {cmd}")
        if len(orphans) > 10:
            print(f"  {COLOR_DIM}... ({len(orphans)-10} additional orphan processes omitted) ...{COLOR_RESET}")
    else:
        print(f"  {COLOR_GREEN}✔ No untracked orphan processes detected.{COLOR_RESET}")
    print()

    # 4. Actions Taken (if remediation performed)
    if actions_taken:
        print(f"{COLOR_BOLD}4. REMEDIATION ACTIONS EXECUTED:{COLOR_RESET}")
        for act in actions_taken:
            print(f"  - [{COLOR_GREEN}{act['status']}{COLOR_RESET}] {act['message']}")
        print()

    print(COLOR_DIM + "=" * 104 + COLOR_RESET + "\n")


def generate_json_report(
    procs: Dict[int, ProcessInfo],
    zombies: List[ProcessInfo],
    orphans: List[ProcessInfo],
    negligent_parents: Dict[int, List[ProcessInfo]],
    pid_max: int,
    actions_taken: Optional[List[Dict[str, Any]]] = None,
) -> str:
    """Generates structured machine-parseable JSON."""
    total_procs = len(procs)
    utilization_pct = round((total_procs / pid_max) * 100, 2) if pid_max > 0 else 0.0

    zombie_records = []
    for z in zombies:
        ancestry = trace_ancestry(z.pid, procs)
        zombie_records.append({
            "pid": z.pid,
            "ppid": z.ppid,
            "name": z.name,
            "cmdline": z.cmdline,
            "parent_name": procs[z.ppid].name if z.ppid in procs else "Unknown",
            "ancestry": ancestry,
        })

    data = {
        "metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "total_processes": total_procs,
            "pid_max": pid_max,
            "pid_utilization_percent": utilization_pct,
            "zombie_count": len(zombies),
            "orphan_count": len(orphans),
            "negligent_parent_count": len(negligent_parents),
            "status": "CRITICAL" if len(zombies) > 5 else ("WARNING" if len(zombies) > 0 else "HEALTHY"),
        },
        "zombies": zombie_records,
        "negligent_parents": [
            {
                "ppid": ppid,
                "name": procs[ppid].name if ppid in procs else "Unknown",
                "zombie_children_pids": [z.pid for z in z_list],
            }
            for ppid, z_list in negligent_parents.items()
        ],
        "orphans": [o.to_dict() for o in orphans],
        "actions_taken": actions_taken or [],
    }
    return json.dumps(data, indent=2)


def generate_prometheus_metrics(
    procs: Dict[int, ProcessInfo],
    zombies: List[ProcessInfo],
    orphans: List[ProcessInfo],
    negligent_parents: Dict[int, List[ProcessInfo]],
    pid_max: int,
) -> str:
    """Generates OpenMetrics / Prometheus text exposition format."""
    total_procs = len(procs)
    utilization_pct = round((total_procs / pid_max) * 100, 2) if pid_max > 0 else 0.0

    lines = [
        "# HELP zombie_processes_total Current count of defunct zombie processes in kernel process table",
        "# TYPE zombie_processes_total gauge",
        f"zombie_processes_total {len(zombies)}",
        "",
        "# HELP orphan_processes_total Current count of untracked orphaned processes re-parented to init",
        "# TYPE orphan_processes_total gauge",
        f"orphan_processes_total {len(orphans)}",
        "",
        "# HELP negligent_parents_total Current count of parent processes with unreaped zombie children",
        "# TYPE negligent_parents_total gauge",
        f"negligent_parents_total {len(negligent_parents)}",
        "",
        "# HELP process_table_active_processes Total number of active processes in process table",
        "# TYPE process_table_active_processes gauge",
        f"process_table_active_processes {total_procs}",
        "",
        "# HELP process_table_max_pids Kernel maximum process ID capacity (pid_max)",
        "# TYPE process_table_max_pids gauge",
        f"process_table_max_pids {pid_max}",
        "",
        "# HELP process_table_utilization_percent Percentage of total PID table capacity in use",
        "# TYPE process_table_utilization_percent gauge",
        f"process_table_utilization_percent {utilization_pct}",
    ]
    return "\n".join(lines) + "\n"


def auto_reap_cycle(procs: Dict[int, ProcessInfo], zombies: List[ProcessInfo], negligent_parents: Dict[int, List[ProcessInfo]]) -> List[Dict[str, Any]]:
    """
    Executes progressive auto-remediation:
    1. Sends SIGCHLD to parents.
    2. Waits 0.5s.
    3. If zombies remain, sends SIGTERM to negligent parents.
    4. If still remaining after 0.5s, sends SIGKILL to negligent parents.
    """
    actions_taken = []
    if not zombies:
        return actions_taken

    # Step 1: Gentle SIGCHLD
    actions_sigchld = reap_via_sigchld(negligent_parents, procs)
    actions_taken.extend(actions_sigchld)
    time.sleep(0.5)

    # Re-evaluate
    current_procs = get_system_process_table()
    current_zombies, _, current_parents = classify_processes(current_procs)

    if not current_zombies:
        actions_taken.append({
            "status": "REAPED_SUCCESSFULLY",
            "message": "All zombies successfully reaped via gentle SIGCHLD signal.",
        })
        return actions_taken

    # Step 2: Forceful Parent Termination (SIGTERM -> SIGKILL)
    actions_kill = reap_via_kill_parent(current_parents, current_procs, force=False)
    actions_taken.extend(actions_kill)
    time.sleep(0.5)

    # Check again
    current_procs = get_system_process_table()
    current_zombies, _, current_parents = classify_processes(current_procs)

    if current_zombies:
        actions_force_kill = reap_via_kill_parent(current_parents, current_procs, force=True)
        actions_taken.extend(actions_force_kill)
        time.sleep(0.5)

    return actions_taken


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Zombie and Orphan Process Reaper - Linux process lifecycle inspector, hierarchy tracer, and automated cleanup utility.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "--scan",
        action="store_true",
        help="Scan and report zombie/orphan processes (default behavior).",
    )
    parser.add_argument(
        "--reap-sigchld",
        action="store_true",
        dest="reap_sigchld",
        help="Send SIGCHLD to parents of zombie processes to trigger waitpid() cleanup.",
    )
    parser.add_argument(
        "--kill-parents",
        action="store_true",
        dest="kill_parents",
        help="Terminate negligent parents with SIGTERM/SIGKILL, forcing kernel re-parenting to PID 1.",
    )
    parser.add_argument(
        "--kill-orphans",
        action="store_true",
        dest="kill_orphans",
        help="Terminate rogue orphan processes.",
    )
    parser.add_argument(
        "--match",
        dest="match_name",
        help="Filter process name or command string when terminating orphans.",
    )
    parser.add_argument(
        "--auto-reap",
        action="store_true",
        dest="auto_reap",
        help="Progressively auto-reap zombies (SIGCHLD -> SIGTERM parent -> SIGKILL parent).",
    )
    parser.add_argument(
        "-d", "--daemon",
        action="store_true",
        help="Run continuously in background daemon mode.",
    )
    parser.add_argument(
        "-i", "--interval",
        type=int,
        default=5,
        help="Daemon poll interval in seconds (default: 5s).",
    )
    parser.add_argument(
        "-j", "--json",
        action="store_true",
        dest="json_output",
        help="Output report in machine-readable JSON format.",
    )
    parser.add_argument(
        "-p", "--prometheus",
        action="store_true",
        dest="prom_output",
        help="Output metrics in Prometheus / OpenMetrics format.",
    )
    parser.add_argument(
        "-o", "--output",
        dest="output_file",
        help="Write output report directly to specified file inside project directory.",
    )
    parser.add_argument(
        "--critical-threshold",
        type=int,
        default=10,
        help="Threshold of zombie count to trigger exit code 2 (default: 10).",
    )
    parser.add_argument(
        "--no-fail",
        action="store_true",
        help="Always return exit code 0 regardless of zombie count.",
    )

    args = parser.parse_args()

    pid_max = get_pid_max()

    def run_single_iteration() -> Tuple[int, str]:
        procs = get_system_process_table()
        zombies, orphans, negligent_parents = classify_processes(procs)
        actions_taken: List[Dict[str, Any]] = []

        if args.auto_reap and zombies:
            actions_taken = auto_reap_cycle(procs, zombies, negligent_parents)
            # Re-sample
            procs = get_system_process_table()
            zombies, orphans, negligent_parents = classify_processes(procs)
        elif args.reap_sigchld and zombies:
            actions_taken = reap_via_sigchld(negligent_parents, procs)
        elif args.kill_parents and zombies:
            actions_taken = reap_via_kill_parent(negligent_parents, procs, force=True)

        if args.kill_orphans and orphans:
            act_orphan = kill_orphan_processes(orphans, args.match_name)
            actions_taken.extend(act_orphan)

        rendered = ""
        if args.json_output:
            rendered = generate_json_report(procs, zombies, orphans, negligent_parents, pid_max, actions_taken)
        elif args.prom_output:
            rendered = generate_prometheus_metrics(procs, zombies, orphans, negligent_parents, pid_max)
        else:
            print_cli_report(procs, zombies, orphans, negligent_parents, pid_max, actions_taken)

        if args.output_file and rendered:
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(rendered + ("\n" if not rendered.endswith("\n") else ""))
        elif rendered:
            print(rendered)

        # Exit code determination
        if args.no_fail:
            return 0, rendered

        if len(zombies) >= args.critical_threshold:
            return 2, rendered
        elif len(zombies) > 0:
            return 1, rendered

        return 0, rendered

    if args.daemon:
        print(f"{COLOR_BOLD}{COLOR_BLUE}[DAEMON] Starting Process Reaper Watchdog (Interval: {args.interval}s, Auto-Reap: {args.auto_reap})...{COLOR_RESET}")
        try:
            while True:
                run_single_iteration()
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print(f"\n{COLOR_YELLOW}[DAEMON] Watchdog stopped.{COLOR_RESET}")
            return 0
    else:
        code, _ = run_single_iteration()
        return code


if __name__ == "__main__":
    sys.exit(main())
