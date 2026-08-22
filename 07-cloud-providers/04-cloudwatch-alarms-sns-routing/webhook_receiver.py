#!/usr/bin/env python3
"""
webhook_receiver.py - Lightweight SNS HTTP/HTTPS Webhook Listener
=============================================================================
Receives, verifies, and logs incoming Amazon SNS notification payloads.

Features:
  - Handles SubscriptionConfirmation and Notification events.
  - Automatically parses nested CloudWatch Alarm JSON messages.
  - Formats ANSI colored alert cards for on-call visibility.
  - Persists received alerts to test_webhook_events.json for test assertions.
=============================================================================
"""

import argparse
import http.server
import json
import os
import socketserver
import sys
import threading
import time
from typing import Any, Dict, List

CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"

RECEIVED_EVENTS: List[Dict[str, Any]] = []
LOG_FILE_PATH = "test_webhook_events.json"
VERBOSE_MODE = False


class SNSWebhookHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for Amazon SNS webhook payloads."""

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length)

        try:
            payload = json.loads(post_data.decode("utf-8"))
        except Exception:
            payload = {"raw": post_data.decode("utf-8", errors="replace")}

        msg_type = payload.get("Type", self.headers.get("x-amz-sns-message-type", "Notification"))
        timestamp = payload.get("Timestamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))

        event_record = {
            "received_at": time.time(),
            "type": msg_type,
            "topic_arn": payload.get("TopicArn", ""),
            "subject": payload.get("Subject", ""),
            "payload": payload,
        }

        # 1. Handle Subscription Confirmation
        if msg_type == "SubscriptionConfirmation":
            token = payload.get("Token", "")
            sub_url = payload.get("SubscribeURL", "")
            print(f"\n{CLR_CYAN}[SNS WEBHOOK] Subscription Confirmation Request Received!{CLR_RESET}")
            print(f"  Topic ARN   : {payload.get('TopicArn')}")
            print(f"  Token       : {token[:16]}...")
            if sub_url:
                print(f"  SubscribeURL: {sub_url}")
            RECEIVED_EVENTS.append(event_record)
            self._save_events()
            self._respond(200, {"status": "Subscription confirmed (mock)"})
            return

        # 2. Handle Alarm Notifications
        raw_message = payload.get("Message", "{}")
        try:
            alarm_details = json.loads(raw_message) if isinstance(raw_message, str) else raw_message
        except Exception:
            alarm_details = {"raw_message": raw_message}

        event_record["alarm_details"] = alarm_details
        RECEIVED_EVENTS.append(event_record)
        self._save_events()

        # Display Formatted Alert Card
        alarm_name = alarm_details.get("AlarmName", payload.get("Subject", "CloudWatch Alarm"))
        new_state = alarm_details.get("NewStateValue", "ALARM")
        old_state = alarm_details.get("OldStateValue", "OK")
        reason = alarm_details.get("NewStateReason", "Threshold breached")
        state_time = alarm_details.get("StateChangeTime", timestamp)

        state_badge = f"{CLR_RED}{CLR_BOLD}[ALARM]{CLR_RESET}" if new_state == "ALARM" else f"{CLR_GREEN}{CLR_BOLD}[OK - RESOLVED]{CLR_RESET}"

        print(f"\n{CLR_MAGENTA}{'=' * 75}{CLR_RESET}")
        print(f"  🚨 {CLR_BOLD}INCIDENT ALERT DISPATCHED TO WEBHOOK{CLR_RESET}  {state_badge}")
        print(f"{CLR_MAGENTA}{'=' * 75}{CLR_RESET}")
        print(f"  Alarm Name    : {CLR_WHITE}{alarm_name}{CLR_RESET}")
        print(f"  State Change  : {CLR_YELLOW}{old_state}{CLR_RESET} ➔ {CLR_RED if new_state == 'ALARM' else CLR_GREEN}{new_state}{CLR_RESET}")
        print(f"  Timestamp     : {CLR_GRAY}{state_time}{CLR_RESET}")
        print(f"  Trigger Reason: {reason}")
        print(f"  Topic ARN     : {CLR_GRAY}{payload.get('TopicArn', 'N/A')}{CLR_RESET}")
        print(f"{CLR_MAGENTA}{'=' * 75}{CLR_RESET}\n")

        self._respond(200, {"status": "Alert received and logged"})

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "UP", "received_events_count": len(RECEIVED_EVENTS)})
        elif self.path == "/events":
            self._respond(200, {"events": RECEIVED_EVENTS})
        else:
            self._respond(200, {"service": "SNS Webhook Receiver", "status": "listening"})

    def _respond(self, status: int, data: Dict[str, Any]):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def _save_events(self):
        try:
            with open(LOG_FILE_PATH, "w", encoding="utf-8") as f:
                json.dump(RECEIVED_EVENTS, f, indent=2)
        except Exception as e:
            if VERBOSE_MODE:
                print(f"[WARN] Failed to write events file: {e}")

    def log_message(self, format, *args):
        if VERBOSE_MODE:
            sys.stderr.write(f"[HTTP] {args[0]} - {args[1]}\n")


def start_server(port: int = 8080, log_file: str = "test_webhook_events.json", verbose: bool = False):
    global LOG_FILE_PATH, VERBOSE_MODE
    LOG_FILE_PATH = log_file
    VERBOSE_MODE = verbose

    # Reset log file
    with open(LOG_FILE_PATH, "w", encoding="utf-8") as f:
        json.dump([], f)

    socketserver.TCPServer.allow_reuse_address = True
    server = socketserver.TCPServer(("", port), SNSWebhookHandler)
    print(f"{CLR_CYAN}▶ SNS Webhook Receiver listening on http://127.0.0.1:{port}...{CLR_RESET}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n{CLR_YELLOW}[INFO] Webhook server shutting down...{CLR_RESET}")
    finally:
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Amazon SNS HTTP/HTTPS Webhook Receiver Server")
    parser.add_argument("--port", type=int, default=8080, help="Port to listen on (default: 8080)")
    parser.add_argument("--log-file", default="test_webhook_events.json", help="Path to save event log")
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose HTTP request logs")
    args = parser.parse_args()

    start_server(port=args.port, log_file=args.log_file, verbose=args.verbose)
