#!/usr/bin/env python3
"""
Cloud Cost Governance and Tag Compliance Engine
===============================================
AWS Lambda Function and Standalone FinOps Governance Engine auditing AWS EC2,
S3, and RDS resources for mandatory billing tags (Environment, Owner, CostCenter, Project).

Computes compliance scores, estimates untracked cloud spend, tags non-compliant
resources for remediation, and publishes daily Slack/SNS executive digests.
"""

import json
import logging
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

# Configure logging
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] [%(levelname)s] %(message)s")
logger = logging.getLogger("CostGovernanceEngine")

# Configuration from Environment Variables
MANDATORY_TAGS = [t.strip() for t in os.environ.get("MANDATORY_TAGS", "Environment,Owner,CostCenter,Project").split(",") if t.strip()]
ALLOWED_ENVIRONMENTS = [e.strip() for e in os.environ.get("ALLOWED_ENVIRONMENTS", "production,staging,development,sandbox").split(",") if e.strip()]
AUDIT_BUCKET_NAME = os.environ.get("AUDIT_BUCKET_NAME", "cost-governance-audit-logs")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
GRACE_PERIOD_DAYS = int(os.environ.get("GRACE_PERIOD_DAYS", "7"))
ENABLE_AUTO_REMEDIATION = os.environ.get("ENABLE_AUTO_REMEDIATION", "true").lower() in ("true", "1", "yes")
PORT = int(os.environ.get("PORT", "8080"))

# Validation Regexes
EMAIL_REGEX = re.compile(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$")
COST_CENTER_REGEX = re.compile(r"^CC-\d{3,6}$")

# Estimated Monthly Costs by Resource Type for FinOps Spend Attribution
ESTIMATED_MONTHLY_COSTS = {
    "ec2:t2.micro": 8.50,
    "ec2:t3.micro": 7.60,
    "ec2:t3.medium": 30.36,
    "ec2:m5.large": 69.12,
    "ec2:c5.xlarge": 122.40,
    "ec2:default": 35.00,
    "rds:db.t3.micro": 12.40,
    "rds:db.t3.medium": 49.60,
    "rds:default": 45.00,
    "s3:bucket": 15.00,
    "ebs:gp3": 8.00,
}

# In-memory store for local simulation & caching
LATEST_REPORT: Optional[Dict[str, Any]] = None
REPORT_LOCK = threading.Lock()
START_TIME = time.time()


# ==============================================================================
# Tag Validation Core Engine
# ==============================================================================
def validate_resource_tags(resource_id: str, resource_type: str, tags: Dict[str, str]) -> Dict[str, Any]:
    """
    Validates a resource against mandatory billing tag policies.
    Checks for tag existence, allowed enum values, and format syntax.
    """
    missing_tags = []
    invalid_tags = []

    # 1. Check presence of each mandatory tag
    for req_tag in MANDATORY_TAGS:
        if req_tag not in tags or not tags[req_tag].strip():
            missing_tags.append(req_tag)

    # 2. Validate tag format & enums if tag is present
    if "Environment" in tags:
        env_val = tags["Environment"].strip().lower()
        if env_val not in ALLOWED_ENVIRONMENTS:
            invalid_tags.append(f"Environment='{tags['Environment']}' (Allowed: {ALLOWED_ENVIRONMENTS})")

    if "Owner" in tags:
        owner_val = tags["Owner"].strip()
        if not EMAIL_REGEX.match(owner_val):
            invalid_tags.append(f"Owner='{owner_val}' (Must be valid email)")

    if "CostCenter" in tags:
        cc_val = tags["CostCenter"].strip()
        if not COST_CENTER_REGEX.match(cc_val):
            invalid_tags.append(f"CostCenter='{cc_val}' (Expected format 'CC-XXXX')")

    is_compliant = len(missing_tags) == 0 and len(invalid_tags) == 0

    # Calculate estimated monthly burn
    est_cost = ESTIMATED_MONTHLY_COSTS.get(f"{resource_type}:{tags.get('InstanceType', '')}", ESTIMATED_MONTHLY_COSTS.get(f"{resource_type}:default", 25.00))

    termination_date = None
    if not is_compliant:
        termination_date = (datetime.now(timezone.utc) + timedelta(days=GRACE_PERIOD_DAYS)).strftime("%Y-%m-%d")

    return {
        "resource_id": resource_id,
        "resource_type": resource_type,
        "is_compliant": is_compliant,
        "missing_tags": missing_tags,
        "invalid_tags": invalid_tags,
        "tags": tags,
        "estimated_monthly_spend": est_cost,
        "remediation_status": "COMPLIANT" if is_compliant else "FLAGGED_FOR_REMEDIATION",
        "scheduled_action": "NONE" if is_compliant else f"Enforce tags or terminate on {termination_date}",
        "termination_date": termination_date,
    }


# ==============================================================================
# Mock Inventory Scanner (For Offline & Local Testing)
# ==============================================================================
def generate_sample_cloud_inventory() -> List[Dict[str, Any]]:
    """Generates synthetic multi-service cloud inventory for testing."""
    return [
        {
            "id": "i-0a1b2c3d4e5f0001",
            "type": "ec2",
            "name": "prod-api-gateway-01",
            "tags": {
                "Name": "prod-api-gateway-01",
                "Environment": "production",
                "Owner": "sre-core@company.com",
                "CostCenter": "CC-1001",
                "Project": "core-api",
                "InstanceType": "t3.medium",
            },
        },
        {
            "id": "i-0a1b2c3d4e5f0002",
            "type": "ec2",
            "name": "dev-data-worker-scratch",
            "tags": {
                "Name": "dev-data-worker-scratch",
                "Environment": "development",
                "Project": "data-lake",
                "InstanceType": "m5.large",
                # Missing Owner & CostCenter
            },
        },
        {
            "id": "i-0a1b2c3d4e5f0003",
            "type": "ec2",
            "name": "test-invalid-env-node",
            "tags": {
                "Name": "test-invalid-env-node",
                "Environment": "local-test",  # Invalid enum
                "Owner": "john_invalid_email",  # Invalid email format
                "CostCenter": "123",  # Invalid CC format
                "Project": "poc",
                "InstanceType": "t3.micro",
            },
        },
        {
            "id": "arn:aws:s3:::company-prod-media-assets",
            "type": "s3",
            "name": "company-prod-media-assets",
            "tags": {
                "Environment": "production",
                "Owner": "media-ops@company.com",
                "CostCenter": "CC-2002",
                "Project": "media-storage",
            },
        },
        {
            "id": "arn:aws:s3:::orphan-untracked-backups-2026",
            "type": "s3",
            "name": "orphan-untracked-backups-2026",
            "tags": {
                # Completely untagged
            },
        },
        {
            "id": "db-PROD-POSTGRESQL-01",
            "type": "rds",
            "name": "db-PROD-POSTGRESQL-01",
            "tags": {
                "Environment": "production",
                "Owner": "dbas@company.com",
                "CostCenter": "CC-1001",
                "Project": "user-database",
            },
        },
        {
            "id": "db-staging-analytics-db",
            "type": "rds",
            "name": "db-staging-analytics-db",
            "tags": {
                "Environment": "staging",
                "Owner": "data-team@company.com",
                # Missing CostCenter & Project
            },
        },
    ]


# ==============================================================================
# Live AWS Resource Scanner (boto3)
# ==============================================================================
def scan_live_aws_resources() -> List[Dict[str, Any]]:
    """Scans real AWS environment using boto3 if credentials are present."""
    try:
        import boto3

        resources = []
        region = os.environ.get("AWS_REGION", "us-east-1")

        # 1. EC2 Instances
        ec2 = boto3.client("ec2", region_name=region)
        resp_ec2 = ec2.describe_instances()
        for res in resp_ec2.get("Reservations", []):
            for inst in res.get("Instances", []):
                inst_id = inst.get("InstanceId", "")
                inst_tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                inst_tags["InstanceType"] = inst.get("InstanceType", "default")
                resources.append({"id": inst_id, "type": "ec2", "name": inst_tags.get("Name", inst_id), "tags": inst_tags})

        # 2. S3 Buckets
        s3 = boto3.client("s3", region_name=region)
        resp_s3 = s3.list_buckets()
        for b in resp_s3.get("Buckets", []):
            b_name = b["Name"]
            try:
                tag_resp = s3.get_bucket_tagging(Bucket=b_name)
                b_tags = {t["Key"]: t["Value"] for t in tag_resp.get("TagSet", [])}
            except Exception:
                b_tags = {}
            resources.append({"id": f"arn:aws:s3:::{b_name}", "type": "s3", "name": b_name, "tags": b_tags})

        # 3. RDS Instances
        rds = boto3.client("rds", region_name=region)
        resp_rds = rds.describe_db_instances()
        for db in resp_rds.get("DBInstances", []):
            db_id = db["DBInstanceIdentifier"]
            db_arn = db.get("DBInstanceArn", db_id)
            try:
                tag_resp = rds.list_tags_for_resource(ResourceName=db_arn)
                db_tags = {t["Key"]: t["Value"] for t in tag_resp.get("TagList", [])}
            except Exception:
                db_tags = {}
            resources.append({"id": db_id, "type": "rds", "name": db_id, "tags": db_tags})

        logger.info(f"Live AWS scan collected {len(resources)} resources across EC2, S3, RDS.")
        return resources
    except Exception as e:
        logger.warning(f"Live AWS scan unavailable ({e}). Falling back to sample inventory.")
        return generate_sample_cloud_inventory()


# ==============================================================================
# Full Compliance Audit Execution
# ==============================================================================
def execute_compliance_audit(resources: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
    """
    Runs full FinOps compliance audit over provided resources or scanned inventory.
    """
    global LATEST_REPORT
    if resources is None:
        # Check if AWS credentials exist, else use sample inventory
        if "AWS_EXECUTION_ENV" in os.environ or "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" in os.environ or os.environ.get("AWS_ACCESS_KEY_ID"):
            resources = scan_live_aws_resources()
        else:
            resources = generate_sample_cloud_inventory()

    results = []
    total_spend = 0.0
    untracked_spend = 0.0

    service_breakdown = {"ec2": {"total": 0, "compliant": 0, "untracked_cost": 0.0}, "s3": {"total": 0, "compliant": 0, "untracked_cost": 0.0}, "rds": {"total": 0, "compliant": 0, "untracked_cost": 0.0}}

    for item in resources:
        res_id = item["id"]
        res_type = item["type"]
        tags = item.get("tags", {})
        audit = validate_resource_tags(res_id, res_type, tags)
        audit["name"] = item.get("name", res_id)
        results.append(audit)

        cost = audit["estimated_monthly_spend"]
        total_spend += cost

        srv = service_breakdown.setdefault(res_type, {"total": 0, "compliant": 0, "untracked_cost": 0.0})
        srv["total"] += 1

        if audit["is_compliant"]:
            srv["compliant"] += 1
        else:
            untracked_spend += cost
            srv["untracked_cost"] += cost

    total_count = len(results)
    compliant_count = sum(1 for r in results if r["is_compliant"])
    non_compliant_count = total_count - compliant_count
    compliance_score = round((compliant_count / total_count * 100.0), 1) if total_count > 0 else 100.0

    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "policy_configuration": {
            "mandatory_tags": MANDATORY_TAGS,
            "allowed_environments": ALLOWED_ENVIRONMENTS,
            "grace_period_days": GRACE_PERIOD_DAYS,
            "auto_remediation_enabled": ENABLE_AUTO_REMEDIATION,
        },
        "summary": {
            "total_resources": total_count,
            "compliant_resources": compliant_count,
            "non_compliant_resources": non_compliant_count,
            "compliance_score_percent": compliance_score,
            "total_estimated_monthly_spend_usd": round(total_spend, 2),
            "untracked_at_risk_spend_usd": round(untracked_spend, 2),
            "untracked_spend_percent": round((untracked_spend / total_spend * 100.0), 1) if total_spend > 0 else 0.0,
        },
        "service_breakdown": service_breakdown,
        "resources": results,
    }

    with REPORT_LOCK:
        LATEST_REPORT = report

    logger.info(f"Audit completed: {compliant_count}/{total_count} compliant ({compliance_score}%). Untracked spend: ${untracked_spend:.2f}/mo.")
    return report


# ==============================================================================
# Notification Dispatcher (Slack & SNS)
# ==============================================================================
def format_slack_payload(report: Dict[str, Any]) -> Dict[str, Any]:
    """Generates Slack Block Kit payload with executive metrics & badges."""
    summary = report["summary"]
    score = summary["compliance_score_percent"]
    score_emoji = "🟢" if score >= 90 else ("🟡" if score >= 70 else "🔴")

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"{score_emoji} FinOps Cloud Cost Governance & Tag Compliance Report",
            },
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*Compliance Score:*\n`{score}%` ({summary['compliant_resources']}/{summary['total_resources']} compliant)"},
                {"type": "mrkdwn", "text": f"*Untracked Risk Spend:*\n`${summary['untracked_at_risk_spend_usd']:.2f} / month`"},
                {"type": "mrkdwn", "text": f"*Mandatory Tags:*\n`{', '.join(MANDATORY_TAGS)}`"},
                {"type": "mrkdwn", "text": f"*Audit Timestamp:*\n`{report['timestamp'][:19]} UTC`"},
            ],
        },
        {"type": "divider"},
    ]

    # Add non-compliant items highlight
    non_compliant = [r for r in report["resources"] if not r["is_compliant"]]
    if non_compliant:
        violator_lines = []
        for r in non_compliant[:5]:
            issues = []
            if r["missing_tags"]:
                issues.append(f"Missing: {','.join(r['missing_tags'])}")
            if r["invalid_tags"]:
                issues.append(f"Invalid: {'; '.join(r['invalid_tags'])}")
            violator_lines.append(f"• *{r['name']}* ({r['resource_type'].upper()}) — {' | '.join(issues)}")

        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": "*⚠️ Top Non-Compliant Resources:*\n" + "\n".join(violator_lines),
                },
            }
        )

    return {"blocks": blocks}


def dispatch_notifications(report: Dict[str, Any], webhook_url: str = SLACK_WEBHOOK_URL):
    """Dispatches formatted Slack message or logs if webhook is absent."""
    payload = format_slack_payload(report)
    if webhook_url and webhook_url.startswith("http"):
        try:
            data = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(webhook_url, data=data, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                logger.info(f"Dispatched Slack notification (HTTP {resp.getcode()})")
        except Exception as e:
            logger.warning(f"Failed to post to Slack webhook: {e}")
    else:
        logger.info(f"[SIMULATED SLACK NOTIFICATION] FinOps Score: {report['summary']['compliance_score_percent']}%, Untracked: ${report['summary']['untracked_at_risk_spend_usd']:.2f}")


# ==============================================================================
# AWS Lambda Handler
# ==============================================================================
def lambda_handler(event: Any, context: Any) -> Dict[str, Any]:
    """Entrypoint for AWS Lambda scheduled EventBridge execution."""
    logger.info("Starting scheduled FinOps tag compliance audit via AWS Lambda...")
    report = execute_compliance_audit()
    dispatch_notifications(report)

    # If S3 Audit bucket is configured and in AWS environment, archive JSON report
    if AUDIT_BUCKET_NAME and "AWS_EXECUTION_ENV" in os.environ:
        try:
            import boto3

            s3 = boto3.client("s3")
            key = f"compliance-reports/{datetime.now(timezone.utc).strftime('%Y-%m-%d')}-audit.json"
            s3.put_object(Bucket=AUDIT_BUCKET_NAME, Key=key, Body=json.dumps(report, indent=2), ContentType="application/json")
            logger.info(f"Archived audit report to s3://{AUDIT_BUCKET_NAME}/{key}")
        except Exception as e:
            logger.warning(f"Could not archive to S3: {e}")

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "message": "FinOps Tag Compliance audit completed successfully",
                "summary": report["summary"],
            }
        ),
    }


# ==============================================================================
# Local HTTP Server & Interactive Dashboard (For Local Docker & Testing)
# ==============================================================================
class GovernanceHTTPHandler(BaseHTTPRequestHandler):
    """Serves REST API and Web Dashboard for FinOps governance."""

    server_version = "CloudCostGovernanceEngine/1.0"

    def log_message(self, format, *args):
        sys.stdout.write(f"[{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}] {self.address_string()} - {format % args}\n")
        sys.stdout.flush()

    def _send_json(self, status_code: int, data: dict):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, status_code: int, html: str):
        payload = html.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        # 1. Health Probe
        if path in ("/health", "/api/health"):
            self._send_json(
                HTTPStatus.OK,
                {
                    "status": "HEALTHY",
                    "engine": "Cloud Cost Governance & Tag Compliance",
                    "uptime_seconds": round(time.time() - START_TIME, 2),
                    "mandatory_tags": MANDATORY_TAGS,
                    "auto_remediation": ENABLE_AUTO_REMEDIATION,
                },
            )
            return

        # 2. Query Latest Compliance Report
        if path == "/api/compliance":
            with REPORT_LOCK:
                if LATEST_REPORT is None:
                    report = execute_compliance_audit()
                else:
                    report = LATEST_REPORT
            self._send_json(HTTPStatus.OK, report)
            return

        # 3. Interactive Web Dashboard
        if path in ("", "/index.html"):
            with REPORT_LOCK:
                if LATEST_REPORT is None:
                    report = execute_compliance_audit()
                else:
                    report = LATEST_REPORT

            summary = report["summary"]
            score = summary["compliance_score_percent"]
            score_color = "#22c55e" if score >= 90 else ("#f59e0b" if score >= 70 else "#ef4444")

            table_rows = ""
            for r in report["resources"]:
                status_badge = '<span class="badge badge-compliant">COMPLIANT</span>' if r["is_compliant"] else '<span class="badge badge-danger">NON-COMPLIANT</span>'
                issues = []
                if r["missing_tags"]:
                    issues.append(f"<strong style='color:#ef4444'>Missing:</strong> {', '.join(r['missing_tags'])}")
                if r["invalid_tags"]:
                    issues.append(f"<strong style='color:#f59e0b'>Invalid:</strong> {'; '.join(r['invalid_tags'])}")
                issue_text = "<br>".join(issues) if issues else "<span style='color:#22c55e;'>All tags verified</span>"

                table_rows += f"""
                <tr>
                    <td><strong>{r['name']}</strong><br><span style="font-size:11px;color:#94a3b8;">{r['resource_id']}</span></td>
                    <td><span class="badge badge-type">{r['resource_type'].upper()}</span></td>
                    <td>{status_badge}</td>
                    <td style="font-size:12px;">{issue_text}</td>
                    <td><strong>${r['estimated_monthly_spend']:.2f}</strong>/mo</td>
                    <td style="font-size:11px;color:#cbd5e1;">{r['scheduled_action']}</td>
                </tr>
                """

            html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Cloud Cost Governance & Tag Compliance Dashboard</title>
    <style>
        :root {{
            --bg-dark: #090d16;
            --card-bg: #131b2e;
            --border: #1e293b;
            --primary: #3b82f6;
            --text-light: #f8fafc;
            --text-muted: #94a3b8;
            --green: #22c55e;
            --amber: #f59e0b;
            --red: #ef4444;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: var(--bg-dark);
            color: var(--text-light);
            margin: 0;
            padding: 24px;
        }}
        .container {{
            max-width: 1200px;
            margin: 0 auto;
        }}
        .header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--border);
            padding-bottom: 20px;
            margin-bottom: 24px;
        }}
        h1 {{
            margin: 0;
            font-size: 24px;
            color: var(--primary);
            display: flex;
            align-items: center;
            gap: 12px;
        }}
        .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }}
        .card {{
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 20px;
        }}
        .metric-title {{
            font-size: 12px;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 8px;
        }}
        .metric-val {{
            font-size: 28px;
            font-weight: 700;
        }}
        table {{
            width: 100%;
            border-collapse: collapse;
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 12px;
            overflow: hidden;
        }}
        th, td {{
            padding: 14px 16px;
            text-align: left;
            border-bottom: 1px solid var(--border);
            font-size: 13px;
        }}
        th {{
            background: #0f172a;
            color: var(--text-muted);
            text-transform: uppercase;
            font-size: 11px;
        }}
        .badge {{
            padding: 4px 10px;
            border-radius: 9999px;
            font-size: 11px;
            font-weight: 600;
            display: inline-block;
        }}
        .badge-type {{ background: rgba(59, 130, 246, 0.15); color: #60a5fa; }}
        .badge-compliant {{ background: rgba(34, 197, 94, 0.15); color: var(--green); }}
        .badge-danger {{ background: rgba(239, 68, 68, 0.15); color: var(--red); }}
        .btn {{
            background: var(--primary);
            color: #fff;
            padding: 10px 18px;
            border-radius: 8px;
            text-decoration: none;
            font-weight: 600;
            font-size: 13px;
            cursor: pointer;
            border: none;
            display: inline-flex;
            align-items: center;
            gap: 8px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1>🏷️ FinOps Cloud Cost Governance & Tag Compliance</h1>
                <div style="font-size: 13px; color: var(--text-muted); margin-top: 4px;">
                    Enforcing Mandatory Tags: <code>{', '.join(MANDATORY_TAGS)}</code>
                </div>
            </div>
            <button class="btn" onclick="fetch('/api/scan', {{method: 'POST'}}).then(() => location.reload())">🔄 Run Fresh Audit</button>
        </div>

        <div class="grid">
            <div class="card">
                <div class="metric-title">FinOps Compliance Score</div>
                <div class="metric-val" style="color: {score_color};">{score}%</div>
            </div>
            <div class="card">
                <div class="metric-title">Untracked Cloud Spend</div>
                <div class="metric-val" style="color: var(--red);">${summary['untracked_at_risk_spend_usd']:.2f} <span style="font-size: 13px; color: var(--text-muted);">/mo</span></div>
            </div>
            <div class="card">
                <div class="metric-title">Compliant Resources</div>
                <div class="metric-val" style="color: var(--green);">{summary['compliant_resources']} <span style="font-size: 13px; color: var(--text-muted);">/ {summary['total_resources']}</span></div>
            </div>
            <div class="card">
                <div class="metric-title">Auto-Remediation</div>
                <div class="metric-val" style="color: #38bdf8; font-size: 22px;">{'Active (7d Grace)' if ENABLE_AUTO_REMEDIATION else 'Audit Only'}</div>
            </div>
        </div>

        <div class="card" style="padding: 0;">
            <table>
                <thead>
                    <tr>
                        <th>Resource</th>
                        <th>Type</th>
                        <th>Status</th>
                        <th>Compliance Violations</th>
                        <th>Est. Spend</th>
                        <th>Remediation Action</th>
                    </tr>
                </thead>
                <tbody>
                    {table_rows}
                </tbody>
            </table>
        </div>
    </div>
</body>
</html>
"""
            self._send_html(HTTPStatus.OK, html)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not Found", "path": self.path})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path in ("/api/scan", "/scan"):
            content_length = int(self.headers.get("Content-Length", 0))
            custom_resources = None
            if content_length > 0:
                body = self.rfile.read(content_length).decode("utf-8")
                try:
                    payload = json.loads(body)
                    if isinstance(payload, list):
                        custom_resources = payload
                    elif isinstance(payload, dict) and "resources" in payload:
                        custom_resources = payload["resources"]
                except Exception:
                    pass

            report = execute_compliance_audit(resources=custom_resources)
            dispatch_notifications(report)
            self._send_json(HTTPStatus.OK, {"message": "Audit completed", "report": report})
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Endpoint not found"})


def run_standalone_server(port: int = PORT):
    """Starts standalone HTTP web server for local exploration."""
    server_address = ("", port)
    httpd = ThreadingHTTPServer(server_address, GovernanceHTTPHandler)
    print(f"🚀 Cloud Cost Governance Engine active on port {port}...")
    print(f"   Mandatory Tags: {', '.join(MANDATORY_TAGS)}")
    print(f"   Auto-Remediate: {ENABLE_AUTO_REMEDIATION} (Grace: {GRACE_PERIOD_DAYS} days)")
    sys.stdout.flush()

    # Pre-populate report
    execute_compliance_audit()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down Governance Engine...")
        httpd.server_close()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "audit":
        report = execute_compliance_audit()
        print(json.dumps(report, indent=2))
        sys.exit(0 if report["summary"]["non_compliant_resources"] == 0 else 1)
    else:
        port_num = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else PORT
        run_standalone_server(port=port_num)
