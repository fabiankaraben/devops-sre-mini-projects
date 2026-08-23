#!/usr/bin/env python3
"""
runbook_executor.py - SRE Automated Incident Runbook Daemon
===========================================================
Listens for PagerDuty, Alertmanager, and Webhook alert events, verifies HMAC-SHA256
signatures for zero-trust security, maps incidents to declarative remediation runbooks,
executes modular scripts with cooldown guards and timeouts, and auto-resolves incidents.
"""

import argparse
import dataclasses
import hashlib
import hmac
import http.server
import json
import logging
import os
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(threadName)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("runbook_executor")

DEFAULT_PORT = int(os.environ.get("PORT", 8080))
DEFAULT_CONFIG_PATH = os.environ.get("CONFIG_PATH", "runbook_config.yaml")


@dataclasses.dataclass
class ExecutionRecord:
    execution_id: str
    incident_id: str
    rule_id: str
    rule_name: str
    service: str
    runbook_script: str
    args: List[str]
    status: str  # SUCCESS, FAILED, TIMEOUT, COOLDOWN_BLOCKED
    exit_code: Optional[int]
    duration_seconds: float
    stdout: str
    stderr: str
    auto_resolved: bool
    started_at: str
    completed_at: str


class RunbookDaemonState:
    """Thread-safe state manager for runbook rules, audit logs, cooldowns, and metrics."""

    def __init__(self, config_path: str):
        self._lock = threading.Lock()
        self.config_path = config_path
        self.config = self._load_config(config_path)
        self.start_time = time.time()

        self.last_execution_time: Dict[str, float] = {}
        self.active_locks: Dict[str, threading.Lock] = {}
        self.history: List[ExecutionRecord] = []

        # Prometheus metrics counters
        self.metrics = {
            "executions_total": 0,
            "success_total": 0,
            "failed_total": 0,
            "timeout_total": 0,
            "cooldown_blocked_total": 0,
            "auto_resolved_total": 0,
        }

    def _load_config(self, path: str) -> Dict[str, Any]:
        default_cfg = {
            "version": "1.0",
            "daemon_name": "sre-incident-runbook-executor",
            "webhook_secret": "sre-remediation-secret-token-12345",
            "default_timeout_seconds": 30,
            "default_cooldown_seconds": 15,
            "auto_resolve_incidents": True,
            "target_host": "http://mock-services:9000",
            "rules": [
                {
                    "id": "remediate_hung_worker",
                    "name": "Hung Worker Deadlock Self-Healing",
                    "match": {"alertname": "HungWorkerDetected", "service": "worker-service", "event_type": "trigger"},
                    "runbook": "runbooks/restart_service.sh",
                    "args": ["worker-service"],
                    "timeout_seconds": 20,
                    "cooldown_seconds": 15,
                    "auto_resolve": True,
                },
                {
                    "id": "remediate_redis_oom",
                    "name": "Redis Memory Pressure Eviction",
                    "match": {"alertname": "RedisMemoryCritical", "service": "redis-cache", "event_type": "trigger"},
                    "runbook": "runbooks/flush_cache.sh",
                    "args": ["redis-cache"],
                    "timeout_seconds": 20,
                    "cooldown_seconds": 15,
                    "auto_resolve": True,
                },
                {
                    "id": "remediate_queue_backlog",
                    "name": "Queue Backlog Dynamic Autoscaling",
                    "match": {"alertname": "QueueBacklogHigh", "service": "order-queue", "event_type": "trigger"},
                    "runbook": "runbooks/scale_deployment.sh",
                    "args": ["order-queue", "6"],
                    "timeout_seconds": 25,
                    "cooldown_seconds": 15,
                    "auto_resolve": True,
                },
                {
                    "id": "remediate_dlq_spike",
                    "name": "Dead-Letter Queue Automated Replay & Drain",
                    "match": {"alertname": "DeadLetterQueueSpike", "service": "order-queue", "event_type": "trigger"},
                    "runbook": "runbooks/drain_queue.sh",
                    "args": ["order-queue"],
                    "timeout_seconds": 20,
                    "cooldown_seconds": 15,
                    "auto_resolve": True,
                },
            ],
        }

        if not os.path.exists(path):
            logger.warning("Config file '%s' not found, using default configuration.", path)
            return default_cfg

        try:
            import yaml

            with open(path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
                if isinstance(data, dict) and "rules" in data:
                    return data
        except Exception as err:
            logger.warning("Failed to load YAML config from '%s': %s", path, err)

        return default_cfg

    def verify_signature(self, raw_body: bytes, signature_header: Optional[str]) -> bool:
        """Verify HMAC-SHA256 signature against configured webhook_secret."""
        secret = self.config.get("webhook_secret", "")
        if not secret:
            return True  # If no secret configured, allow (open mode)

        if not signature_header:
            logger.warning("Rejecting webhook: Missing signature header.")
            return False

        # Extract hex digest if prefixed (e.g. 'v1=abc', 'sha256=abc', or raw 'abc')
        sig = signature_header.strip()
        if "=" in sig:
            sig = sig.split("=", 1)[1]

        expected_sig = hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
        is_valid = hmac.compare_digest(sig.lower(), expected_sig.lower())
        if not is_valid:
            logger.warning("Rejecting webhook: HMAC-SHA256 signature mismatch (Got: %s, Expected: %s).", sig, expected_sig)
        return is_valid

    def find_matching_rule(self, event_data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Match event payload attributes against declarative rules."""
        alertname = event_data.get("alertname") or event_data.get("title") or event_data.get("summary", "")
        service = event_data.get("service") or event_data.get("service_name", "")
        event_type = event_data.get("event_type") or event_data.get("event", "trigger")

        for rule in self.config.get("rules", []):
            match = rule.get("match", {})
            m_alert = match.get("alertname")
            m_service = match.get("service")
            m_type = match.get("event_type", "trigger")

            # Match criteria
            alert_matched = not m_alert or m_alert.lower() in alertname.lower() or alertname.lower() in m_alert.lower()
            service_matched = not m_service or m_service.lower() in service.lower() or service.lower() in m_service.lower()
            type_matched = not m_type or m_type.lower() in event_type.lower() or event_type.lower() in m_type.lower()

            if alert_matched and service_matched and type_matched:
                return rule

        return None

    def execute_runbook(self, rule: Dict[str, Any], event_data: Dict[str, Any]) -> ExecutionRecord:
        """Execute runbook script with cooldown guards, timeouts, and audit logging."""
        rule_id = rule.get("id", "unknown_rule")
        rule_name = rule.get("name", rule_id)
        runbook_path = rule.get("runbook", "")
        args = rule.get("args", [])
        cooldown_sec = rule.get("cooldown_seconds", self.config.get("default_cooldown_seconds", 15))
        timeout_sec = rule.get("timeout_seconds", self.config.get("default_timeout_seconds", 30))
        auto_resolve = rule.get("auto_resolve", self.config.get("auto_resolve_incidents", True))

        incident_id = event_data.get("incident_id") or event_data.get("id", f"inc-{int(time.time())}")
        service_name = event_data.get("service") or rule.get("match", {}).get("service", "unknown")
        exec_id = f"exec-{int(time.time() * 1000)}"
        started_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        # 1. Cooldown Guard Check
        with self._lock:
            now = time.time()
            last_time = self.last_execution_time.get(rule_id, 0.0)
            if now - last_time < cooldown_sec:
                remaining = round(cooldown_sec - (now - last_time), 1)
                logger.warning(
                    "COOLDOWN BLOCKED: Rule '%s' executed %.1fs ago (< %ds cooldown). %ds remaining.",
                    rule_id, now - last_time, cooldown_sec, remaining
                )
                self.metrics["cooldown_blocked_total"] += 1
                rec = ExecutionRecord(
                    execution_id=exec_id,
                    incident_id=incident_id,
                    rule_id=rule_id,
                    rule_name=rule_name,
                    service=service_name,
                    runbook_script=runbook_path,
                    args=args,
                    status="COOLDOWN_BLOCKED",
                    exit_code=None,
                    duration_seconds=0.0,
                    stdout="",
                    stderr=f"Execution blocked by {cooldown_sec}s cooldown policy ({remaining}s remaining).",
                    auto_resolved=False,
                    started_at=started_str,
                    completed_at=started_str,
                )
                self.history.append(rec)
                return rec

            self.last_execution_time[rule_id] = now
            self.metrics["executions_total"] += 1

        # 2. Runbook Execution
        logger.info("Executing runbook '%s' for rule '%s' (Incident: %s)...", runbook_path, rule_name, incident_id)
        start_ts = time.time()
        env = os.environ.copy()
        env["TARGET_HOST"] = self.config.get("target_host", "http://mock-services:9000")
        env["INCIDENT_ID"] = incident_id
        env["SERVICE_NAME"] = service_name

        cmd = [runbook_path] + [str(a) for a in args]
        status = "SUCCESS"
        exit_code = 0
        stdout_str = ""
        stderr_str = ""

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout_sec,
                env=env,
                check=False,
            )
            exit_code = proc.returncode
            stdout_str = proc.stdout.strip()
            stderr_str = proc.stderr.strip()

            if exit_code == 0:
                status = "SUCCESS"
                with self._lock:
                    self.metrics["success_total"] += 1
                logger.info("Runbook '%s' completed successfully (Exit Code: 0).", runbook_path)
            else:
                status = "FAILED"
                with self._lock:
                    self.metrics["failed_total"] += 1
                logger.error("Runbook '%s' failed with exit code %d. Stderr: %s", runbook_path, exit_code, stderr_str)

        except subprocess.TimeoutExpired:
            status = "TIMEOUT"
            exit_code = -1
            stderr_str = f"Execution exceeded {timeout_sec}s timeout limit."
            with self._lock:
                self.metrics["timeout_total"] += 1
            logger.error("Runbook '%s' timed out after %ds.", runbook_path, timeout_sec)

        except Exception as err:
            status = "FAILED"
            exit_code = -1
            stderr_str = f"Execution error: {err}"
            with self._lock:
                self.metrics["failed_total"] += 1
            logger.error("Runbook execution exception: %s", err)

        duration = round(time.time() - start_ts, 3)
        completed_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        # 3. Incident Auto-Resolution
        resolved_ok = False
        if status == "SUCCESS" and auto_resolve:
            resolved_ok = self._send_auto_resolve_callback(incident_id, rule_name, duration)
            if resolved_ok:
                with self._lock:
                    self.metrics["auto_resolved_total"] += 1

        rec = ExecutionRecord(
            execution_id=exec_id,
            incident_id=incident_id,
            rule_id=rule_id,
            rule_name=rule_name,
            service=service_name,
            runbook_script=runbook_path,
            args=args,
            status=status,
            exit_code=exit_code,
            duration_seconds=duration,
            stdout=stdout_str,
            stderr=stderr_str,
            auto_resolved=resolved_ok,
            started_at=started_str,
            completed_at=completed_str,
        )

        with self._lock:
            self.history.append(rec)

        return rec

    def _send_auto_resolve_callback(self, incident_id: str, rule_name: str, duration: float) -> bool:
        target_host = self.config.get("target_host", "http://mock-services:9000")
        url = f"{target_host.rstrip('/')}/pagerduty/api/v1/incidents/{incident_id}/resolve"
        payload = {
            "incident_id": incident_id,
            "status": "resolved",
            "resolution_summary": f"Remediated automatically by SRE Runbook Executor ({rule_name}) in {duration:.2f}s.",
            "resolved_by": "sre-automated-runbook-executor",
        }
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json", "User-Agent": "runbook-executor/1.0"},
            )
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                if resp.status in (200, 201, 204):
                    logger.info("Auto-resolution callback succeeded for incident '%s'.", incident_id)
                    return True
        except Exception as err:
            logger.warning("Auto-resolution callback to %s failed: %s", url, err)
        return False

    def generate_prometheus_metrics(self) -> str:
        with self._lock:
            lines = [
                "# HELP runbook_executions_total Total number of runbook executions initiated.",
                "# TYPE runbook_executions_total counter",
                f'runbook_executions_total {self.metrics["executions_total"]}',
                "",
                "# HELP runbook_executions_success_total Total successful runbook remediations.",
                "# TYPE runbook_executions_success_total counter",
                f'runbook_executions_success_total {self.metrics["success_total"]}',
                "",
                "# HELP runbook_executions_failed_total Total failed runbook remediations.",
                "# TYPE runbook_executions_failed_total counter",
                f'runbook_executions_failed_total {self.metrics["failed_total"]}',
                "",
                "# HELP runbook_cooldown_blocked_total Total executions blocked by safety cooldown policies.",
                "# TYPE runbook_cooldown_blocked_total counter",
                f'runbook_cooldown_blocked_total {self.metrics["cooldown_blocked_total"]}',
                "",
                "# HELP runbook_auto_resolved_total Total incidents automatically resolved post-remediation.",
                "# TYPE runbook_auto_resolved_total counter",
                f'runbook_auto_resolved_total {self.metrics["auto_resolved_total"]}',
                "",
            ]
            return "\n".join(lines)


# Global daemon state
daemon_state: Optional[RunbookDaemonState] = None


class RunbookWebhookHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler for webhook alert ingestion and SRE inspection."""

    def log_message(self, format_str: str, *args: Any):
        if "GET /health" not in format_str % args and "GET /metrics" not in format_str % args:
            logger.info("%s - %s", self.client_address[0], format_str % args)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path in ("/health", "/healthz"):
            resp = json.dumps({"status": "healthy", "service": "runbook-executor"}).encode("utf-8")
            self._send_response(200, resp, "application/json")

        elif path == "/metrics":
            resp = daemon_state.generate_prometheus_metrics().encode("utf-8")
            self._send_response(200, resp, "text/plain; version=0.0.4; charset=utf-8")

        elif path in ("/history", "/api/v1/history"):
            with daemon_state._lock:
                records = [dataclasses.asdict(r) for r in daemon_state.history]
            resp = json.dumps({"total_executions": len(records), "executions": records}, indent=2).encode("utf-8")
            self._send_response(200, resp, "application/json")

        elif path in ("/status", "/api/v1/status"):
            with daemon_state._lock:
                summary = {
                    "daemon_name": daemon_state.config.get("daemon_name"),
                    "uptime_seconds": round(time.time() - daemon_state.start_time, 1),
                    "configured_rules_count": len(daemon_state.config.get("rules", [])),
                    "metrics": daemon_state.metrics,
                    "rules": [
                        {
                            "id": r.get("id"),
                            "name": r.get("name"),
                            "runbook": r.get("runbook"),
                            "match": r.get("match"),
                            "cooldown_seconds": r.get("cooldown_seconds"),
                        }
                        for r in daemon_state.config.get("rules", [])
                    ],
                }
            resp = json.dumps(summary, indent=2).encode("utf-8")
            self._send_response(200, resp, "application/json")

        else:
            self._send_response(404, b'{"error":"Not Found"}', "application/json")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length) if length > 0 else b""

        # 1. HMAC Signature Verification
        sig_header = (
            self.headers.get("X-Webhook-Signature")
            or self.headers.get("X-PagerDuty-Signature")
            or self.headers.get("X-Hub-Signature-256")
            or self.headers.get("X-Signature")
        )

        if not daemon_state.verify_signature(raw_body, sig_header):
            resp = json.dumps({
                "error": "Unauthorized: Invalid HMAC-SHA256 signature",
                "status": "signature_mismatch",
            }).encode("utf-8")
            self._send_response(401, resp, "application/json")
            return

        # 2. Parse payload
        try:
            payload = json.loads(raw_body.decode("utf-8")) if raw_body else {}
        except Exception as err:
            resp = json.dumps({"error": f"Invalid JSON payload: {err}"}).encode("utf-8")
            self._send_response(400, resp, "application/json")
            return

        # 3. Route by webhook path
        if path in ("/webhook/pagerduty", "/webhook/alertmanager", "/webhook/generic", "/webhook"):
            normalized_event = self._normalize_event(payload, path)
            matched_rule = daemon_state.find_matching_rule(normalized_event)

            if not matched_rule:
                logger.info("No matching runbook rule found for alert event: %s", normalized_event)
                resp = json.dumps({
                    "message": "Alert received but no matching runbook rule found",
                    "event": normalized_event,
                    "remediation_status": "SKIPPED",
                }).encode("utf-8")
                self._send_response(200, resp, "application/json")
                return

            # Execute runbook
            record = daemon_state.execute_runbook(matched_rule, normalized_event)
            http_status = 200 if record.status in ("SUCCESS", "COOLDOWN_BLOCKED") else 500
            resp = json.dumps({
                "message": f"Runbook remediation executed: {record.status}",
                "execution": dataclasses.asdict(record),
            }, indent=2).encode("utf-8")
            self._send_response(http_status, resp, "application/json")

        else:
            self._send_response(404, b'{"error":"Unknown webhook route"}', "application/json")

    def _normalize_event(self, payload: Dict[str, Any], path: str) -> Dict[str, Any]:
        """Normalize varying webhook formats (PagerDuty v3, Alertmanager, Generic) into standard dict."""
        event: Dict[str, Any] = {}

        # 1. PagerDuty v3 Webhook Format
        if "event" in payload and isinstance(payload["event"], dict):
            ev = payload["event"]
            data = ev.get("data", {})
            event["incident_id"] = data.get("id", f"pd-{int(time.time())}")
            event["title"] = data.get("title", "")
            event["alertname"] = data.get("title", "")
            event["service"] = data.get("service", {}).get("summary", "")
            raw_type = ev.get("event_type", "incident.triggered").replace("incident.", "")
            event["event_type"] = "trigger" if "trigger" in raw_type else raw_type
            event["custom_details"] = data.get("custom_details", {})
            # Check if custom_details contains alertname/service overrides
            if "alertname" in event["custom_details"]:
                event["alertname"] = event["custom_details"]["alertname"]
            if "service" in event["custom_details"]:
                event["service"] = event["custom_details"]["service"]
            return event

        # 2. Prometheus Alertmanager Format
        if "alerts" in payload and isinstance(payload["alerts"], list) and len(payload["alerts"]) > 0:
            first_alert = payload["alerts"][0]
            labels = first_alert.get("labels", {})
            annotations = first_alert.get("annotations", {})
            event["incident_id"] = labels.get("alertname", f"am-{int(time.time())}")
            event["alertname"] = labels.get("alertname", "")
            event["service"] = labels.get("service", "")
            event["event_type"] = "trigger" if first_alert.get("status") == "firing" else "resolve"
            event["summary"] = annotations.get("summary", "")
            return event

        # 3. Generic Webhook Format
        event["incident_id"] = payload.get("incident_id") or payload.get("id", f"inc-{int(time.time())}")
        event["alertname"] = payload.get("alertname") or payload.get("title") or payload.get("name", "")
        event["service"] = payload.get("service") or payload.get("service_name", "")
        event["event_type"] = payload.get("event_type") or payload.get("event", "trigger")
        return event

    def _send_response(self, code: int, body: bytes, content_type: str):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    global daemon_state
    parser = argparse.ArgumentParser(description="Automated Incident Runbook Executor Daemon")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT, help="Port to listen on")
    parser.add_argument("--config", "-c", type=str, default=DEFAULT_CONFIG_PATH, help="Path to runbook config YAML")
    args = parser.parse_args()

    daemon_state = RunbookDaemonState(args.config)

    class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedServer(("0.0.0.0", args.port), RunbookWebhookHandler)
    logger.info("Automated Runbook Executor Daemon listening on http://0.0.0.0:%d", args.port)
    logger.info("Webhook endpoints: /webhook/pagerduty, /webhook/alertmanager, /webhook/generic")
    logger.info("Configured rules count: %d", len(daemon_state.config.get("rules", [])))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down daemon...")
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
