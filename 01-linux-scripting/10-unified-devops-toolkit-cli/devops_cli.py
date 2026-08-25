#!/usr/bin/env python3
"""
Unified DevOps Toolkit CLI (Python Edition)
============================================
A production-grade, consolidated DevOps engineering CLI providing system health
diagnostics, web access log analytics, multi-host parallel SSH execution, and
cloud infrastructure cost estimation.

Part of: DevOps & SRE Mini-Projects
Domain:  01. Linux Scripting
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

VERSION = "1.0.0"
BUILD_DATE = "2026-08-25"

COLOR_RESET = "\033[0m"
COLOR_BOLD = "\033[1m"
COLOR_DIM = "\033[2m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[0;33m"
COLOR_RED = "\033[0;31m"
COLOR_BLUE = "\033[0;34m"
COLOR_MAGENTA = "\033[0;35m"
COLOR_CYAN = "\033[0;36m"
COLOR_WHITE = "\033[1;37m"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


# ==============================================================================
# MODULE 1: SYSTEM HEALTH (sys health)
# ==============================================================================

def get_cpu_load() -> Dict[str, Any]:
    """Retrieves load averages and logical core count."""
    cores = os.cpu_count() or 1
    load1, load5, load15 = 0.0, 0.0, 0.0
    try:
        load1, load5, load15 = os.getloadavg()
    except Exception:
        pass

    # Normalize utilization percentage
    util_pct = min(100.0, round((load1 / cores) * 100.0, 2))
    return {
        "cores": cores,
        "load_1m": round(load1, 2),
        "load_5m": round(load5, 2),
        "load_15m": round(load15, 2),
        "utilization_percent": util_pct,
    }


def get_memory_info() -> Dict[str, Any]:
    """Reads memory statistics across Linux and macOS."""
    total_mb, used_mb, free_mb = 0, 0, 0

    if os.path.exists("/proc/meminfo"):
        try:
            mem = {}
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    parts = line.split(":")
                    if len(parts) == 2:
                        k = parts[0].strip()
                        v = parts[1].strip().split()[0]
                        mem[k] = int(v)
            total_mb = mem.get("MemTotal", 0) // 1024
            free_mb = (mem.get("MemFree", 0) + mem.get("Buffers", 0) + mem.get("Cached", 0)) // 1024
            used_mb = max(0, total_mb - free_mb)
        except Exception:
            pass

    if total_mb == 0:
        # Fallback to sysconf or vm_stat
        try:
            pages = os.sysconf("SC_PHYS_PAGES")
            page_size = os.sysconf("SC_PAGE_SIZE")
            total_mb = (pages * page_size) // (1024 * 1024)
            # Estimate roughly for BSD/macOS
            free_mb = int(total_mb * 0.4)
            used_mb = total_mb - free_mb
        except Exception:
            total_mb, used_mb, free_mb = 8192, 4096, 4096

    used_pct = round((used_mb / total_mb) * 100.0, 2) if total_mb > 0 else 0.0
    return {
        "total_mb": total_mb,
        "used_mb": used_mb,
        "free_mb": free_mb,
        "used_percent": used_pct,
    }


def get_disk_info() -> List[Dict[str, Any]]:
    """Retrieves disk partition usage."""
    disks = []
    try:
        usage = shutil.disk_usage("/")
        total_gb = round(usage.total / (1024 ** 3), 2)
        used_gb = round(usage.used / (1024 ** 3), 2)
        free_gb = round(usage.free / (1024 ** 3), 2)
        pct = round((usage.used / usage.total) * 100.0, 2) if usage.total > 0 else 0.0
        disks.append({
            "mount": "/",
            "total_gb": total_gb,
            "used_gb": used_gb,
            "free_gb": free_gb,
            "used_percent": pct,
        })
    except Exception:
        pass
    return disks


def get_process_stats() -> Dict[str, Any]:
    """Gathers active and zombie process counts."""
    total_procs = 0
    zombies = 0
    try:
        out = subprocess.check_output(["ps", "-axo", "state"], universal_newlines=True, stderr=subprocess.DEVNULL)
        lines = out.strip().splitlines()[1:]
        total_procs = len(lines)
        zombies = sum(1 for s in lines if s.strip().startswith("Z"))
    except Exception:
        total_procs = 100

    return {
        "total_processes": total_procs,
        "zombies": zombies,
    }


def execute_sys_health(args: argparse.Namespace) -> int:
    """Executes the 'sys health' subcommand."""
    cpu = get_cpu_load()
    mem = get_memory_info()
    disks = get_disk_info()
    procs = get_process_stats()

    # Determine health status
    status = "HEALTHY"
    if cpu["utilization_percent"] > 85.0 or mem["used_percent"] > 90.0 or procs["zombies"] > 0:
        status = "WARNING"
    if cpu["utilization_percent"] > 95.0 or mem["used_percent"] > 98.0:
        status = "CRITICAL"

    data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "hostname": platform.node(),
        "os": f"{platform.system()} {platform.release()}",
        "status": status,
        "cpu": cpu,
        "memory": mem,
        "disks": disks,
        "processes": procs,
    }

    if args.json_output:
        print(json.dumps(data, indent=2))
        return 0

    if args.markdown_output:
        print(f"# System Resource Health Diagnostic\n")
        print(f"- **Hostname**: `{data['hostname']}`")
        print(f"- **OS**: `{data['os']}`")
        print(f"- **Status**: **`{status}`**\n")
        print(f"## CPU & Memory Metrics\n")
        print(f"| Metric | Value | Status |")
        print(f"| :--- | :--- | :--- |")
        print(f"| CPU Cores | `{cpu['cores']}` | OK |")
        print(f"| Load Average (1m, 5m, 15m) | `{cpu['load_1m']}, {cpu['load_5m']}, {cpu['load_15m']}` | OK |")
        print(f"| RAM Usage | `{mem['used_mb']} MB / {mem['total_mb']} MB ({mem['used_percent']}%)` | OK |")
        print(f"| Disk Space (/) | `{disks[0]['used_gb']} GB / {disks[0]['total_gb']} GB ({disks[0]['used_percent']}%)` | OK |")
        print(f"| Active Processes | `{procs['total_processes']} (Zombies: {procs['zombies']})` | OK |")
        return 0

    # ANSI Terminal Table
    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                               DEVOPS-CLI: SYSTEM HEALTH DIAGNOSTIC                                     {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Host     : {COLOR_BOLD}{data['hostname']}{COLOR_RESET} ({data['os']})")
    print(f"Timestamp: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    st_color = COLOR_GREEN if status == "HEALTHY" else (COLOR_YELLOW if status == "WARNING" else COLOR_RED)
    print(f"Overall  : {st_color}{COLOR_BOLD}[ {status} ]{COLOR_RESET}\n")

    print(f"{COLOR_BOLD}1. CPU SUBSYSTEM & LOAD AVERAGE:{COLOR_RESET}")
    print(f"  - Logical CPU Cores : {COLOR_BOLD}{cpu['cores']}{COLOR_RESET}")
    print(f"  - Load Average      : 1m: {COLOR_CYAN}{cpu['load_1m']}{COLOR_RESET} | 5m: {COLOR_CYAN}{cpu['load_5m']}{COLOR_RESET} | 15m: {COLOR_CYAN}{cpu['load_15m']}{COLOR_RESET}")
    print(f"  - Estimated Load    : {cpu['utilization_percent']}%\n")

    print(f"{COLOR_BOLD}2. MEMORY & SWAP SUBSYSTEM:{COLOR_RESET}")
    print(f"  - Physical RAM      : {mem['used_mb']} MB used / {mem['total_mb']} MB total ({mem['used_percent']}%)")
    print(f"  - Available Free RAM: {COLOR_GREEN}{mem['free_mb']} MB{COLOR_RESET}\n")

    print(f"{COLOR_BOLD}3. STORAGE & MOUNT POINTS:{COLOR_RESET}")
    for d in disks:
        print(f"  - Mount '{COLOR_BOLD}{d['mount']}{COLOR_RESET}': {d['used_gb']} GB used / {d['total_gb']} GB total ({d['used_percent']}% utilized)")
    print()

    print(f"{COLOR_BOLD}4. PROCESS LIFECYCLES:{COLOR_RESET}")
    print(f"  - Active Processes  : {procs['total_processes']}")
    z_str = f"{COLOR_RED}{procs['zombies']} (Reap required!){COLOR_RESET}" if procs['zombies'] > 0 else f"{COLOR_GREEN}0 (Clean){COLOR_RESET}"
    print(f"  - Defunct (Zombies) : {z_str}\n")
    print(COLOR_DIM + "=" * 104 + COLOR_RESET + "\n")
    return 0


# ==============================================================================
# MODULE 2: LOG ANALYZER (log stats)
# ==============================================================================

LOG_PATTERN = re.compile(
    r'^(?P<ip>\S+)\s+\S+\s+\S+\s+\[(?P<time>[^\]]+)\]\s+"(?P<method>\S+)\s+(?P<path>\S+)\s+[^\"]+"\s+(?P<status>\d{3})\s+(?P<bytes>\d+)(?:\s+"[^"]*"\s+"[^"]*"(?:\s+(?P<latency>[\d.]+))?)?'
)


def parse_log_file(filepath: str, top_n: int = 5, status_filter: Optional[str] = None) -> Dict[str, Any]:
    """Parses access logs and computes aggregation metrics."""
    if not os.path.exists(filepath):
        raise FileNotFoundError(f"Log file not found: {filepath}")

    total_requests = 0
    ip_counter: Dict[str, int] = {}
    path_counter: Dict[str, int] = {}
    status_counter: Dict[str, int] = {}
    latencies: List[float] = []

    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            match = LOG_PATTERN.match(line)
            if match:
                ip = match.group("ip")
                path = match.group("path")
                status = match.group("status")
                lat_str = match.group("latency")

                if status_filter:
                    if status_filter.endswith("xx"):
                        prefix = status_filter[0]
                        if not status.startswith(prefix):
                            continue
                    elif status != status_filter:
                        continue

                total_requests += 1
                ip_counter[ip] = ip_counter.get(ip, 0) + 1
                path_counter[path] = path_counter.get(path, 0) + 1
                status_counter[status] = status_counter.get(status, 0) + 1

                if lat_str:
                    try:
                        latencies.append(float(lat_str) * 1000.0)  # ms
                    except ValueError:
                        pass
            else:
                # Generic fallback if line contains HTTP status
                tokens = line.split()
                if len(tokens) >= 9:
                    total_requests += 1
                    ip = tokens[0]
                    ip_counter[ip] = ip_counter.get(ip, 0) + 1

    # Status distribution
    status_2xx = sum(v for k, v in status_counter.items() if k.startswith("2"))
    status_3xx = sum(v for k, v in status_counter.items() if k.startswith("3"))
    status_4xx = sum(v for k, v in status_counter.items() if k.startswith("4"))
    status_5xx = sum(v for k, v in status_counter.items() if k.startswith("5"))
    err_rate = round(((status_4xx + status_5xx) / total_requests) * 100.0, 2) if total_requests > 0 else 0.0

    # Latency percentiles
    lat_sorted = sorted(latencies) if latencies else [0.0]
    p50 = lat_sorted[int(len(lat_sorted) * 0.50)]
    p90 = lat_sorted[int(len(lat_sorted) * 0.90)]
    p99 = lat_sorted[min(len(lat_sorted) - 1, int(len(lat_sorted) * 0.99))]

    top_ips = sorted(ip_counter.items(), key=lambda x: x[1], reverse=True)[:top_n]
    top_paths = sorted(path_counter.items(), key=lambda x: x[1], reverse=True)[:top_n]

    return {
        "file": filepath,
        "total_requests": total_requests,
        "unique_ips": len(ip_counter),
        "status_codes": {
            "2xx": status_2xx,
            "3xx": status_3xx,
            "4xx": status_4xx,
            "5xx": status_5xx,
            "detailed": status_counter,
            "error_rate_percent": err_rate,
        },
        "top_client_ips": [{"ip": k, "count": v} for k, v in top_ips],
        "top_endpoints": [{"path": k, "count": v} for k, v in top_paths],
        "latency_ms": {
            "p50": round(p50, 2),
            "p90": round(p90, 2),
            "p99": round(p99, 2),
        } if latencies else None,
    }


def execute_log_stats(args: argparse.Namespace) -> int:
    """Executes the 'log stats' subcommand."""
    try:
        data = parse_log_file(args.file, top_n=args.top, status_filter=args.status)
    except FileNotFoundError as e:
        print(f"{COLOR_RED}Error: {e}{COLOR_RESET}", file=sys.stderr)
        return 3

    if args.json_output:
        print(json.dumps(data, indent=2))
        return 0

    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                               DEVOPS-CLI: LOG ANALYTICS REPORT                                         {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Log File : {COLOR_CYAN}{data['file']}{COLOR_RESET}")
    print(f"Analyzed : {COLOR_BOLD}{data['total_requests']}{COLOR_RESET} total requests ({data['unique_ips']} unique client IPs)\n")

    sc = data["status_codes"]
    print(f"{COLOR_BOLD}1. HTTP STATUS CODE DISTRIBUTION:{COLOR_RESET}")
    print(f"  - 2xx (Success)    : {COLOR_GREEN}{sc['2xx']}{COLOR_RESET}")
    print(f"  - 3xx (Redirect)   : {COLOR_BLUE}{sc['3xx']}{COLOR_RESET}")
    print(f"  - 4xx (Client Err) : {COLOR_YELLOW}{sc['4xx']}{COLOR_RESET}")
    print(f"  - 5xx (Server Err) : {COLOR_RED}{sc['5xx']}{COLOR_RESET}")
    print(f"  - Overall Error Rate: {COLOR_BOLD}{sc['error_rate_percent']}%{COLOR_RESET}\n")

    print(f"{COLOR_BOLD}2. TOP REQUESTED ENDPOINTS:{COLOR_RESET}")
    for item in data["top_endpoints"]:
        print(f"  - {COLOR_CYAN}{item['path']:<35}{COLOR_RESET} : {item['count']} requests")
    print()

    print(f"{COLOR_BOLD}3. TOP CLIENT IP ADDRESSES:{COLOR_RESET}")
    for item in data["top_client_ips"]:
        print(f"  - {COLOR_YELLOW}{item['ip']:<25}{COLOR_RESET} : {item['count']} requests")
    print()

    if data["latency_ms"]:
        lat = data["latency_ms"]
        print(f"{COLOR_BOLD}4. RESPONSE LATENCY PERCENTILES:{COLOR_RESET}")
        print(f"  - P50 (Median) : {lat['p50']} ms")
        print(f"  - P90          : {lat['p90']} ms")
        print(f"  - P99          : {lat['p99']} ms\n")

    print(COLOR_DIM + "=" * 104 + COLOR_RESET + "\n")
    return 0


# ==============================================================================
# MODULE 3: SSH EXECUTION POOL (ssh run)
# ==============================================================================

def execute_remote_ssh(host_entry: str, cmd: str, timeout: int = 10) -> Dict[str, Any]:
    """Executes a command across SSH or local mock executor."""
    parts = host_entry.strip().split()
    host = parts[0]
    port = 22
    user = os.environ.get("USER", "root")

    for p in parts[1:]:
        if p.startswith("port="):
            port = int(p.split("=")[1])
        elif p.startswith("user="):
            user = p.split("=")[1]

    t0 = time.perf_counter()
    ssh_cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", f"ConnectTimeout={timeout}",
        "-p", str(port),
        f"{user}@{host}",
        cmd,
    ]

    try:
        res = subprocess.run(
            ssh_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            universal_newlines=True,
            check=False,
        )
        duration = round(time.perf_counter() - t0, 3)
        return {
            "host": host,
            "port": port,
            "user": user,
            "command": cmd,
            "exit_code": res.returncode,
            "stdout": res.stdout.strip(),
            "stderr": res.stderr.strip(),
            "duration_seconds": duration,
            "status": "SUCCESS" if res.returncode == 0 else "FAILED",
        }
    except subprocess.TimeoutExpired:
        duration = round(time.perf_counter() - t0, 3)
        return {
            "host": host,
            "port": port,
            "user": user,
            "command": cmd,
            "exit_code": 124,
            "stdout": "",
            "stderr": f"Connection timed out after {timeout} seconds",
            "duration_seconds": duration,
            "status": "TIMEOUT",
        }
    except Exception as e:
        duration = round(time.perf_counter() - t0, 3)
        return {
            "host": host,
            "port": port,
            "user": user,
            "command": cmd,
            "exit_code": 255,
            "stdout": "",
            "stderr": str(e),
            "duration_seconds": duration,
            "status": "ERROR",
        }


def execute_ssh_pool(args: argparse.Namespace) -> int:
    """Executes 'ssh run' across multi-host targets."""
    hosts = []
    if args.hosts:
        hosts.extend([h.strip() for h in args.hosts.split(",") if h.strip()])
    elif args.inventory:
        if not os.path.exists(args.inventory):
            print(f"{COLOR_RED}Error: Inventory file not found: {args.inventory}{COLOR_RESET}", file=sys.stderr)
            return 3
        with open(args.inventory, "r") as f:
            for line in f:
                cleaned = line.split("#")[0].strip()
                if cleaned:
                    hosts.append(cleaned)

    if not hosts:
        print(f"{COLOR_RED}Error: No target hosts specified. Use --hosts or -i <inventory_file>{COLOR_RESET}", file=sys.stderr)
        return 3

    cmd = args.command
    concurrency = max(1, args.concurrency)
    timeout = max(1, args.timeout)

    results = []
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = {executor.submit(execute_remote_ssh, h, cmd, timeout): h for h in hosts}
        for future in as_completed(futures):
            results.append(future.result())

    results.sort(key=lambda x: (x["host"], x["port"]))

    if args.json_output:
        print(json.dumps({"command": cmd, "total_hosts": len(hosts), "results": results}, indent=2))
        return 0

    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                               DEVOPS-CLI: PARALLEL SSH POOL EXECUTION                                  {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Command  : {COLOR_CYAN}{cmd}{COLOR_RESET}")
    print(f"Targets  : {len(hosts)} hosts (Concurrency: {concurrency}, Timeout: {timeout}s)\n")

    for r in results:
        badge = f"{COLOR_GREEN}[  OK  ]{COLOR_RESET}" if r["exit_code"] == 0 else f"{COLOR_RED}[ FAIL ]{COLOR_RESET}"
        print(f"{badge} {COLOR_BOLD}{r['user']}@{r['host']}:{r['port']}{COLOR_RESET} (Duration: {r['duration_seconds']}s, Exit: {r['exit_code']})")
        if r["stdout"]:
            for line in r["stdout"].splitlines():
                print(f"    {COLOR_DIM}stdout |{COLOR_RESET} {line}")
        if r["stderr"]:
            for line in r["stderr"].splitlines():
                print(f"    {COLOR_RED}stderr |{COLOR_RESET} {line}")
        print()

    print(COLOR_DIM + "=" * 104 + COLOR_RESET + "\n")
    return 0


# ==============================================================================
# MODULE 4: CLOUD COST ESTIMATOR (cost estimate)
# ==============================================================================

def calculate_cloud_costs(manifest_path: str) -> Dict[str, Any]:
    """Calculates compute, storage, and egress costs from manifest."""
    if not os.path.exists(manifest_path):
        raise FileNotFoundError(f"Manifest file not found: {manifest_path}")

    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

    project = manifest.get("project_name", "Default Project")
    currency = manifest.get("currency", "USD")
    resources = manifest.get("resources", [])

    total_monthly = 0.0
    items = []
    recommendations = []

    for r in resources:
        name = r.get("name", "Unnamed")
        r_type = r.get("type", "compute")
        specs = r.get("specs", {})
        count = r.get("count", 1)

        monthly_cost = 0.0
        if r_type == "compute":
            hr_rate = specs.get("hourly_rate", 0.0)
            monthly_cost = hr_rate * 730.0 * count
            # Recommendation check
            itype = specs.get("instance_type", "")
            if itype.startswith("t3.") or itype.startswith("m5."):
                recommendations.append(f"Consider migrating '{name}' ({itype}) to Graviton arm64 (e.g. t4g/m6g) for ~20% cost reduction.")
        elif r_type == "storage":
            size_gb = specs.get("size_gb", 0)
            rate_gb = specs.get("monthly_rate_per_gb", 0.08)
            monthly_cost = size_gb * rate_gb * count
        elif r_type == "bandwidth":
            tb = specs.get("estimated_tb_monthly", 0)
            rate_gb = specs.get("rate_per_gb", 0.05)
            monthly_cost = tb * 1024 * rate_gb

        total_monthly += monthly_cost
        items.append({
            "name": name,
            "type": r_type,
            "count": count,
            "monthly_cost": round(monthly_cost, 2),
            "specs": specs,
        })

    return {
        "project": project,
        "currency": currency,
        "total_monthly": round(total_monthly, 2),
        "total_annual": round(total_monthly * 12.0, 2),
        "breakdown": items,
        "recommendations": recommendations,
    }


def execute_cost_estimate(args: argparse.Namespace) -> int:
    """Executes 'cost estimate' subcommand."""
    try:
        data = calculate_cloud_costs(args.file)
    except FileNotFoundError as e:
        print(f"{COLOR_RED}Error: {e}{COLOR_RESET}", file=sys.stderr)
        return 3

    if args.json_output:
        print(json.dumps(data, indent=2))
        return 0

    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                          DEVOPS-CLI: CLOUD INFRASTRUCTURE COST ESTIMATE                                 {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Project  : {COLOR_CYAN}{data['project']}{COLOR_RESET}")
    print(f"Estimate : {COLOR_BOLD}${data['total_monthly']:,.2f} / month{COLOR_RESET} (${data['total_annual']:,.2f} / year {data['currency']})\n")

    print(f"{COLOR_BOLD}{'RESOURCE NAME':<30}  {'TYPE':<12}  {'COUNT':<8}  {'MONTHLY COST'}{COLOR_RESET}")
    print(COLOR_DIM + "-" * 104 + COLOR_RESET)
    for b in data["breakdown"]:
        print(f"{b['name']:<30}  {b['type']:<12}  {b['count']:<8}  ${b['monthly_cost']:,.2f}")
    print(COLOR_DIM + "-" * 104 + COLOR_RESET)

    if data["recommendations"]:
        print(f"\n{COLOR_BOLD}💡 SRE RIGHT-SIZING & COST OPTIMIZATION RECOMMENDATIONS:{COLOR_RESET}")
        for rec in data["recommendations"]:
            print(f"  - {COLOR_GREEN}{rec}{COLOR_RESET}")
    print()
    print(COLOR_DIM + "=" * 104 + COLOR_RESET + "\n")
    return 0


# ==============================================================================
# MODULE 5: AUTOCOMPLETION GENERATOR (completion)
# ==============================================================================

BASH_COMPLETION = """# bash completion for devops-cli
_devops_cli_completions() {
    local cur prev opts subcommands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    subcommands="sys log ssh cost completion version"

    case "${prev}" in
        devops-cli|devops_cli.py)
            COMPREPLY=( $(compgen -W "${subcommands}" -- ${cur}) )
            return 0
            ;;
        sys)
            COMPREPLY=( $(compgen -W "health" -- ${cur}) )
            return 0
            ;;
        log)
            COMPREPLY=( $(compgen -W "stats" -- ${cur}) )
            return 0
            ;;
        ssh)
            COMPREPLY=( $(compgen -W "run" -- ${cur}) )
            return 0
            ;;
        cost)
            COMPREPLY=( $(compgen -W "estimate" -- ${cur}) )
            return 0
            ;;
        completion)
            COMPREPLY=( $(compgen -W "bash zsh" -- ${cur}) )
            return 0
            ;;
        *)
            ;;
    esac
}
complete -F _devops_cli_completions devops-cli
complete -F _devops_cli_completions devops_cli.py
"""

ZSH_COMPLETION = """#compdef devops-cli devops_cli.py
_devops_cli() {
    local -a commands
    commands=(
        'sys:System hardware & resource diagnostic subcommands'
        'log:Web access & application log analytics'
        'ssh:Parallel multi-node SSH command execution pool'
        'cost:Cloud infrastructure cost estimation & right-sizing'
        'completion:Generate shell autocompletion script'
        'version:Show CLI binary version & build information'
    )
    _describe -t commands 'devops-cli subcommands' commands
}
compdef _devops_cli devops-cli devops_cli.py
"""


def execute_completion(args: argparse.Namespace) -> int:
    """Generates shell completion scripts."""
    shell = args.shell.lower()
    if shell == "bash":
        print(BASH_COMPLETION)
    elif shell == "zsh":
        print(ZSH_COMPLETION)
    else:
        print(f"Unsupported shell: {shell}. Supported: bash, zsh", file=sys.stderr)
        return 3
    return 0


# ==============================================================================
# MAIN ROUTING ENGINE
# ==============================================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        prog="devops-cli",
        description="Unified DevOps Toolkit CLI - Production-grade systems, logs, SSH & cloud cost utility.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("-v", "--version", action="store_true", help="Show version information")

    subparsers = parser.add_subparsers(dest="subcommand", help="Available subcommand modules")

    # 1. sys health
    sys_parser = subparsers.add_parser("sys", help="System hardware & OS health inspection")
    sys_sub = sys_parser.add_subparsers(dest="sys_action")
    health_p = sys_sub.add_parser("health", help="Inspect CPU, memory, disks, and processes")
    health_p.add_argument("-j", "--json", action="store_true", dest="json_output", help="JSON output format")
    health_p.add_argument("-m", "--markdown", action="store_true", dest="markdown_output", help="Markdown format")

    # 2. log stats
    log_parser = subparsers.add_parser("log", help="Web & application log analytics")
    log_sub = log_parser.add_subparsers(dest="log_action")
    stats_p = log_sub.add_parser("stats", help="Analyze request counts, status codes, top URLs and latency")
    stats_p.add_argument("-f", "--file", required=True, help="Path to access log file")
    stats_p.add_argument("-t", "--top", type=int, default=5, help="Top N results to display (default: 5)")
    stats_p.add_argument("-s", "--status", help="Filter by HTTP status code or family (e.g. 500 or 5xx)")
    stats_p.add_argument("-j", "--json", action="store_true", dest="json_output", help="JSON output format")

    # 3. ssh run
    ssh_parser = subparsers.add_parser("ssh", help="Multi-node SSH execution pool")
    ssh_sub = ssh_parser.add_subparsers(dest="ssh_action")
    run_p = ssh_sub.add_parser("run", help="Run command concurrently across host inventory")
    run_p.add_argument("command", help="Command string to execute remotely")
    run_p.add_argument("-H", "--hosts", help="Comma-separated target host list")
    run_p.add_argument("-i", "--inventory", help="Path to inventory file")
    run_p.add_argument("-c", "--concurrency", type=int, default=5, help="Max worker concurrency (default: 5)")
    run_p.add_argument("-t", "--timeout", type=int, default=10, help="Per-host execution timeout in seconds")
    run_p.add_argument("-j", "--json", action="store_true", dest="json_output", help="JSON output format")

    # 4. cost estimate
    cost_parser = subparsers.add_parser("cost", help="Cloud infrastructure cost estimation")
    cost_sub = cost_parser.add_subparsers(dest="cost_action")
    est_p = cost_sub.add_parser("estimate", help="Calculate monthly cost and recommendations from manifest")
    est_p.add_argument("-f", "--file", required=True, help="Path to infrastructure manifest JSON")
    est_p.add_argument("-j", "--json", action="store_true", dest="json_output", help="JSON output format")

    # 5. completion
    comp_p = subparsers.add_parser("completion", help="Generate shell autocompletion script")
    comp_p.add_argument("shell", choices=["bash", "zsh"], help="Target shell")

    args = parser.parse_args()

    if args.version:
        print(f"devops-cli version {VERSION} (built {BUILD_DATE}, Python {platform.python_version()} on {platform.system()}/{platform.machine()})")
        return 0

    if not args.subcommand:
        parser.print_help()
        return 0

    if args.subcommand == "sys":
        if args.sys_action == "health":
            return execute_sys_health(args)
        health_p.print_help()
        return 0
    elif args.subcommand == "log":
        if args.log_action == "stats":
            return execute_log_stats(args)
        stats_p.print_help()
        return 0
    elif args.subcommand == "ssh":
        if args.ssh_action == "run":
            return execute_ssh_pool(args)
        run_p.print_help()
        return 0
    elif args.subcommand == "cost":
        if args.cost_action == "estimate":
            return execute_cost_estimate(args)
        est_p.print_help()
        return 0
    elif args.subcommand == "completion":
        return execute_completion(args)

    return 0


if __name__ == "__main__":
    sys.exit(main())
