#!/usr/bin/env python3
"""
Continuous Load Generator & Downtime Analyzer
==============================================
Simulates active user traffic against the Global Edge Router during Blue-Green
deployments to verify zero dropped connections and calculate availability.
"""

import sys
import time
import json
import signal
import argparse
import urllib.request
import urllib.error

# ANSI styling
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"

running = True

def sigint_handler(sig, frame):
    global running
    running = False

signal.signal(signal.SIGINT, sigint_handler)
signal.signal(signal.SIGTERM, sigint_handler)

def run_load_test(target_url: str, rate_per_sec: int, duration_sec: int, output_json: str):
    global running
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  ⚡ Continuous Load Generator & Downtime Analyzer{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  • Target Endpoint: {CLR_BOLD}{target_url}{CLR_RESET}")
    print(f"  • Rate:            {rate_per_sec} requests/sec")
    print(f"  • Duration:        {'Unlimited (Ctrl+C to stop)' if duration_sec == 0 else f'{duration_sec} seconds'}")
    print("----------------------------------------------------------------------")

    interval = 1.0 / float(rate_per_sec)
    total_requests = 0
    success_requests = 0
    failed_requests = 0
    dropped_connections = 0

    latencies = []
    color_distribution = {"blue": 0, "green": 0, "unknown": 0}
    region_distribution = {"us-east": 0, "eu-west": 0, "unknown": 0}
    version_distribution = {}

    start_time = time.time()
    last_print = start_time

    while running:
        req_start = time.time()
        total_requests += 1

        try:
            req = urllib.request.Request(target_url)
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                elapsed_ms = (time.time() - req_start) * 1000.0
                latencies.append(elapsed_ms)

                if resp.status == 200:
                    success_requests += 1
                    try:
                        data = json.loads(resp.read().decode("utf-8"))
                        col = data.get("color", "unknown").lower()
                        reg = data.get("region", "unknown").lower()
                        ver = data.get("version", "unknown")
                        
                        color_distribution[col] = color_distribution.get(col, 0) + 1
                        region_distribution[reg] = region_distribution.get(reg, 0) + 1
                        version_distribution[ver] = version_distribution.get(ver, 0) + 1
                    except Exception:
                        pass
                else:
                    failed_requests += 1
        except urllib.error.HTTPError as e:
            failed_requests += 1
            latencies.append((time.time() - req_start) * 1000.0)
        except Exception as e:
            failed_requests += 1
            dropped_connections += 1
            latencies.append((time.time() - req_start) * 1000.0)

        now = time.time()
        if now - last_print >= 1.0:
            last_print = now
            elapsed = int(now - start_time)
            cur_avail = (success_requests / total_requests * 100.0) if total_requests > 0 else 100.0
            p50 = sorted(latencies)[int(len(latencies) * 0.5)] if latencies else 0.0
            print(
                f"  [Elapsed: {elapsed:02d}s] Reqs: {total_requests:<5} | "
                f"Success: {CLR_GREEN}{success_requests}{CLR_RESET} | "
                f"Failed: {CLR_RED if failed_requests > 0 else CLR_GRAY}{failed_requests}{CLR_RESET} | "
                f"Avail: {CLR_GREEN if cur_avail == 100.0 else CLR_YELLOW}{cur_avail:.2f}%{CLR_RESET} | "
                f"p50: {p50:.1f}ms (Blue: {color_distribution.get('blue', 0)}, Green: {color_distribution.get('green', 0)})",
                end="\r"
            )

        if duration_sec > 0 and (now - start_time) >= duration_sec:
            break

        # Precise sleep compensation
        time_taken = time.time() - req_start
        sleep_dur = interval - time_taken
        if sleep_dur > 0:
            time.sleep(sleep_dur)

    # Compute Summary
    duration_total = time.time() - start_time
    availability_pct = (success_requests / total_requests * 100.0) if total_requests > 0 else 0.0
    sorted_latencies = sorted(latencies) if latencies else [0.0]
    p50 = sorted_latencies[int(len(sorted_latencies) * 0.50)]
    p95 = sorted_latencies[int(len(sorted_latencies) * 0.95)] if len(sorted_latencies) >= 20 else sorted_latencies[-1]
    p99 = sorted_latencies[int(len(sorted_latencies) * 0.99)] if len(sorted_latencies) >= 100 else sorted_latencies[-1]

    print("\n" + "=" * 70)
    print(f"{CLR_CYAN}{CLR_BOLD}  📊 Continuous Load Test Results & Downtime Analysis{CLR_RESET}")
    print("=" * 70)
    print(f"  • Total Duration:         {duration_total:.2f} seconds")
    print(f"  • Total Requests Sent:    {CLR_BOLD}{total_requests}{CLR_RESET}")
    print(f"  • Successful (HTTP 200):  {CLR_GREEN}{CLR_BOLD}{success_requests}{CLR_RESET}")
    print(f"  • Failed Requests:        {CLR_RED if failed_requests > 0 else CLR_GREEN}{CLR_BOLD}{failed_requests}{CLR_RESET}")
    print(f"  • Dropped Connections:    {CLR_RED if dropped_connections > 0 else CLR_GREEN}{CLR_BOLD}{dropped_connections}{CLR_RESET}")
    print(f"  • Measured Availability:  {CLR_GREEN if availability_pct == 100.0 else CLR_YELLOW}{CLR_BOLD}{availability_pct:.4f}%{CLR_RESET}")
    print(f"  • Zero-Downtime Result:   {CLR_GREEN}{CLR_BOLD}VERIFIED (0 dropped requests during switch){CLR_RESET}" if failed_requests == 0 else f"{CLR_RED}DOWNTIME DETECTED{CLR_RESET}")
    print("----------------------------------------------------------------------")
    print(f"  • Latency Profile:        p50: {p50:.2f}ms | p95: {p95:.2f}ms | p99: {p99:.2f}ms")
    print(f"  • Color Distribution:     Blue: {color_distribution.get('blue', 0)} | Green: {color_distribution.get('green', 0)}")
    print(f"  • Region Distribution:    US-East: {region_distribution.get('us-east', 0)} | EU-West: {region_distribution.get('eu-west', 0)}")
    print(f"  • Version Distribution:   {version_distribution}")
    print("=" * 70)

    if output_json:
        report = {
            "total_requests": total_requests,
            "success_requests": success_requests,
            "failed_requests": failed_requests,
            "dropped_connections": dropped_connections,
            "availability_percentage": availability_pct,
            "zero_downtime_verified": failed_requests == 0,
            "duration_seconds": duration_total,
            "latency_ms": {
                "p50": round(p50, 2),
                "p95": round(p95, 2),
                "p99": round(p99, 2)
            },
            "color_distribution": color_distribution,
            "region_distribution": region_distribution,
            "version_distribution": version_distribution
        }
        try:
            with open(output_json, "w") as f:
                json.dump(report, f, indent=2)
            print(f"  [✓] Summary JSON report written to: {output_json}\n")
        except Exception as e:
            print(f"  [WARN] Failed to write JSON output: {e}\n")

    return 0 if failed_requests == 0 else 1

def main():
    parser = argparse.ArgumentParser(description="Continuous Load Generator for Blue-Green Verification")
    parser.add_argument("--url", default="http://localhost:8090/api/info", help="Target endpoint to load test")
    parser.add_argument("--rate", type=int, default=25, help="Requests per second")
    parser.add_argument("--duration", type=int, default=0, help="Duration in seconds (0 for indefinite)")
    parser.add_argument("--output-json", default="", help="Path to write JSON summary report")

    args = parser.parse_args()
    sys.exit(run_load_test(args.url, args.rate, args.duration, args.output_json))

if __name__ == "__main__":
    main()
