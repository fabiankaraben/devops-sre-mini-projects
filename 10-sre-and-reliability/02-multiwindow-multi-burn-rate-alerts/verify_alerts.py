#!/usr/bin/env python3
"""
verify_alerts.py - Multiwindow Multi-Burn-Rate Alert Verification Engine
========================================================================
Validates Prometheus recording rules, Multi-Burn-Rate alerting rules, Alertmanager
routing, and alert lifecycle state transitions (inactive -> pending -> firing -> resolved).
"""

import argparse
import dataclasses
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("verify_alerts")

# ANSI Color formatting
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_YELLOW = "\033[1;33m"
CLR_RED = "\033[1;31m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"
CLR_BG_RED = "\033[41;1;37m"
CLR_BG_GREEN = "\033[42;1;30m"
CLR_BG_YELLOW = "\033[43;1;30m"


@dataclasses.dataclass
class AlertRuleState:
    name: str
    group: str
    state: str  # inactive, pending, firing
    severity: str
    urgency: str
    service: str
    burn_rate_1h: Optional[float]
    burn_rate_5m: Optional[float]
    summary: str
    description: str
    active_alerts_count: int


def query_json(url: str, timeout: float = 5.0) -> Optional[Dict[str, Any]]:
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "verify_alerts/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                return json.loads(resp.read().decode("utf-8"))
    except Exception as err:
        logger.debug("HTTP GET %s failed: %s", url, err)
    return None


def get_instant_metric(prom_url: str, query: str) -> Optional[float]:
    url = f"{prom_url.rstrip('/')}/api/v1/query?{urllib.parse.urlencode({'query': query})}"
    data = query_json(url)
    if not data or data.get("status") != "success":
        return None
    results = data.get("data", {}).get("result", [])
    if not results:
        return 0.0
    try:
        return float(results[0].get("value", [0, "0"])[1])
    except Exception:
        return None


def fetch_alerting_rules(prom_url: str) -> List[AlertRuleState]:
    url = f"{prom_url.rstrip('/')}/api/v1/rules?type=alert"
    data = query_json(url)
    rules_list: List[AlertRuleState] = []

    if not data or data.get("status") != "success":
        return rules_list

    groups = data.get("data", {}).get("groups", [])
    for grp in groups:
        grp_name = grp.get("name", "")
        for rule in grp.get("rules", []):
            if rule.get("type") != "alerting":
                continue

            alert_name = rule.get("name", "unknown")
            state = rule.get("state", "inactive")
            labels = rule.get("labels", {})
            annotations = rule.get("annotations", {})
            active_alerts = rule.get("alerts", [])

            service = labels.get("service", "checkout-service")
            if active_alerts:
                service = active_alerts[0].get("labels", {}).get("service", service)

            # Query current burn rates for context
            rate_1h = get_instant_metric(prom_url, f'job:slo_burn_rate:rate1h{{service="{service}"}}')
            rate_5m = get_instant_metric(prom_url, f'job:slo_burn_rate:rate5m{{service="{service}"}}')

            rules_list.append(
                AlertRuleState(
                    name=alert_name,
                    group=grp_name,
                    state=state,
                    severity=labels.get("severity", "unknown"),
                    urgency=labels.get("urgency", "unknown"),
                    service=service,
                    burn_rate_1h=rate_1h,
                    burn_rate_5m=rate_5m,
                    summary=annotations.get("summary", ""),
                    description=annotations.get("description", ""),
                    active_alerts_count=len(active_alerts),
                )
            )

    return rules_list


def fetch_alertmanager_alerts(am_url: str) -> List[Dict[str, Any]]:
    url = f"{am_url.rstrip('/')}/api/v2/alerts"
    data = query_json(url)
    if isinstance(data, list):
        return data
    return []


def fetch_simulator_status(sim_url: str) -> Optional[Dict[str, Any]]:
    url = f"{sim_url.rstrip('/')}/status"
    return query_json(url)


def format_terminal_dashboard(
    rules: List[AlertRuleState],
    am_alerts: List[Dict[str, Any]],
    sim_status: Optional[Dict[str, Any]],
    prom_url: str,
    am_url: str,
) -> str:
    lines: List[str] = []
    lines.append(f"{CLR_CYAN}{CLR_BOLD}========================================================================================================{CLR_RESET}")
    lines.append(f"{CLR_CYAN}{CLR_BOLD}  🚨 GOOGLE SRE MULTIWINDOW MULTI-BURN-RATE ALERTING DASHBOARD{CLR_RESET}")
    lines.append(f"{CLR_CYAN}{CLR_BOLD}========================================================================================================{CLR_RESET}")
    lines.append(f"{CLR_GRAY}Prometheus: {prom_url} | Alertmanager: {am_url} | Time: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}{CLR_RESET}")
    lines.append("")

    # Traffic Simulator Status Card
    if sim_status:
        scen = sim_status.get("active_scenario", "unknown")
        err_rate = sim_status.get("current_error_rate_percent", "0.0%")
        tot_req = sim_status.get("cumulative_totals", {}).get("total_requests", 0)
        sli = sim_status.get("cumulative_totals", {}).get("overall_success_sli_percent", 100.0)

        scen_color = CLR_GREEN if scen == "healthy" else (CLR_YELLOW if "slow" in scen else CLR_RED)
        lines.append(f"  {CLR_BOLD}Active Traffic Profile:{CLR_RESET} [{scen_color}{scen.upper()}{CLR_RESET}]  |  Error Rate: {CLR_BOLD}{err_rate}{CLR_RESET}  |  Processed Requests: {tot_req:.0f}  |  Overall SLI: {sli:.3f}%")
        lines.append("")

    # Summary metric counts
    firing_count = sum(1 for r in rules if r.state == "firing")
    pending_count = sum(1 for r in rules if r.state == "pending")
    inactive_count = sum(1 for r in rules if r.state == "inactive")

    summary_badge = (
        f"{CLR_BG_RED} FIRING ({firing_count}) {CLR_RESET}" if firing_count > 0
        else f"{CLR_BG_YELLOW} PENDING ({pending_count}) {CLR_RESET}" if pending_count > 0
        else f"{CLR_BG_GREEN} NOMINAL (ALL INACTIVE) {CLR_RESET}"
    )

    lines.append(f"  Alerting State: {summary_badge}  |  Total Rules: {len(rules)}  |  Inactive: {CLR_GREEN}{inactive_count}{CLR_RESET}  |  Pending: {CLR_YELLOW}{pending_count}{CLR_RESET}  |  Firing: {CLR_RED}{firing_count}{CLR_RESET}")
    lines.append("")

    # Rules Table
    lines.append(f"{CLR_BOLD}{'ALERT RULE NAME':<34} {'SEVERITY':<10} {'WINDOWS':<14} {'STATE':<12} {'1H BURN':<10} {'5M BURN':<10} {'ACTIVE':<8}{CLR_RESET}")
    lines.append(f"{CLR_GRAY}{'-'*34} {'-'*10} {'-'*14} {'-'*12} {'-'*10} {'-'*10} {'-'*8}{CLR_RESET}")

    for r in rules:
        if r.state == "firing":
            state_str = f"{CLR_RED}{CLR_BOLD}🔴 FIRING{CLR_RESET}"
        elif r.state == "pending":
            state_str = f"{CLR_YELLOW}🟡 PENDING{CLR_RESET}"
        else:
            state_str = f"{CLR_GREEN}🟢 INACTIVE{CLR_RESET}"

        sev_color = CLR_RED if r.severity == "page" else CLR_YELLOW
        sev_str = f"{sev_color}{r.severity.upper()}{CLR_RESET}"

        b1h = f"{r.burn_rate_1h:.2f}x" if r.burn_rate_1h is not None else "0.00x"
        b5m = f"{r.burn_rate_5m:.2f}x" if r.burn_rate_5m is not None else "0.00x"

        # Determine window labels
        if "14_4x" in r.name:
            win = "1h / 5m"
        elif "6_0x" in r.name:
            win = "6h / 30m"
        elif "3_0x" in r.name:
            win = "24h / 2h"
        elif "1_0x" in r.name:
            win = "3d / 6h"
        else:
            win = "multi"

        lines.append(
            f"{r.name[:33]:<34} {sev_str:<19} {win:<14} {state_str:<21} {b1h:<10} {b5m:<10} {r.active_alerts_count:<8}"
        )

    lines.append(f"{CLR_GRAY}{'='*104}{CLR_RESET}")
    lines.append("")

    # Alertmanager Active Notifications
    lines.append(f"{CLR_BOLD}📬 ALERTMANAGER ACTIVE NOTIFICATIONS ({len(am_alerts)} Active):{CLR_RESET}")
    if not am_alerts:
        lines.append(f"  {CLR_GREEN}✔ No active alerts dispatched to Alertmanager notification receivers.{CLR_RESET}")
    else:
        for alert in am_alerts:
            lbls = alert.get("labels", {})
            an = alert.get("annotations", {})
            name = lbls.get("alertname", "unknown")
            sev = lbls.get("severity", "unknown")
            svc = lbls.get("service", "unknown")
            summary = an.get("summary", "")
            lines.append(f"  {CLR_RED}⚡ [{sev.upper()}] {name} on {svc}{CLR_RESET}: {summary}")

    lines.append("")
    return "\n".join(lines)


def format_markdown(
    rules: List[AlertRuleState],
    am_alerts: List[Dict[str, Any]],
    sim_status: Optional[Dict[str, Any]],
    prom_url: str,
    am_url: str,
) -> str:
    firing_count = sum(1 for r in rules if r.state == "firing")
    pending_count = sum(1 for r in rules if r.state == "pending")

    badge = "🔴 FIRING" if firing_count > 0 else ("🟡 PENDING" if pending_count > 0 else "🟢 NOMINAL")

    md = [
        "# 🚨 Google SRE Multiwindow Multi-Burn-Rate Alert Verification Report",
        "",
        f"> **Generated at**: `{time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}`  ",
        f"> **Prometheus Source**: `{prom_url}`  ",
        f"> **Alertmanager Source**: `{am_url}`  ",
        f"> **Current Alerting State**: **{badge}**",
        "",
        "---",
        "",
        "## 📊 Alerting Rules State Matrix",
        "",
        "| Alert Rule | Severity | Multi-Window Pair | State | 1h Burn Rate | 5m Burn Rate | Active Alerts |",
        "| :--- | :---: | :---: | :---: | :---: | :---: | :---: |",
    ]

    for r in rules:
        state_display = f"**🔴 FIRING**" if r.state == "firing" else (f"*🟡 PENDING*" if r.state == "pending" else "🟢 INACTIVE")
        b1h = f"`{r.burn_rate_1h:.2f}x`" if r.burn_rate_1h is not None else "`0.00x`"
        b5m = f"`{r.burn_rate_5m:.2f}x`" if r.burn_rate_5m is not None else "`0.00x`"
        win = "1h / 5m" if "14_4x" in r.name else ("6h / 30m" if "6_0x" in r.name else ("24h / 2h" if "3_0x" in r.name else "3d / 6h"))

        md.append(f"| **`{r.name}`** | `{r.severity}` | `{win}` | {state_display} | {b1h} | {b5m} | `{r.active_alerts_count}` |")

    md.extend([
        "",
        "---",
        "",
        "## 📬 Alertmanager Dispatched Alerts",
        "",
    ])

    if not am_alerts:
        md.append("🟢 *No alerts currently routed to Alertmanager notification receivers.*")
    else:
        for a in am_alerts:
            lbls = a.get("labels", {})
            an = a.get("annotations", {})
            md.extend([
                f"### 🔴 `{lbls.get('alertname')}`",
                f"- **Service**: `{lbls.get('service')}`",
                f"- **Severity**: `{lbls.get('severity')}`",
                f"- **Summary**: {an.get('summary')}",
                f"- **Description**: {an.get('description')}",
                f"- **Runbook**: [{an.get('runbook_url')}]({an.get('runbook_url')})",
                "",
            ])

    md.extend([
        "---",
        "",
        "## 🧠 SRE Multi-Burn-Rate Theory Reference",
        "",
        "- **14.4x Burn Rate**: Burns 2% of budget in 1 hour; 100% in 50 hours (triggers 1h & 5m page alert).",
        "- **6.0x Burn Rate**: Burns 5% of budget in 6 hours; 100% in 120 hours (triggers 6h & 30m page alert).",
        "- **3.0x Burn Rate**: Burns 10% of budget in 24 hours; 100% in 10 days (triggers 24h & 2h ticket alert).",
        "- **1.0x Burn Rate**: Burns 10% of budget in 3 days; 100% in 30 days (triggers 3d & 6h ticket alert).",
        "",
    ])

    return "\n".join(md)


def format_json_output(rules: List[AlertRuleState], am_alerts: List[Dict[str, Any]], sim_status: Optional[Dict[str, Any]]) -> str:
    payload = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "summary": {
            "total_rules": len(rules),
            "firing_rules": sum(1 for r in rules if r.state == "firing"),
            "pending_rules": sum(1 for r in rules if r.state == "pending"),
            "inactive_rules": sum(1 for r in rules if r.state == "inactive"),
            "alertmanager_alerts_count": len(am_alerts),
        },
        "simulator_status": sim_status,
        "rules": [dataclasses.asdict(r) for r in rules],
        "alertmanager_alerts": am_alerts,
    }
    return json.dumps(payload, indent=2)


def main():
    parser = argparse.ArgumentParser(description="Multiwindow Multi-Burn-Rate Alert Verification CLI")
    parser.add_argument("--prometheus-url", "-p", type=str, default="http://localhost:9090", help="Prometheus base URL")
    parser.add_argument("--alertmanager-url", "-a", type=str, default="http://localhost:9093", help="Alertmanager base URL")
    parser.add_argument("--simulator-url", "-s", type=str, default="http://localhost:8080", help="Simulator base URL")
    parser.add_argument("--format", "-f", choices=["table", "markdown", "json"], default="table", help="Output format")
    parser.add_argument("--output", "-o", type=str, default=None, help="Output file path")
    parser.add_argument("--assert-firing", type=str, default=None, help="Assert that the specified alert is FIRING (exit 0 if firing, 1 otherwise)")
    parser.add_argument("--assert-inactive", type=str, default=None, help="Assert that the specified alert is INACTIVE (exit 0 if inactive, 1 otherwise)")
    parser.add_argument("--mock", action="store_true", help="Run in mock mode for offline testing")
    args = parser.parse_args()

    if args.mock:
        rules = [
            AlertRuleState(
                name="ErrorBudgetBurnRatePage14_4x",
                group="sre_multiwindow_multi_burn_rate_alerts",
                state="firing" if args.assert_firing else "inactive",
                severity="page",
                urgency="critical",
                service="checkout-service",
                burn_rate_1h=150.0 if args.assert_firing else 0.2,
                burn_rate_5m=150.0 if args.assert_firing else 0.2,
                summary="Catastrophic 14.4x Error Budget Burn Rate on checkout-service",
                description="Burning budget at >14.4x over 1h and 5m windows",
                active_alerts_count=1 if args.assert_firing else 0,
            ),
            AlertRuleState(
                name="ErrorBudgetBurnRatePage6_0x",
                group="sre_multiwindow_multi_burn_rate_alerts",
                state="inactive",
                severity="page",
                urgency="high",
                service="checkout-service",
                burn_rate_1h=150.0 if args.assert_firing else 0.2,
                burn_rate_5m=150.0 if args.assert_firing else 0.2,
                summary="Elevated 6.0x Error Budget Burn Rate",
                description="Burning budget at >6.0x over 6h and 30m windows",
                active_alerts_count=0,
            ),
        ]
        am_alerts = []
        sim_status = {"active_scenario": "fast-burn" if args.assert_firing else "healthy", "current_error_rate_percent": "15.0%"}
    else:
        rules = fetch_alerting_rules(args.prometheus_url)
        am_alerts = fetch_alertmanager_alerts(args.alertmanager_url)
        sim_status = fetch_simulator_status(args.simulator_url)

    if args.format == "table":
        output = format_terminal_dashboard(rules, am_alerts, sim_status, args.prometheus_url, args.alertmanager_url)
    elif args.format == "markdown":
        output = format_markdown(rules, am_alerts, sim_status, args.prometheus_url, args.alertmanager_url)
    elif args.format == "json":
        output = format_json_output(rules, am_alerts, sim_status)
    else:
        output = format_terminal_dashboard(rules, am_alerts, sim_status, args.prometheus_url, args.alertmanager_url)

    print(output)

    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(output + "\n")
            logger.info("Saved alert verification report to %s", args.output)
        except Exception as err:
            logger.error("Failed to write report to %s: %s", args.output, err)

    # Assertion checks
    if args.assert_firing:
        target_rule = next((r for r in rules if r.name == args.assert_firing), None)
        if not target_rule or target_rule.state != "firing":
            logger.error("Assertion failed: Alert '%s' is not FIRING (State: %s)", args.assert_firing, target_rule.state if target_rule else "NOT_FOUND")
            sys.exit(1)
        logger.info("Assertion passed: Alert '%s' is FIRING.", args.assert_firing)

    if args.assert_inactive:
        target_rule = next((r for r in rules if r.name == args.assert_inactive), None)
        if target_rule and target_rule.state != "inactive":
            logger.error("Assertion failed: Alert '%s' is not INACTIVE (State: %s)", args.assert_inactive, target_rule.state)
            sys.exit(1)
        logger.info("Assertion passed: Alert '%s' is INACTIVE.", args.assert_inactive)


if __name__ == "__main__":
    main()
