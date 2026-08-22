"""
app.py - Mock Slack & Alertmanager Webhook Sandbox Server

Receives Alertmanager webhook notifications, formats alert cards with ANSI colors
(simulating Slack/Discord message attachments), and provides a queryable API
for automated integration test assertions.
"""

import sys
import time
from typing import Any, Dict, List
from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_RED = "\033[1;31m"
CLR_GREEN = "\033[1;32m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"

app = FastAPI(title="Alertmanager Mock Webhook Receiver & Slack Sandbox", version="1.0.0")

# In-memory alert log
received_alerts: List[Dict[str, Any]] = []


@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "webhook-receiver", "alerts_count": len(received_alerts)}


@app.post("/webhook/{channel}")
async def receive_alertmanager_webhook(channel: str, request: Request):
    """
    Receives Alertmanager webhook payload, parses individual alerts,
    formats a simulated Slack message card to stdout, and stores in history.
    """
    try:
        payload = await request.json()
    except Exception:
        payload = {}

    status_str = payload.get("status", "unknown").upper()
    alerts = payload.get("alerts", [])
    common_labels = payload.get("commonLabels", {})
    common_annotations = payload.get("commonAnnotations", {})

    status_color = CLR_RED if status_str == "FIRING" else CLR_GREEN
    icon = "🚨" if status_str == "FIRING" else "✅"

    print(f"\n{status_color}{CLR_BOLD}┌────────────────────────────────────────────────────────────────────────┐{CLR_RESET}")
    print(f"{status_color}{CLR_BOLD}│ {icon} [SLACK NOTIFICATION] Channel: #{channel:<20} Status: {status_str:<10} │{CLR_RESET}")
    print(f"{status_color}├────────────────────────────────────────────────────────────────────────┤{CLR_RESET}")

    for idx, alert in enumerate(alerts, 1):
        alert_name = alert.get("labels", {}).get("alertname", "UnknownAlert")
        severity = alert.get("labels", {}).get("severity", "info").upper()
        service = alert.get("labels", {}).get("service", "generic")
        summary = alert.get("annotations", {}).get("summary", "No summary provided")
        desc = alert.get("annotations", {}).get("description", "No description provided")
        starts_at = alert.get("startsAt", "")

        sev_color = CLR_RED if severity == "CRITICAL" else CLR_YELLOW

        print(f"│ {CLR_BOLD}Alert #{idx}:{CLR_RESET} {CLR_WHITE}{alert_name}{CLR_RESET} [{sev_color}{severity}{CLR_RESET}] Service: {CLR_CYAN}{service}{CLR_RESET}")
        print(f"│ {CLR_GRAY}Summary    :{CLR_RESET} {summary}")
        print(f"│ {CLR_GRAY}Description:{CLR_RESET} {desc}")
        print(f"│ {CLR_GRAY}Started At :{CLR_RESET} {starts_at}")

        # Store in historical record
        received_alerts.append({
            "received_at": time.time(),
            "channel": channel,
            "status": alert.get("status", status_str.lower()),
            "alertname": alert_name,
            "severity": severity.lower(),
            "service": service,
            "summary": summary,
            "labels": alert.get("labels", {}),
            "annotations": alert.get("annotations", {}),
        })

    print(f"{status_color}└────────────────────────────────────────────────────────────────────────┘{CLR_RESET}\n")
    sys.stdout.flush()

    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content={"status": "received", "channel": channel, "alerts_processed": len(alerts)},
    )


@app.get("/api/alerts/received")
def get_received_alerts():
    """Returns all alerts recorded by the webhook receiver."""
    return {
        "count": len(received_alerts),
        "alerts": received_alerts,
    }


@app.delete("/api/alerts/clear")
def clear_alerts():
    """Clears received alert history."""
    received_alerts.clear()
    return {"status": "cleared", "count": 0}
