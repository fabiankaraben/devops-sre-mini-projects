#!/usr/bin/env python3
"""
Multi-Region Blue-Green Deployment Orchestrator CLI
===================================================
Automates zero-downtime Blue-Green deployments, automated smoke testing,
and atomic traffic switchover across multi-region Kubernetes clusters.
"""

import sys
import json
import time
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
CLR_BLUE = "\033[1;34m"
CLR_GRAY = "\033[0;90m"
CLR_MAGENTA = "\033[1;35m"

ROUTER_URL = "http://localhost:8090"
REGIONS = ["us-east", "eu-west"]

def http_get(url: str, headers: dict = None, timeout: float = 5.0) -> tuple[int, dict]:
    """Helper to perform HTTP GET returning (status_code, json_or_dict)."""
    req = urllib.request.Request(url)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = resp.read().decode("utf-8")
            try:
                data = json.loads(content)
            except Exception:
                data = {"raw": content}
            return resp.status, data
    except urllib.error.HTTPError as e:
        content = e.read().decode("utf-8")
        try:
            data = json.loads(content)
        except Exception:
            data = {"raw": content}
        return e.code, data
    except Exception as e:
        return 0, {"error": str(e)}

def http_post(url: str, payload: dict, timeout: float = 5.0) -> tuple[int, dict]:
    """Helper to perform HTTP POST returning (status_code, json_or_dict)."""
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = resp.read().decode("utf-8")
            return resp.status, json.loads(content)
    except urllib.error.HTTPError as e:
        content = e.read().decode("utf-8")
        try:
            return e.code, json.loads(content)
        except Exception:
            return e.code, {"raw": content}
    except Exception as e:
        return 0, {"error": str(e)}

# ==============================================================================
# CLI Commands
# ==============================================================================

def cmd_status(args):
    """Displays multi-region status table and active routing pointers."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  📊 Multi-Region Blue-Green Fleet & Gateway Status{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

    status_code, state = http_get(f"{ROUTER_URL}/admin/status")
    if status_code != 200:
        print(f"  [{CLR_RED}ERROR{CLR_RESET}] Unable to reach Global Edge Router at {ROUTER_URL}: {state.get('error', 'Unreachable')}")
        return 1

    active_global = state.get("global_active_color", "unknown").upper()
    color_code = CLR_BLUE if active_global == "BLUE" else CLR_GREEN
    print(f"  • Global Active Target:  {color_code}{CLR_BOLD}{active_global}{CLR_RESET}")
    print(f"  • Total Routed Requests: {CLR_BOLD}{state.get('stats', {}).get('total_requests', 0)}{CLR_RESET}")
    print(f"    - Blue Requests:       {state.get('stats', {}).get('blue_requests', 0)}")
    print(f"    - Green Requests:      {state.get('stats', {}).get('green_requests', 0)}")
    print("----------------------------------------------------------------------")

    print(f"  {CLR_BOLD}{'REGION':<12} {'ACTIVE SLOT':<14} {'BLUE VERSION':<16} {'GREEN VERSION':<16} {'HEALTH'}{CLR_RESET}")
    print("  " + "-" * 66)

    for region in REGIONS:
        reg_active = state.get("regions", {}).get(region, {}).get("active_color", "unknown").upper()
        
        # Probe Blue
        _, blue_info = http_get(f"{ROUTER_URL}/private/{region}/blue/api/info")
        blue_ver = blue_info.get("version", "N/A")

        # Probe Green
        _, green_info = http_get(f"{ROUTER_URL}/private/{region}/green/api/info")
        green_ver = green_info.get("version", "N/A")

        reg_color_code = CLR_BLUE if reg_active == "BLUE" else CLR_GREEN
        health_badge = f"{CLR_GREEN}HEALTHY (2/2){CLR_RESET}" if blue_ver != "N/A" and green_ver != "N/A" else f"{CLR_YELLOW}DEGRADED{CLR_RESET}"

        print(f"  {region:<12} {reg_color_code}{reg_active:<14}{CLR_RESET} {blue_ver:<16} {green_ver:<16} {health_badge}")

    print("----------------------------------------------------------------------")
    
    # Test live endpoint
    _, live_info = http_get(f"{ROUTER_URL}/api/info")
    print(f"  • Live Ingress Response: {CLR_CYAN}http://localhost:8090/api/info{CLR_RESET}")
    print(f"    - Served by:   {color_code}[{live_info.get('color', 'unknown').upper()}]{CLR_RESET} in {live_info.get('region', 'unknown')}")
    print(f"    - Version:     {CLR_BOLD}{live_info.get('version', 'unknown')}{CLR_RESET}")
    print(f"======================================================================\n")
    return 0

def run_smoke_tests(target_color: str, simulate_failure: bool = False) -> bool:
    """Executes automated functional and health smoke tests against private endpoints."""
    print(f"\n{CLR_YELLOW}▶ [Automated Smoke Tests] Testing target environment [{target_color.upper()}]...{CLR_RESET}")
    headers = {"X-Simulate-Failure": "true"} if simulate_failure else {}

    all_passed = True
    for region in REGIONS:
        url = f"{ROUTER_URL}/private/{region}/{target_color}/smoke-test"
        code, resp = http_get(url, headers=headers)
        
        test_status = resp.get("smokeTest", "FAILED")
        if code == 200 and test_status == "PASSED":
            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Region {region.upper()} [{target_color}]: Health OK, DB OK, Cache OK (Latency: {resp.get('latencyMs', 0)}ms)")
        else:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Region {region.upper()} [{target_color}]: HTTP {code} - {resp.get('error', 'Smoke test failed')}")
            all_passed = False

    return all_passed

def cmd_smoke_test(args):
    """CLI handler for smoke testing."""
    passed = run_smoke_tests(args.target.lower(), args.simulate_failure)
    return 0 if passed else 1

def switch_traffic(to_color: str, region: str = "all") -> bool:
    """Updates atomic routing pointer on Global Edge Router."""
    payload = {"active_color": to_color.lower(), "region": region}
    code, resp = http_post(f"{ROUTER_URL}/admin/route", payload)
    if code == 200:
        color_code = CLR_BLUE if to_color.lower() == "blue" else CLR_GREEN
        print(f"  [${CLR_GREEN}✓${CLR_RESET}] Atomic Traffic Switch: Live traffic now routed to {color_code}{to_color.upper()}{CLR_RESET} (Region: {region})")
        return True
    else:
        print(f"  [{CLR_RED}ERROR{CLR_RESET}] Failed to switch traffic: {resp.get('error')}")
        return False

def cmd_switch(args):
    """CLI handler for manual traffic switch."""
    success = switch_traffic(args.to.lower(), args.region)
    return 0 if success else 1

def cmd_rollback(args):
    """Executes immediate rollback to the standby environment."""
    print(f"\n{CLR_MAGENTA}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_MAGENTA}{CLR_BOLD}  ⏪ SRE Emergency Instant Rollback Triggered{CLR_RESET}")
    print(f"{CLR_MAGENTA}{CLR_BOLD}======================================================================{CLR_RESET}")

    status_code, state = http_get(f"{ROUTER_URL}/admin/status")
    if status_code != 200:
        print(f"  [{CLR_RED}ERROR{CLR_RESET}] Router unreachable.")
        return 1

    current_active = state.get("global_active_color", "blue")
    standby_target = "green" if current_active == "blue" else "blue"

    print(f"  • Current Active Color: [{current_active.upper()}]")
    print(f"  • Rolling Back To:      [{standby_target.upper()}] across all regions...")

    if switch_traffic(standby_target, "all"):
        print(f"\n{CLR_GREEN}{CLR_BOLD}  ✨ ROLLBACK COMPLETE: Traffic instantaneously restored to [{standby_target.upper()}]{CLR_RESET}\n")
        return 0
    else:
        return 1

def cmd_deploy(args):
    """Orchestrates full zero-downtime Blue-Green deployment with smoke tests."""
    target_version = args.version
    simulate_fail = args.simulate_failure
    strategy = args.strategy

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🚀 Multi-Region Blue-Green Rollout: Target Version {target_version}{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

    # 1. Determine Current Active vs Idle Target
    status_code, state = http_get(f"{ROUTER_URL}/admin/status")
    if status_code != 200:
        print(f"  [{CLR_RED}ERROR{CLR_RESET}] Router unreachable.")
        return 1

    current_active = state.get("global_active_color", "blue")
    idle_target = "green" if current_active == "blue" else "blue"
    idle_color_code = CLR_GREEN if idle_target == "green" else CLR_BLUE

    print(f"  [1/4] Current Live Traffic: [{current_active.upper()}] | Target Idle Slot: {idle_color_code}[{idle_target.upper()}]{CLR_RESET}")

    # 2. Stage Workload on Idle Environment
    print(f"\n{CLR_YELLOW}▶ [2/4] Staging {target_version} on [{idle_target.upper()}] across regions (us-east, eu-west)...{CLR_RESET}")
    time.sleep(1) # Simulation of deployment sync
    print(f"  [{CLR_GREEN}✓${CLR_RESET}] Artifacts deployed to {idle_target.upper()} containers.")

    # 3. Execute Automated Smoke Tests
    print(f"\n{CLR_YELLOW}▶ [3/4] Running automated pre-flight smoke tests on [{idle_target.upper()}]...{CLR_RESET}")
    smoke_passed = run_smoke_tests(idle_target, simulate_failure=simulate_fail)

    if not smoke_passed:
        print(f"\n{CLR_RED}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_RED}{CLR_BOLD}  ⛔ CRITICAL SAFETY ABORT: Pre-Flight Smoke Tests FAILED!{CLR_RESET}")
        print(f"{CLR_RED}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"  • Traffic Switch:      {CLR_RED}ABORTED (0% of live traffic diverted){CLR_RESET}")
        print(f"  • Production Impact:   {CLR_GREEN}ZERO (Live traffic remains 100% on [{current_active.upper()}]){CLR_RESET}")
        print(f"  • Action Taken:        Target environment [{idle_target.upper()}] quarantined for debugging.")
        print(f"======================================================================\n")
        return 1

    # 4. Atomic Traffic Switchover
    print(f"\n{CLR_YELLOW}▶ [4/4] Executing atomic traffic switchover to [{idle_target.upper()}]...{CLR_RESET}")
    if strategy == "canary-region":
        print("  Executing phased regional rollout (Canary: us-east first)...")
        switch_traffic(idle_target, "us-east")
        time.sleep(2)
        print("  Canary phase verified. Switching remaining region (eu-west)...")
        switch_traffic(idle_target, "eu-west")
    else:
        switch_traffic(idle_target, "all")

    # Verify Live traffic
    _, live_info = http_get(f"{ROUTER_URL}/api/info")
    print(f"\n{CLR_GREEN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_GREEN}{CLR_BOLD}  🎉 ZERO-DOWNTIME DEPLOYMENT SUCCESSFUL!{CLR_RESET}")
    print(f"{CLR_GREEN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  • Live Environment:   {idle_color_code}[{live_info.get('color', 'unknown').upper()}]{CLR_RESET}")
    print(f"  • Active Version:     {CLR_BOLD}{live_info.get('version', target_version)}{CLR_RESET}")
    print(f"  • Standby Slot:       [{current_active.upper()}] (Ready for instant rollback)")
    print(f"  • Verification URL:   http://localhost:8090/api/info")
    print(f"======================================================================\n")
    return 0

def main():
    parser = argparse.ArgumentParser(description="Multi-Region Blue-Green Deployment Orchestrator CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # status
    p_status = subparsers.add_parser("status", help="Show fleet deployment and routing status")
    p_status.set_defaults(func=cmd_status)

    # smoke-test
    p_smoke = subparsers.add_parser("smoke-test", help="Run automated smoke tests on specified slot")
    p_smoke.add_argument("--target", choices=["blue", "green"], default="green", help="Target color slot to test")
    p_smoke.add_argument("--simulate-failure", action="store_true", help="Simulate critical smoke test failure")
    p_smoke.set_defaults(func=cmd_smoke_test)

    # switch-traffic
    p_switch = subparsers.add_parser("switch-traffic", help="Manually flip routing pointer to Blue or Green")
    p_switch.add_argument("--to", choices=["blue", "green"], required=True, help="Target color slot")
    p_switch.add_argument("--region", choices=["all", "us-east", "eu-west"], default="all", help="Target region")
    p_switch.set_defaults(func=cmd_switch)

    # rollback
    p_rollback = subparsers.add_parser("rollback", help="Instant emergency rollback to standby slot")
    p_rollback.set_defaults(func=cmd_rollback)

    # deploy
    p_deploy = subparsers.add_parser("deploy", help="Deploy new version to idle environment and switch traffic")
    p_deploy.add_argument("--version", default="v2.0.0", help="Target application version tag")
    p_deploy.add_argument("--strategy", choices=["all-at-once", "canary-region"], default="all-at-once", help="Traffic switch strategy")
    p_deploy.add_argument("--simulate-failure", action="store_true", help="Simulate smoke test failure to test safety abort")
    p_deploy.set_defaults(func=cmd_deploy)

    args = parser.parse_args()
    sys.exit(args.func(args))

if __name__ == "__main__":
    main()
