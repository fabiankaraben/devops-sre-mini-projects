#!/usr/bin/env python3
"""
==============================================================================
memory_hog.py - Container Resource Constraints & OOM Profiling Engine
==============================================================================
Educational memory and CPU allocation tool designed to observe Linux cgroups v2
behavior, CFS CPU throttling, and kernel Out-Of-Memory (OOM) killer mechanics.

Modes:
  - oom:   Gradually allocates memory chunks until the kernel OOM-killer triggers
  - safe:  Allocates memory within configured safety margins and exits cleanly (code 0)
  - hold:  Allocates target memory and maintains it for real-time inspection
  - cpu:   Executes CPU-bound computations across threads to observe CFS throttling
  - inspect: Reads and outputs current cgroups v1/v2 metrics without allocating
==============================================================================
"""

import argparse
import math
import os
import signal
import sys
import threading
import time
from typing import Any, Dict, Optional, Tuple

# ANSI Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_RED = "\033[1;31m"
CLR_GREEN = "\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE = "\033[1;34m"
CLR_MAGENTA = "\033[1;35m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


def read_file_safe(path: str) -> Optional[str]:
    """Safely read content from a virtual filesystem path."""
    try:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                return f.read().strip()
    except Exception:
        pass
    return None


def get_cgroup_version() -> int:
    """Detect whether host/container is using cgroups v2 or v1."""
    if os.path.exists("/sys/fs/cgroup/memory.current"):
        return 2
    if os.path.exists("/sys/fs/cgroup/memory/memory.usage_in_bytes"):
        return 1
    return 2 if os.path.exists("/sys/fs/cgroup/cgroup.controllers") else 0


def get_process_rss_mb() -> float:
    """Read Resident Set Size (RSS) from /proc/self/status or resource module."""
    status = read_file_safe("/proc/self/status")
    if status:
        for line in status.splitlines():
            if line.startswith("VmRSS:"):
                parts = line.split()
                if len(parts) >= 2:
                    kb = float(parts[1])
                    return kb / 1024.0
    return 0.0


def read_cgroup_memory_stats() -> Dict[str, Any]:
    """Inspect Linux cgroup memory parameters."""
    v = get_cgroup_version()
    stats: Dict[str, Any] = {
        "version": v,
        "current_bytes": 0,
        "current_mb": 0.0,
        "limit_bytes": 0,
        "limit_mb": 0.0,
        "limit_str": "unlimited",
        "oom_kills": 0,
        "high_throttles": 0,
        "max_events": 0,
        "swap_current_bytes": 0,
        "swap_current_mb": 0.0,
        "swap_limit_bytes": 0,
        "swap_limit_mb": 0.0,
    }

    if v == 2:
        # Cgroup v2 metrics
        current_raw = read_file_safe("/sys/fs/cgroup/memory.current")
        if current_raw and current_raw.isdigit():
            stats["current_bytes"] = int(current_raw)
            stats["current_mb"] = stats["current_bytes"] / (1024 * 1024)

        max_raw = read_file_safe("/sys/fs/cgroup/memory.max")
        if max_raw:
            if max_raw.isdigit():
                stats["limit_bytes"] = int(max_raw)
                stats["limit_mb"] = stats["limit_bytes"] / (1024 * 1024)
                stats["limit_str"] = f"{stats['limit_mb']:.1f} MB"
            else:
                stats["limit_str"] = "max (unlimited)"

        events_raw = read_file_safe("/sys/fs/cgroup/memory.events")
        if events_raw:
            for line in events_raw.splitlines():
                parts = line.split()
                if len(parts) == 2:
                    k, val = parts[0], parts[1]
                    if k == "oom_kill" and val.isdigit():
                        stats["oom_kills"] = int(val)
                    elif k == "high" and val.isdigit():
                        stats["high_throttles"] = int(val)
                    elif k == "max" and val.isdigit():
                        stats["max_events"] = int(val)

        swap_current = read_file_safe("/sys/fs/cgroup/memory.swap.current")
        if swap_current and swap_current.isdigit():
            stats["swap_current_bytes"] = int(swap_current)
            stats["swap_current_mb"] = stats["swap_current_bytes"] / (1024 * 1024)

        swap_max = read_file_safe("/sys/fs/cgroup/memory.swap.max")
        if swap_max and swap_max.isdigit():
            stats["swap_limit_bytes"] = int(swap_max)
            stats["swap_limit_mb"] = stats["swap_limit_bytes"] / (1024 * 1024)

    elif v == 1:
        # Cgroup v1 fallback
        usage_raw = read_file_safe("/sys/fs/cgroup/memory/memory.usage_in_bytes")
        if usage_raw and usage_raw.isdigit():
            stats["current_bytes"] = int(usage_raw)
            stats["current_mb"] = stats["current_bytes"] / (1024 * 1024)

        limit_raw = read_file_safe("/sys/fs/cgroup/memory/memory.limit_in_bytes")
        if limit_raw and limit_raw.isdigit():
            lim = int(limit_raw)
            # Linux kernel uses ~ 0x7FFFFFFFFFFFF000 (9223372036854771712) for unlimited in v1
            if lim > (1 << 50):
                stats["limit_str"] = "unlimited"
            else:
                stats["limit_bytes"] = lim
                stats["limit_mb"] = lim / (1024 * 1024)
                stats["limit_str"] = f"{stats['limit_mb']:.1f} MB"

        failcnt = read_file_safe("/sys/fs/cgroup/memory/memory.failcnt")
        if failcnt and failcnt.isdigit():
            stats["max_events"] = int(failcnt)

    return stats


def read_cgroup_cpu_stats() -> Dict[str, Any]:
    """Inspect Linux cgroup CPU quota and throttling parameters."""
    v = get_cgroup_version()
    stats: Dict[str, Any] = {
        "version": v,
        "quota_us": -1,
        "period_us": 100000,
        "effective_cpus": 0.0,
        "nr_periods": 0,
        "nr_throttled": 0,
        "throttled_usec": 0,
        "throttle_pct": 0.0,
    }

    if v == 2:
        cpu_max = read_file_safe("/sys/fs/cgroup/cpu.max")
        if cpu_max:
            parts = cpu_max.split()
            if len(parts) >= 2:
                quota_str, period_str = parts[0], parts[1]
                if period_str.isdigit():
                    stats["period_us"] = int(period_str)
                if quota_str.isdigit():
                    stats["quota_us"] = int(quota_str)
                    stats["effective_cpus"] = stats["quota_us"] / float(stats["period_us"])
                else:
                    stats["effective_cpus"] = float(os.cpu_count() or 1)

        cpu_stat = read_file_safe("/sys/fs/cgroup/cpu.stat")
        if cpu_stat:
            for line in cpu_stat.splitlines():
                parts = line.split()
                if len(parts) == 2:
                    k, val = parts[0], parts[1]
                    if k == "nr_periods" and val.isdigit():
                        stats["nr_periods"] = int(val)
                    elif k == "nr_throttled" and val.isdigit():
                        stats["nr_throttled"] = int(val)
                    elif k == "throttled_usec" and val.isdigit():
                        stats["throttled_usec"] = int(val)

    elif v == 1:
        quota = read_file_safe("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
        period = read_file_safe("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
        if period and period.isdigit():
            stats["period_us"] = int(period)
        if quota and (quota.isdigit() or (quota.startswith("-") and quota[1:].isdigit())):
            stats["quota_us"] = int(quota)
            if stats["quota_us"] > 0:
                stats["effective_cpus"] = stats["quota_us"] / float(stats["period_us"])
            else:
                stats["effective_cpus"] = float(os.cpu_count() or 1)

        cpu_stat = read_file_safe("/sys/fs/cgroup/cpu/cpu.stat")
        if cpu_stat:
            for line in cpu_stat.splitlines():
                parts = line.split()
                if len(parts) == 2:
                    k, val = parts[0], parts[1]
                    if k == "nr_periods" and val.isdigit():
                        stats["nr_periods"] = int(val)
                    elif k == "nr_throttled" and val.isdigit():
                        stats["nr_throttled"] = int(val)
                    elif k == "throttled_time" and val.isdigit():
                        stats["throttled_usec"] = int(val) // 1000

    if stats["nr_periods"] > 0:
        stats["throttle_pct"] = (stats["nr_throttled"] / float(stats["nr_periods"])) * 100.0

    return stats


def print_banner(mode: str) -> None:
    """Print educational startup banner."""
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 75}{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🧪 Container Resource Constraints & OOM Profiling Engine{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 75}{CLR_RESET}")
    print(f"  PID:             {os.getpid()}")
    print(f"  UID / GID:       {os.getuid()} / {os.getgid()}")
    print(f"  Host / Hostname: {os.uname().nodename}")
    print(f"  Cgroup Version:  v{get_cgroup_version()}")
    print(f"  Execution Mode:  {CLR_YELLOW}{mode.upper()}{CLR_RESET}")
    print(f"{CLR_CYAN}{'-' * 75}{CLR_RESET}")
    sys.stdout.flush()


def print_cgroup_environment() -> None:
    """Log discovered cgroup limits."""
    mem_stats = read_cgroup_memory_stats()
    cpu_stats = read_cgroup_cpu_stats()

    print(f"{CLR_BOLD}⚙️  Discovered Resource Constraints:{CLR_RESET}")
    print(f"  • Memory Limit:      {CLR_GREEN}{mem_stats['limit_str']}{CLR_RESET}")
    if mem_stats["swap_limit_bytes"] > 0:
        print(f"  • Swap Limit:        {mem_stats['swap_limit_mb']:.1f} MB")
    print(f"  • CPU CFS Quota:     {cpu_stats['quota_us']} µs / {cpu_stats['period_us']} µs ({cpu_stats['effective_cpus']:.2f} CPUs)")
    print(f"  • Initial RSS:       {get_process_rss_mb():.2f} MB")
    print(f"  • Initial Cgroup:    {mem_stats['current_mb']:.2f} MB")
    print(f"{CLR_CYAN}{'-' * 75}{CLR_RESET}")
    sys.stdout.flush()


def run_inspect_mode() -> None:
    """Inspect and print complete cgroups v1/v2 metrics."""
    print_banner("inspect")
    print_cgroup_environment()
    mem_stats = read_cgroup_memory_stats()
    cpu_stats = read_cgroup_cpu_stats()

    print(f"{CLR_BOLD}📊 Detailed Cgroup Diagnostic Dump:{CLR_RESET}")
    for k, v in mem_stats.items():
        print(f"  memory.{k:20s}: {v}")
    for k, v in cpu_stats.items():
        print(f"  cpu.{k:23s}: {v}")
    print(f"{CLR_CYAN}{'=' * 75}{CLR_RESET}")


def run_memory_allocation(
    mode: str,
    chunk_size_mb: int,
    delay: float,
    target_mb: Optional[int] = None,
    hold_time: int = 30,
) -> None:
    """
    Gradually allocate memory chunks and write data to physical pages.
    
    Writing bytes directly to memory is critical: modern Linux kernels use
    optimistic memory allocation (overcommit) and lazy page allocation.
    Simply creating empty structures or sparse allocations will not fault
    pages into physical RSS until written.
    """
    print_banner(mode)
    print_cgroup_environment()

    buffers = []
    total_allocated_mb = 0
    iteration = 0
    chunk_bytes = chunk_size_mb * 1024 * 1024

    mem_stats = read_cgroup_memory_stats()
    limit_mb = mem_stats["limit_mb"] if mem_stats["limit_mb"] > 0 else float("inf")

    print(f"{CLR_BOLD}🚀 Starting memory allocation workflow...{CLR_RESET}")
    if mode == "oom":
        print(f"  Target: Intentionally trigger Kernel OOM-Killer when exceeding limit ({mem_stats['limit_str']})")
    elif mode == "safe":
        print(f"  Target: Safely allocate up to {target_mb} MB (Limit: {mem_stats['limit_str']}) and exit cleanly")
    elif mode == "hold":
        print(f"  Target: Allocate {target_mb} MB and hold memory for {hold_time}s to allow inspection")

    print(f"{CLR_GRAY}{'Iter':<6} {'Allocated':<12} {'Process RSS':<14} {'Cgroup Usage':<15} {'Cgroup Limit':<14} {'Bar / Status'}{CLR_RESET}")
    print(f"{CLR_GRAY}{'-' * 75}{CLR_RESET}")
    sys.stdout.flush()

    try:
        while True:
            iteration += 1

            # Check safe/hold mode termination criteria
            if target_mb is not None and total_allocated_mb >= target_mb:
                print(f"{CLR_GREEN}✔ Target allocation of {target_mb} MB reached safely.{CLR_RESET}")
                if mode == "hold":
                    print(f"{CLR_YELLOW}⏳ Holding {total_allocated_mb} MB in RAM for {hold_time} seconds (press Ctrl+C to stop)...{CLR_RESET}")
                    start_hold = time.time()
                    while time.time() - start_hold < hold_time:
                        time.sleep(1)
                print(f"{CLR_GREEN}✨ Workflow finished successfully without triggering OOM.{CLR_RESET}")
                sys.exit(0)

            # Allocate and physically touch memory pages
            # Writing bytes ensures kernel allocates actual anonymous RSS pages
            data = bytearray(b"X" * chunk_bytes)
            buffers.append(data)
            total_allocated_mb += chunk_size_mb

            # Read metrics
            rss_mb = get_process_rss_mb()
            cgroup_mem = read_cgroup_memory_stats()
            cur_mb = cgroup_mem["current_mb"]

            # Visual progress bar relative to limit
            pct = 0.0
            if limit_mb != float("inf") and limit_mb > 0:
                pct = (cur_mb / limit_mb) * 100.0
                bar_len = 15
                filled = min(bar_len, int(bar_len * (cur_mb / limit_mb)))
                bar_color = CLR_GREEN if pct < 75 else (CLR_YELLOW if pct < 90 else CLR_RED)
                bar_str = f"{bar_color}[{'#' * filled}{'.' * (bar_len - filled)}] {pct:5.1f}%{CLR_RESET}"
            else:
                bar_str = f"{CLR_BLUE}[Allocating]{CLR_RESET}"

            print(f"{iteration:<6} {total_allocated_mb:>5} MB     {rss_mb:>6.1f} MB     {cur_mb:>6.1f} MB       {cgroup_mem['limit_str']:<14} {bar_str}")
            sys.stdout.flush()

            if delay > 0:
                time.sleep(delay)

    except MemoryError:
        print(f"\n{CLR_RED}💥 Python caught MemoryError before kernel OOM-killer.{CLR_RESET}")
        sys.exit(1)


def cpu_worker(stop_event: threading.Event, worker_id: int) -> None:
    """Thread worker generating 100% CPU load through continuous floating-point math."""
    while not stop_event.is_set():
        # CPU-intensive trigonometric and exponential operations
        _ = [math.sin(x) * math.cos(x) for x in range(1000)]


def run_cpu_mode(threads: int = 2, duration: int = 15) -> None:
    """Execute multi-threaded CPU stress to observe CFS Quota throttling."""
    print_banner("cpu")
    print_cgroup_environment()

    cpu_stats_initial = read_cgroup_cpu_stats()
    print(f"{CLR_BOLD}⚡ Launching {threads} CPU worker threads for {duration} seconds...{CLR_RESET}")
    print(f"  CFS Quota: {cpu_stats_initial['quota_us']} µs per {cpu_stats_initial['period_us']} µs period ({cpu_stats_initial['effective_cpus']:.2f} CPUs)")
    print(f"{CLR_GRAY}{'Elapsed':<10} {'Throttled Periods':<20} {'Throttled Time (ms)':<22} {'Throttle Rate'}{CLR_RESET}")
    print(f"{CLR_GRAY}{'-' * 75}{CLR_RESET}")
    sys.stdout.flush()

    stop_event = threading.Event()
    worker_threads = []
    for i in range(threads):
        t = threading.Thread(target=cpu_worker, args=(stop_event, i), daemon=True)
        worker_threads.append(t)
        t.start()

    start_time = time.time()
    try:
        while time.time() - start_time < duration:
            time.sleep(1.0)
            elapsed = int(time.time() - start_time)
            cur_cpu = read_cgroup_cpu_stats()
            throttled_ms = cur_cpu["throttled_usec"] / 1000.0
            pct_color = CLR_GREEN if cur_cpu["throttle_pct"] < 10 else (CLR_YELLOW if cur_cpu["throttle_pct"] < 50 else CLR_RED)
            rate_str = f"{pct_color}{cur_cpu['throttle_pct']:5.1f}% throttled{CLR_RESET}"
            print(f"{elapsed:>2}s        {cur_cpu['nr_throttled']:>6} / {cur_cpu['nr_periods']:<10} {throttled_ms:>10.2f} ms             {rate_str}")
            sys.stdout.flush()
    finally:
        stop_event.set()
        for t in worker_threads:
            t.join(timeout=1.0)

    final_cpu = read_cgroup_cpu_stats()
    print(f"{CLR_CYAN}{'-' * 75}{CLR_RESET}")
    print(f"{CLR_GREEN}✔ CPU Stress completed.{CLR_RESET}")
    print(f"  Total Periods Sampled:  {final_cpu['nr_periods']}")
    print(f"  Throttled Periods:      {final_cpu['nr_throttled']} ({final_cpu['throttle_pct']:.1f}%)")
    print(f"  Total Throttled Time:   {final_cpu['throttled_usec'] / 1000.0:.2f} ms")
    sys.exit(0)


def signal_handler(signum, frame):
    """Handle graceful shutdown signals (SIGTERM, SIGINT)."""
    signame = signal.Signals(signum).name
    print(f"\n{CLR_YELLOW}⚠️  Received signal {signame} ({signum}). Performing graceful exit.{CLR_RESET}")
    sys.exit(128 + signum)


def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    parser = argparse.ArgumentParser(
        description="Container Resource Constraints and OOM Profiler Utility",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--mode",
        choices=["oom", "safe", "hold", "cpu", "inspect"],
        default="oom",
        help="Operating mode: oom (leak to kill), safe (controlled allocation), hold (keep memory), cpu (CFS stress), inspect (dump cgroup stats)",
    )
    parser.add_argument(
        "--chunk-size-mb",
        type=int,
        default=10,
        help="Memory chunk allocated per step in MB",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.4,
        help="Delay in seconds between allocation steps",
    )
    parser.add_argument(
        "--target-mb",
        type=int,
        default=60,
        help="Target total allocation for safe and hold modes in MB",
    )
    parser.add_argument(
        "--hold-time",
        type=int,
        default=15,
        help="Duration in seconds to hold allocated memory before exiting",
    )
    parser.add_argument(
        "--cpu-threads",
        type=int,
        default=4,
        help="Number of concurrent worker threads for CPU stress",
    )
    parser.add_argument(
        "--cpu-duration",
        type=int,
        default=10,
        help="Duration in seconds for CPU stress test",
    )

    args = parser.parse_args()

    if args.mode == "inspect":
        run_inspect_mode()
    elif args.mode == "cpu":
        run_cpu_mode(threads=args.cpu_threads, duration=args.cpu_duration)
    elif args.mode == "oom":
        run_memory_allocation(
            mode="oom",
            chunk_size_mb=args.chunk_size_mb,
            delay=args.delay,
            target_mb=None,
        )
    elif args.mode == "safe":
        run_memory_allocation(
            mode="safe",
            chunk_size_mb=args.chunk_size_mb,
            delay=args.delay,
            target_mb=args.target_mb,
        )
    elif args.mode == "hold":
        run_memory_allocation(
            mode="hold",
            chunk_size_mb=args.chunk_size_mb,
            delay=args.delay,
            target_mb=args.target_mb,
            hold_time=args.hold_time,
        )


if __name__ == "__main__":
    main()
