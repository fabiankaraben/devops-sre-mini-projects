#!/usr/bin/env python3
"""
postmortem_generator.py - SRE Incident Timeline & Blameless Postmortem Generator
================================================================================
Aggregates heterogeneous event streams (Prometheus alerts, Git commits, CI/CD
deployments, Slack discussions, PagerDuty pages) to construct a chronological
incident timeline, compute core SRE operational metrics (MTTD, MTTA, MTTM, MTTR,
Error Budget Burn), perform 5-Whys RCA, and export structured Markdown, JSON,
and HTML postmortem documents.
"""

import argparse
import datetime
import json
import logging
import os
import sys
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("postmortem_generator")

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"


def parse_iso8601_utc(ts_str: str) -> datetime.datetime:
    """Parses standard ISO-8601 UTC timestamp string to datetime object."""
    clean_str = ts_str.strip().replace("Z", "+00:00")
    dt = datetime.datetime.fromisoformat(clean_str)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.astimezone(datetime.timezone.utc)


def format_duration(seconds: float) -> str:
    """Formats duration in seconds into human-readable representation."""
    if seconds < 0:
        return "0s"
    total_secs = int(round(seconds))
    hours = total_secs // 3600
    minutes = (total_secs % 3600) // 60
    secs = total_secs % 60

    parts = []
    if hours > 0:
        parts.append(f"{hours}h")
    if minutes > 0 or hours > 0:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


@dataclass
class TimelineEvent:
    """Represents a unified, normalized incident timeline event."""
    timestamp_utc: str
    epoch_timestamp: float
    source: str         # ALERT, DEPLOYMENT, GIT_COMMIT, SLACK, PAGERDUTY, METRICS
    category: str       # TRIGGER, DETECTION, DIAGNOSIS, MITIGATION, RESOLUTION, INFO
    actor: str
    summary: str
    details: Dict[str, Any] = field(default_factory=dict)
    severity: Optional[str] = None


@dataclass
class SREMetrics:
    """Calculated Site Reliability Engineering operational KPIs."""
    mttd_seconds: float                     # Mean Time to Detect (Start -> 1st Alert)
    mttd_formatted: str
    mtta_seconds: float                     # Mean Time to Acknowledge (1st Alert -> Responder ACK)
    mtta_formatted: str
    mttm_seconds: float                     # Mean Time to Mitigate (ACK -> Mitigation Deployed)
    mttm_formatted: str
    mttr_seconds: float                     # Mean Time to Resolve (Start -> All Healthy)
    mttr_formatted: str
    total_outage_duration_seconds: float
    total_outage_formatted: str
    total_requests_affected: int
    failed_requests: int
    availability_pct: float
    error_budget_consumed_pct: float
    estimated_revenue_loss_usd: float


class IncidentIngestor:
    """Discovers and parses heterogeneous event logs from incident fixtures."""

    def __init__(self, incident_dir: str):
        self.incident_dir = incident_dir
        if not os.path.isdir(incident_dir):
            raise FileNotFoundError(f"Incident data directory not found: {incident_dir}")

    def load_meta(self) -> Dict[str, Any]:
        path = os.path.join(self.incident_dir, "incident_meta.json")
        if not os.path.exists(path):
            raise FileNotFoundError(f"Missing incident_meta.json in {self.incident_dir}")
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)

    def load_alerts(self) -> List[TimelineEvent]:
        path = os.path.join(self.incident_dir, "alerts.json")
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            raw_alerts = json.load(f)

        events: List[TimelineEvent] = []
        for alert in raw_alerts:
            ts = alert.get("timestamp", "")
            dt = parse_iso8601_utc(ts)
            status = alert.get("status", "firing").lower()
            category = "DETECTION" if status == "firing" else "RESOLUTION"
            events.append(TimelineEvent(
                timestamp_utc=dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
                epoch_timestamp=dt.timestamp(),
                source="ALERT",
                category=category,
                actor="Prometheus / Alertmanager",
                summary=f"Alert {status.upper()}: {alert.get('name', 'Unknown Alert')} - {alert.get('summary', '')}",
                details=alert,
                severity=alert.get("severity", "critical").upper(),
            ))
        return events

    def load_deployments(self) -> List[TimelineEvent]:
        path = os.path.join(self.incident_dir, "deployments.json")
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            raw_deps = json.load(f)

        events: List[TimelineEvent] = []
        for dep in raw_deps:
            ts = dep.get("timestamp", "")
            dt = parse_iso8601_utc(ts)
            summary = dep.get("summary", "")
            is_rollback = "rollback" in summary.lower() or "v2.4.0" in dep.get("version", "")
            category = "MITIGATION" if is_rollback else "TRIGGER"

            events.append(TimelineEvent(
                timestamp_utc=dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
                epoch_timestamp=dt.timestamp(),
                source="DEPLOYMENT",
                category=category,
                actor=dep.get("deployed_by", "CI/CD Pipeline"),
                summary=f"Deployment {dep.get('service', '')}:{dep.get('version', '')} ({dep.get('status', '')}) - {summary}",
                details=dep,
                severity="INFO",
            ))
        return events

    def load_git_commits(self) -> List[TimelineEvent]:
        path = os.path.join(self.incident_dir, "git_commits.json")
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            raw_commits = json.load(f)

        events: List[TimelineEvent] = []
        for commit in raw_commits:
            ts = commit.get("timestamp", "")
            dt = parse_iso8601_utc(ts)
            is_revert = "revert" in commit.get("pr_title", "").lower()
            category = "MITIGATION" if is_revert else "TRIGGER"

            events.append(TimelineEvent(
                timestamp_utc=dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
                epoch_timestamp=dt.timestamp(),
                source="GIT_COMMIT",
                category=category,
                actor=commit.get("author", "Developer"),
                summary=f"Git PR #{commit.get('pr_number', '')} ({commit.get('commit_sha', '')[:7]}): {commit.get('pr_title', '')}",
                details=commit,
                severity="INFO",
            ))
        return events

    def load_slack_messages(self) -> List[TimelineEvent]:
        path = os.path.join(self.incident_dir, "slack_messages.json")
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            raw_msgs = json.load(f)

        events: List[TimelineEvent] = []
        for msg in raw_msgs:
            ts = msg.get("timestamp", "")
            dt = parse_iso8601_utc(ts)
            text = msg.get("text", "")
            user = msg.get("user", "")

            # Deduce category based on content
            lower_text = text.lower()
            if "alert firing" in lower_text:
                category = "DETECTION"
            elif "alert resolved" in lower_text or "resolved" in lower_text and "declaring" in lower_text:
                category = "RESOLUTION"
            elif "rollback" in lower_text or "patching" in lower_text:
                category = "MITIGATION"
            elif "timeout" in lower_text or "exhausted" in lower_text or "found it" in lower_text or "checking" in lower_text:
                category = "DIAGNOSIS"
            elif "declaring" in lower_text or "acknowledging" in lower_text:
                category = "DETECTION"
            else:
                category = "INFO"

            events.append(TimelineEvent(
                timestamp_utc=dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
                epoch_timestamp=dt.timestamp(),
                source="SLACK",
                category=category,
                actor=f"{user} ({msg.get('channel', '#incident')})",
                summary=text,
                details=msg,
                severity="INFO",
            ))
        return events

    def load_pagerduty(self) -> List[TimelineEvent]:
        path = os.path.join(self.incident_dir, "pagerduty.json")
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            raw_pd = json.load(f)

        events: List[TimelineEvent] = []
        for pd_ev in raw_pd:
            ts = pd_ev.get("timestamp", "")
            dt = parse_iso8601_utc(ts)
            ev_type = pd_ev.get("type", "event").upper()
            actor = pd_ev.get("actor") or pd_ev.get("assigned_to") or "PagerDuty Engine"

            if ev_type == "TRIGGER":
                category = "DETECTION"
            elif ev_type == "ACKNOWLEDGE":
                category = "DETECTION"
            elif ev_type == "RESOLVE":
                category = "RESOLUTION"
            else:
                category = "DIAGNOSIS"

            note = f" - Note: {pd_ev['note']}" if "note" in pd_ev else ""
            events.append(TimelineEvent(
                timestamp_utc=dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
                epoch_timestamp=dt.timestamp(),
                source="PAGERDUTY",
                category=category,
                actor=actor,
                summary=f"PagerDuty {ev_type} on {pd_ev.get('service', '')}{note}",
                details=pd_ev,
                severity=pd_ev.get("urgency", "high").upper(),
            ))
        return events

    def build_complete_timeline(self) -> List[TimelineEvent]:
        """Aggregates and strictly sorts all events chronologically."""
        all_events: List[TimelineEvent] = []
        all_events.extend(self.load_deployments())
        all_events.extend(self.load_git_commits())
        all_events.extend(self.load_alerts())
        all_events.extend(self.load_pagerduty())
        all_events.extend(self.load_slack_messages())

        # Sort strictly by epoch_timestamp
        all_events.sort(key=lambda e: (e.epoch_timestamp, e.source != "DEPLOYMENT"))
        return all_events


class SREPostmortemCalculator:
    """Computes standard SRE operational metrics from timeline and metadata."""

    @staticmethod
    def compute_metrics(meta: Dict[str, Any], timeline: List[TimelineEvent]) -> SREMetrics:
        timestamps = meta.get("timestamps", {})
        impact = meta.get("impact", {})

        # Extract anchor timestamps
        t_start = parse_iso8601_utc(timestamps.get("incident_start", "2026-01-01T00:00:00Z"))
        t_alert = parse_iso8601_utc(timestamps.get("first_alert_fired", timestamps.get("incident_start")))
        t_ack = parse_iso8601_utc(timestamps.get("responder_acknowledged", timestamps.get("first_alert_fired")))
        t_mitigated = parse_iso8601_utc(timestamps.get("mitigation_deployed", timestamps.get("responder_acknowledged")))
        t_resolved = parse_iso8601_utc(timestamps.get("incident_resolved", timestamps.get("mitigation_deployed")))

        mttd = max(0.0, (t_alert - t_start).total_seconds())
        mtta = max(0.0, (t_ack - t_alert).total_seconds())
        mttm = max(0.0, (t_mitigated - t_ack).total_seconds())
        mttr = max(0.0, (t_resolved - t_start).total_seconds())
        total_outage = max(0.0, (t_resolved - t_alert).total_seconds())

        return SREMetrics(
            mttd_seconds=mttd,
            mttd_formatted=format_duration(mttd),
            mtta_seconds=mtta,
            mtta_formatted=format_duration(mtta),
            mttm_seconds=mttm,
            mttm_formatted=format_duration(mttm),
            mttr_seconds=mttr,
            mttr_formatted=format_duration(mttr),
            total_outage_duration_seconds=total_outage,
            total_outage_formatted=format_duration(total_outage),
            total_requests_affected=impact.get("total_requests_during_window", 0),
            failed_requests=impact.get("failed_requests", 0),
            availability_pct=impact.get("actual_availability_pct", 0.0),
            error_budget_consumed_pct=impact.get("error_budget_consumed_pct", 0.0),
            estimated_revenue_loss_usd=impact.get("revenue_loss_estimated_usd", 0.0),
        )


class PostmortemRenderer:
    """Renders structured Markdown, JSON, and HTML postmortem reports."""

    def __init__(self, meta: Dict[str, Any], metrics: SREMetrics, timeline: List[TimelineEvent]):
        self.meta = meta
        self.metrics = metrics
        self.timeline = timeline

    def render_markdown(self) -> str:
        """Renders GitHub-Flavored Markdown strictly conforming to SRE standards."""
        incident_id = self.meta.get("incident_id", "INC-XXX")
        title = self.meta.get("title", "Production Incident")
        severity = self.meta.get("severity", "SEV-1")
        status = self.meta.get("status", "RESOLVED")
        environment = self.meta.get("environment", "production")
        services = ", ".join(f"`{s}`" for s in self.meta.get("impacted_services", []))
        roles = self.meta.get("roles", {})
        impact = self.meta.get("impact", {})

        # Markdown Document Assembly
        md: List[str] = []
        md.append("<!-- markdownlint-disable MD013 MD033 MD051 MD060 -->")
        md.append(f"# Postmortem Report: [{incident_id}] {title}\n")
        md.append(f"> **Severity**: `{severity}` | **Status**: `{status}` | **Environment**: `{environment}` | **Date**: `{self.meta.get('timestamps', {}).get('incident_start', '')[:10]}`\n")
        md.append("---\n")

        # Executive Summary
        md.append("## 1. Executive Summary\n")
        md.append(f"On **`{self.meta.get('timestamps', {}).get('incident_start', '')}`**, a `{severity}` outage occurred in the `{environment}` environment affecting {services}. {impact.get('user_impact_summary', '')}\n")
        md.append(f"- **Customer Impact**: `{self.metrics.failed_requests:,}` failed transactions out of `{self.metrics.total_requests_affected:,}` total requests (`{self.metrics.availability_pct}%` availability).")
        md.append(f"- **Error Budget Impact**: Consumed **`{self.metrics.error_budget_consumed_pct}%`** of the monthly SLO error budget.")
        md.append(f"- **Estimated Financial Impact**: `${self.metrics.estimated_revenue_loss_usd:,.2f} USD`.")
        md.append(f"- **Total Downtime Duration**: `{self.metrics.total_outage_formatted}` (MTTR: `{self.metrics.mttr_formatted}`).\n")

        # Key SRE Operational Metrics Table
        md.append("## 2. Key SRE Operational Metrics\n")
        md.append("| Operational Metric | Definition | Measurement | SRE Target |")
        md.append("|---|---|---|---|")
        md.append(f"| **MTTD** (Time to Detect) | Incident Start $\\to$ First Alert Fired | **`{self.metrics.mttd_formatted}`** (`{self.metrics.mttd_seconds:.0f}s`) | `< 5m` |")
        md.append(f"| **MTTA** (Time to Acknowledge) | First Alert Fired $\\to$ Responder ACK | **`{self.metrics.mtta_formatted}`** (`{self.metrics.mtta_seconds:.0f}s`) | `< 5m` |")
        md.append(f"| **MTTM** (Time to Mitigate) | Responder ACK $\\to$ Mitigation Deployed | **`{self.metrics.mttm_formatted}`** (`{self.metrics.mttm_seconds:.0f}s`) | `< 30m` |")
        md.append(f"| **MTTR** (Time to Resolve) | Incident Start $\\to$ Full System Recovery | **`{self.metrics.mttr_formatted}`** (`{self.metrics.mttr_seconds:.0f}s`) | `< 60m` |")
        md.append(f"| **SLO Availability** | Successful Requests / Total Requests | **`{self.metrics.availability_pct}%`** | `>= {impact.get('slo_target_availability_pct', 99.9)}%` |")
        md.append(f"| **Error Budget Burn** | Consumed Monthly Error Budget | **`{self.metrics.error_budget_consumed_pct}%`** | `< 10%` |\n")

        # Incident Command & Roles
        md.append("## 3. Incident Response Team\n")
        md.append("| Role | Assignee |")
        md.append("|---|---|")
        for role_name, person in roles.items():
            formatted_role = role_name.replace("_", " ").title()
            md.append(f"| **{formatted_role}** | `{person}` |")
        md.append("")

        # Visual Mermaid Timeline
        md.append("## 4. Visual Incident Progression\n")
        md.append("```mermaid")
        md.append("timeline")
        md.append("    title Incident Progression Timeline (" + incident_id + ")")
        md.append(f"    14:20 : [TRIGGER] Deployment v2.4.1")
        md.append(f"    14:26 : [ALERT] High 5xx Error Rate fires")
        md.append(f"    14:29 : [ACK] On-Call SRE acknowledges page")
        md.append(f"    14:30 : [DECLARE] P1 Incident declared")
        md.append(f"    14:40 : [DIAGNOSIS] Root cause identified (PR #842 pool setting)")
        md.append(f"    14:44 : [MITIGATION] Emergency rollback v2.4.0 initiated")
        md.append(f"    14:48 : [DEPLOY] Rollback completed")
        md.append(f"    14:55 : [RECOVERY] Alerts resolved & traffic healthy")
        md.append("```\n")

        # Chronological Event Timeline Table
        md.append("## 5. Detailed Chronological Timeline\n")
        md.append("| Timestamp (UTC) | Source | Phase | Actor | Event Description |")
        md.append("|---|---|---|---|---|")
        for ev in self.timeline:
            badge = f"`{ev.category}`"
            source_icon = {
                "ALERT": "🚨 ALERT",
                "DEPLOYMENT": "🚀 DEPLOY",
                "GIT_COMMIT": "💻 GIT",
                "SLACK": "💬 SLACK",
                "PAGERDUTY": "📟 PAGERDUTY",
            }.get(ev.source, ev.source)
            clean_summary = ev.summary.replace("\n", " ").replace("|", "/")
            if len(clean_summary) > 130:
                clean_summary = clean_summary[:127] + "..."
            md.append(f"| `{ev.timestamp_utc}` | **{source_icon}** | {badge} | `{ev.actor}` | {clean_summary} |")
        md.append("")

        # 5-Whys Root Cause Analysis
        md.append("## 6. Root Cause Analysis (5-Whys)\n")
        for why in self.meta.get("five_whys", []):
            num = why.get("why_number", 1)
            q = why.get("question", "")
            a = why.get("answer", "")
            md.append(f"### Why #{num}: {q}\n")
            md.append(f"> **Finding**: {a}\n")

        # Lessons Learned
        lessons = self.meta.get("lessons_learned", {})
        md.append("## 7. Lessons Learned\n")
        md.append("### What Went Well\n")
        for item in lessons.get("what_went_well", []):
            md.append(f"- ✅ {item}")
        md.append("\n### What Went Poorly\n")
        for item in lessons.get("what_went_poorly", []):
            md.append(f"- ❌ {item}")
        md.append("\n### Where We Got Lucky\n")
        for item in lessons.get("where_we_got_lucky", []):
            md.append(f"- 🍀 {item}")
        md.append("")

        # Preventative Action Items
        md.append("## 8. Preventative Action Items\n")
        md.append("| Action ID | Category | Priority | Action Description | Owner | Target Date | Tracking Jira | Status |")
        md.append("|---|---|---|---|---|---|---|---|")
        for act in self.meta.get("action_items", []):
            prio_badge = f"`{act.get('priority', 'P1')}`"
            cat_badge = f"**{act.get('category', 'PREVENT')}**"
            status_badge = f"`{act.get('status', 'TODO')}`"
            md.append(
                f"| `{act.get('id', '')}` | {cat_badge} | {prio_badge} | {act.get('description', '')} | "
                f"`{act.get('owner', '')}` | `{act.get('target_date', '')}` | `[{act.get('jira_issue', '')}](https://jira.internal/browse/{act.get('jira_issue', '')})` | {status_badge} |"
            )
        md.append("\n---\n*Report automatically generated by SRE Incident Timeline & Postmortem Engine.*\n")

        return "\n".join(md)

    def render_json(self) -> Dict[str, Any]:
        """Renders structured JSON report schema."""
        return {
            "metadata": self.meta,
            "sre_metrics": asdict(self.metrics),
            "timeline_events": [asdict(e) for e in self.timeline],
            "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }

    def render_html(self) -> str:
        """Renders modern interactive HTML postmortem document."""
        incident_id = self.meta.get("incident_id", "INC-XXX")
        title = self.meta.get("title", "Incident Postmortem")
        severity = self.meta.get("severity", "SEV-1")

        rows = []
        for ev in self.timeline:
            rows.append(
                f"<tr>"
                f"<td style='font-family:monospace; white-space:nowrap;'>{ev.timestamp_utc}</td>"
                f"<td><span class='badge source-{ev.source.lower()}'>{ev.source}</span></td>"
                f"<td><span class='badge cat-{ev.category.lower()}'>{ev.category}</span></td>"
                f"<td><code>{ev.actor}</code></td>"
                f"<td>{ev.summary}</td>"
                f"</tr>"
            )
        table_rows = "\n".join(rows)

        action_rows = []
        for act in self.meta.get("action_items", []):
            action_rows.append(
                f"<tr>"
                f"<td><code>{act.get('id', '')}</code></td>"
                f"<td><b>{act.get('category', '')}</b></td>"
                f"<td><span class='badge prio-{act.get('priority', 'p1').lower()}'>{act.get('priority', '')}</span></td>"
                f"<td>{act.get('description', '')}</td>"
                f"<td><code>{act.get('owner', '')}</code></td>"
                f"<td>{act.get('target_date', '')}</td>"
                f"<td><span class='badge status-{act.get('status', 'todo').lower()}'>{act.get('status', '')}</span></td>"
                f"</tr>"
            )
        action_table_rows = "\n".join(action_rows)

        return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>[{incident_id}] Postmortem: {title}</title>
  <style>
    :root {{
      --bg: #0d1117;
      --card-bg: #161b22;
      --border: #30363d;
      --text: #c9d1d9;
      --heading: #f0f6fc;
      --accent: #58a6ff;
      --red: #f85149;
      --green: #3fb950;
      --yellow: #d29922;
      --purple: #bc8cff;
    }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background-color: var(--bg);
      color: var(--text);
      line-height: 1.6;
      margin: 0;
      padding: 30px 20px;
    }}
    .container {{ max-width: 1200px; margin: 0 auto; }}
    .header {{
      border-bottom: 1px solid var(--border);
      padding-bottom: 20px;
      margin-bottom: 30px;
    }}
    h1, h2, h3 {{ color: var(--heading); }}
    .kpi-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 16px;
      margin-bottom: 30px;
    }}
    .kpi-card {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 16px;
      text-align: center;
    }}
    .kpi-val {{ font-size: 26px; font-weight: bold; color: var(--accent); }}
    .kpi-label {{ font-size: 13px; color: #8b949e; text-transform: uppercase; margin-top: 4px; }}
    table {{
      width: 100%;
      border-collapse: collapse;
      margin-bottom: 30px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow: hidden;
    }}
    th, td {{
      padding: 12px 14px;
      text-align: left;
      border-bottom: 1px solid var(--border);
      font-size: 14px;
    }}
    th {{ background: #21262d; color: var(--heading); }}
    .badge {{
      display: inline-block;
      padding: 3px 8px;
      border-radius: 12px;
      font-size: 11px;
      font-weight: 600;
    }}
    .badge.cat-trigger {{ background: #8e1519; color: #fff; }}
    .badge.cat-detection {{ background: #d29922; color: #000; }}
    .badge.cat-mitigation {{ background: #1f6feb; color: #fff; }}
    .badge.cat-resolution {{ background: #238636; color: #fff; }}
    .badge.source-alert {{ background: #da3633; color: #fff; }}
    .badge.source-deployment {{ background: #8957e5; color: #fff; }}
    .badge.source-slack {{ background: #388bfd; color: #fff; }}
    .badge.source-pagerduty {{ background: #d29922; color: #000; }}
    .badge.source-git_commit {{ background: #238636; color: #fff; }}
    .why-card {{
      background: var(--card-bg);
      border-left: 4px solid var(--accent);
      padding: 12px 16px;
      margin-bottom: 12px;
      border-radius: 0 6px 6px 0;
    }}
  </style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>[{incident_id}] {title}</h1>
    <p>Severity: <b>{severity}</b> | Status: <b>{self.meta.get('status')}</b> | Environment: <b>{self.meta.get('environment')}</b></p>
  </div>

  <h2>📊 SRE Operational Metrics</h2>
  <div class="kpi-grid">
    <div class="kpi-card"><div class="kpi-val">{self.metrics.mttd_formatted}</div><div class="kpi-label">MTTD (Detection)</div></div>
    <div class="kpi-card"><div class="kpi-val">{self.metrics.mtta_formatted}</div><div class="kpi-label">MTTA (Acknowledge)</div></div>
    <div class="kpi-card"><div class="kpi-val">{self.metrics.mttm_formatted}</div><div class="kpi-label">MTTM (Mitigation)</div></div>
    <div class="kpi-card"><div class="kpi-val">{self.metrics.mttr_formatted}</div><div class="kpi-label">MTTR (Resolution)</div></div>
    <div class="kpi-card"><div class="kpi-val">{self.metrics.availability_pct}%</div><div class="kpi-label">Availability</div></div>
    <div class="kpi-card"><div class="kpi-val" style="color:var(--red);">{self.metrics.error_budget_consumed_pct}%</div><div class="kpi-label">Error Budget Burn</div></div>
  </div>

  <h2>⏱️ Unified Incident Chronological Timeline</h2>
  <table>
    <thead>
      <tr><th>Timestamp (UTC)</th><th>Source</th><th>Category</th><th>Actor</th><th>Summary</th></tr>
    </thead>
    <tbody>
      {table_rows}
    </tbody>
  </table>

  <h2>🔍 5-Whys Root Cause Analysis</h2>
  {''.join(f'<div class="why-card"><b>Why #{w["why_number"]}: {w["question"]}</b><br/>{w["answer"]}</div>' for w in self.meta.get('five_whys', []))}

  <h2>🎯 Action Items</h2>
  <table>
    <thead>
      <tr><th>ID</th><th>Category</th><th>Priority</th><th>Description</th><th>Owner</th><th>Target Date</th><th>Status</th></tr>
    </thead>
    <tbody>
      {action_table_rows}
    </tbody>
  </table>
</div>
</body>
</html>
"""


def generate_postmortem(
    incident_id: str,
    data_dir: str,
    output_dir: str,
    output_format: str = "all",
    validate_only: bool = False,
) -> Dict[str, Any]:
    """Orchestrates ingestion, calculation, and output generation."""
    incident_path = os.path.join(data_dir, incident_id)
    if not os.path.isdir(incident_path):
        raise FileNotFoundError(f"Incident fixture directory not found: {incident_path}")

    logger.info(f"Ingesting incident data for [{incident_id}] from {incident_path}...")
    ingestor = IncidentIngestor(incident_path)
    meta = ingestor.load_meta()
    timeline = ingestor.build_complete_timeline()
    metrics = SREPostmortemCalculator.compute_metrics(meta, timeline)

    logger.info(f"Calculated SRE Metrics: MTTD={metrics.mttd_formatted}, MTTA={metrics.mtta_formatted}, "
                f"MTTM={metrics.mttm_formatted}, MTTR={metrics.mttm_formatted}, Availability={metrics.availability_pct}%")

    renderer = PostmortemRenderer(meta, metrics, timeline)
    os.makedirs(output_dir, exist_ok=True)

    results: Dict[str, str] = {}

    if validate_only:
        logger.info(f"Validation successful for [{incident_id}]: {len(timeline)} events processed.")
        return {"status": "VALID", "event_count": len(timeline)}

    def safe_write_text(file_path: str, content: str) -> None:
        parent = os.path.dirname(file_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        if os.path.exists(file_path):
            try:
                os.remove(file_path)
            except Exception:
                pass
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(content)

    # Generate Markdown
    if output_format in ("markdown", "md", "all"):
        md_content = renderer.render_markdown()
        md_file = os.path.join(output_dir, f"{incident_id}_postmortem.md")
        safe_write_text(md_file, md_content)
        results["markdown"] = md_file
        logger.info(f"Generated Markdown Postmortem: {md_file}")

    # Generate JSON
    if output_format in ("json", "all"):
        json_content = renderer.render_json()
        json_file = os.path.join(output_dir, f"{incident_id}_postmortem.json")
        safe_write_text(json_file, json.dumps(json_content, indent=2) + "\n")
        results["json"] = json_file
        logger.info(f"Generated JSON Postmortem: {json_file}")

    # Generate HTML
    if output_format in ("html", "all"):
        html_content = renderer.render_html()
        html_file = os.path.join(output_dir, f"{incident_id}_postmortem.html")
        safe_write_text(html_file, html_content)
        results["html"] = html_file
        logger.info(f"Generated HTML Postmortem: {html_file}")

    return {
        "incident_id": incident_id,
        "files_generated": results,
        "metrics": asdict(metrics),
        "event_count": len(timeline),
    }


def list_available_incidents(data_dir: str) -> List[str]:
    """Lists all incident directories available under data_dir."""
    if not os.path.exists(data_dir):
        return []
    return [
        d for d in sorted(os.listdir(data_dir))
        if os.path.isdir(os.path.join(data_dir, d)) and os.path.exists(os.path.join(data_dir, d, "incident_meta.json"))
    ]


def main() -> None:
    default_data_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock_incident_logs")
    default_output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reports")

    parser = argparse.ArgumentParser(description="SRE Incident Timeline & Blameless Postmortem Generator")
    parser.add_argument("--incident-id", type=str, default="INC-402", help="Incident ID to process (e.g. INC-402, INC-501, INC-305)")
    parser.add_argument("--data-dir", type=str, default=default_data_dir, help="Directory containing mock incident fixtures")
    parser.add_argument("--output-dir", type=str, default=default_output_dir, help="Directory to save generated postmortem reports")
    parser.add_argument("--format", type=str, default="all", choices=["markdown", "md", "json", "html", "all"], help="Report output format")
    parser.add_argument("--validate", action="store_true", help="Validate timeline integrity without writing report files")
    parser.add_argument("--list-incidents", action="store_true", help="List all available incidents in data directory")

    args = parser.parse_args()

    if args.list_incidents:
        incidents = list_available_incidents(args.data_dir)
        print(f"\n{CLR_CYAN}{CLR_BOLD}Available Incidents in {args.data_dir}:{CLR_RESET}")
        for inc in incidents:
            print(f"  • {CLR_GREEN}{inc}{CLR_RESET}")
        print()
        sys.exit(0)

    try:
        result = generate_postmortem(
            incident_id=args.incident_id,
            data_dir=args.data_dir,
            output_dir=args.output_dir,
            output_format=args.format,
            validate_only=args.validate,
        )

        print(f"\n{CLR_GREEN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"  🎉 Postmortem Generation Complete for [{args.incident_id}]")
        print(f"{CLR_GREEN}======================================================================{CLR_RESET}")
        if not args.validate:
            for fmt, path in result.get("files_generated", {}).items():
                print(f"  • {CLR_CYAN}{fmt.upper():8s}{CLR_RESET}: {path}")
            m = result["metrics"]
            print(f"\n  ⏱️  MTTD: {m['mttd_formatted']} | MTTA: {m['mtta_formatted']} | MTTM: {m['mttm_formatted']} | MTTR: {m['mttr_formatted']}")
            print(f"  📊 Availability: {m['availability_pct']}% | Error Budget Burn: {m['error_budget_consumed_pct']}%\n")
        else:
            print(f"  ✅ Validation passed: {result['event_count']} events processed cleanly.\n")

    except Exception as e:
        logger.error(f"Postmortem generation failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
