#!/usr/bin/env python3
"""Automated JSON Schema Validator for Structured Application and Access Logs.

Validates log streams from Docker containers, log files, stdin pipes, or live endpoints
against the enterprise log schema definition.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error
from typing import Any, Dict, List, Optional, Tuple

# ANSI Terminal Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"

# Try importing jsonschema; provide built-in validator fallback if missing
try:
    import jsonschema
    HAS_JSONSCHEMA = True
except ImportError:
    HAS_JSONSCHEMA = False


# ------------------------------------------------------------------------------
# Built-in Fallback Schema Validator
# ------------------------------------------------------------------------------
def fallback_validate_log_entry(
    entry: Dict[str, Any], schema: Dict[str, Any]
) -> List[str]:
    """Validate a log entry against schema rules without external dependencies."""
    errors = []

    # Required root properties
    required_fields = schema.get(
        "required",
        [
            "timestamp",
            "level",
            "logger",
            "message",
            "service",
            "environment",
            "trace_id",
            "caller",
            "context",
        ],
    )
    for field in required_fields:
        if field not in entry:
            errors.append(f"Missing required root property: '{field}'")

    # Timestamp format check
    ts = entry.get("timestamp")
    if ts:
        if not isinstance(ts, str):
            errors.append(
                f"Property 'timestamp' must be string, got {type(ts).__name__}"
            )
        elif not re.match(
            r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$",
            ts,
        ):
            errors.append(
                f"Property 'timestamp' is not valid ISO 8601 UTC format: '{ts}'"
            )

    # Level check
    level = entry.get("level")
    allowed_levels = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
    if level:
        if level not in allowed_levels:
            errors.append(
                f"Property 'level' must be one of {allowed_levels}, got '{level}'"
            )

    # Caller object check
    caller = entry.get("caller")
    if caller is not None:
        if not isinstance(caller, dict):
            errors.append(
                f"Property 'caller' must be object, got {type(caller).__name__}"
            )
        else:
            for req in ["file", "line", "func"]:
                if req not in caller:
                    errors.append(
                        f"Missing required property '{req}' in 'caller' object"
                    )
            if "line" in caller and not isinstance(caller["line"], int):
                errors.append(
                    f"Property 'caller.line' must be integer, got {type(caller['line']).__name__}"
                )

    # Context object check
    context = entry.get("context")
    if context is not None and not isinstance(context, dict):
        errors.append(
            f"Property 'context' must be object, got {type(context).__name__}"
        )

    # HTTP object check
    http_obj = entry.get("http")
    if http_obj is not None:
        if not isinstance(http_obj, dict):
            errors.append(
                f"Property 'http' must be object, got {type(http_obj).__name__}"
            )
        else:
            for req in ["method", "path", "status_code", "duration_ms"]:
                if req not in http_obj:
                    errors.append(
                        f"Missing required property '{req}' in 'http' object"
                    )
            if "status_code" in http_obj and not isinstance(
                http_obj["status_code"], int
            ):
                errors.append(
                    f"Property 'http.status_code' must be integer, got {type(http_obj['status_code']).__name__}"
                )
            if "duration_ms" in http_obj and not isinstance(
                http_obj["duration_ms"], (int, float)
            ):
                errors.append(
                    f"Property 'http.duration_ms' must be number, got {type(http_obj['duration_ms']).__name__}"
                )

    # Error object check
    error_obj = entry.get("error")
    if error_obj is not None:
        if not isinstance(error_obj, dict):
            errors.append(
                f"Property 'error' must be object, got {type(error_obj).__name__}"
            )
        else:
            for req in ["type", "message", "stacktrace"]:
                if req not in error_obj:
                    errors.append(
                        f"Missing required property '{req}' in 'error' object"
                    )

    return errors


# ------------------------------------------------------------------------------
# Log Validator Core Engine
# ------------------------------------------------------------------------------
class LogSchemaValidator:
    """Validates structured JSON log entries against schema rules and tracks statistics."""

    def __init__(self, schema_path: str):
        self.schema_path = schema_path
        self.schema = self._load_schema(schema_path)
        self.jsonschema_validator = (
            jsonschema.Draft7Validator(self.schema) if HAS_JSONSCHEMA else None
        )

        # Statistics trackers
        self.total_lines: int = 0
        self.valid_entries: int = 0
        self.non_json_lines: int = 0
        self.schema_violations: int = 0
        self.level_counts: Dict[str, int] = {
            "DEBUG": 0,
            "INFO": 0,
            "WARNING": 0,
            "ERROR": 0,
            "CRITICAL": 0,
        }
        self.distinct_services: set = set()
        self.distinct_loggers: set = set()
        self.distinct_traces: set = set()
        self.http_status_counts: Dict[int, int] = {}
        self.failures: List[Dict[str, Any]] = []

    def _load_schema(self, path: str) -> Dict[str, Any]:
        if not os.path.exists(path):
            print(
                f"{CLR_RED}[FAIL] Schema file not found: {path}{CLR_RESET}",
                file=sys.stderr,
            )
            sys.exit(1)
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(
                f"{CLR_RED}[FAIL] Failed to parse JSON schema: {e}{CLR_RESET}",
                file=sys.stderr,
            )
            sys.exit(1)

    def validate_line(self, line_number: int, raw_line: str) -> bool:
        """Validate a single raw line from a log stream."""
        stripped = raw_line.strip()
        if not stripped:
            return True  # Ignore empty lines

        self.total_lines += 1

        # 1. Attempt JSON deserialization
        try:
            log_data = json.loads(stripped)
            if not isinstance(log_data, dict):
                self.non_json_lines += 1
                self.failures.append(
                    {
                        "line_number": line_number,
                        "raw_line": stripped[:200],
                        "error_type": "NOT_A_JSON_OBJECT",
                        "details": f"Parsed JSON is {type(log_data).__name__}, expected object",
                    }
                )
                return False
        except json.JSONDecodeError as exc:
            self.non_json_lines += 1
            self.failures.append(
                {
                    "line_number": line_number,
                    "raw_line": stripped[:200],
                    "error_type": "JSON_DECODE_ERROR",
                    "details": str(exc),
                }
            )
            return False

        # 2. Validate against JSON Schema
        violations = []
        if self.jsonschema_validator:
            errors = sorted(
                self.jsonschema_validator.iter_errors(log_data),
                key=lambda e: e.path,
            )
            for err in errors:
                json_path = (
                    "$"
                    + "".join([f"['{p}']" for p in err.path])
                    if err.path
                    else "$"
                )
                violations.append(f"At {json_path}: {err.message}")
        else:
            violations = fallback_validate_log_entry(log_data, self.schema)

        if violations:
            self.schema_violations += 1
            self.failures.append(
                {
                    "line_number": line_number,
                    "raw_line": stripped[:200],
                    "error_type": "SCHEMA_VIOLATION",
                    "details": "; ".join(violations),
                }
            )
            return False

        # 3. Record valid metrics
        self.valid_entries += 1
        level = log_data.get("level", "UNKNOWN")
        self.level_counts[level] = self.level_counts.get(level, 0) + 1

        if "service" in log_data:
            self.distinct_services.add(str(log_data["service"]))
        if "logger" in log_data:
            self.distinct_loggers.add(str(log_data["logger"]))
        if "trace_id" in log_data:
            self.distinct_traces.add(str(log_data["trace_id"]))
        if "http" in log_data and isinstance(log_data["http"], dict):
            status = log_data["http"].get("status_code")
            if isinstance(status, int):
                self.http_status_counts[status] = (
                    self.http_status_counts.get(status, 0) + 1
                )

        return True

    def validate_stream(self, lines: List[str]) -> bool:
        """Validate a list or stream of raw log lines."""
        all_valid = True
        for idx, line in enumerate(lines, start=1):
            if not self.validate_line(idx, line):
                all_valid = False
        return all_valid

    def print_report(self) -> None:
        """Render a formatted, colored validation summary report."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 70)
        print("  📊 STRUCTURED JSON LOG SCHEMA VALIDATION REPORT")
        print("=" * 70 + f"{CLR_RESET}\n")

        print(f"  {CLR_BOLD}Engine:{CLR_RESET} {'jsonschema (Draft-7)' if HAS_JSONSCHEMA else 'Built-in Strict Fallback'}")
        print(f"  {CLR_BOLD}Schema Path:{CLR_RESET} {self.schema_path}")
        print(f"  {CLR_BOLD}Total Lines Scanned:{CLR_RESET} {self.total_lines}")
        print(f"  {CLR_BOLD}Valid JSON Log Events:{CLR_RESET} {CLR_GREEN}{self.valid_entries}{CLR_RESET}")

        if self.schema_violations > 0:
            print(f"  {CLR_BOLD}Schema Violations:{CLR_RESET} {CLR_RED}{self.schema_violations}{CLR_RESET}")
        else:
            print(f"  {CLR_BOLD}Schema Violations:{CLR_RESET} {CLR_GREEN}0{CLR_RESET}")

        if self.non_json_lines > 0:
            print(f"  {CLR_BOLD}Non-JSON / Corrupted Lines:{CLR_RESET} {CLR_RED}{self.non_json_lines}{CLR_RESET}")
        else:
            print(f"  {CLR_BOLD}Non-JSON / Corrupted Lines:{CLR_RESET} {CLR_GREEN}0{CLR_RESET}")

        compliance_rate = (
            (self.valid_entries / self.total_lines * 100)
            if self.total_lines > 0
            else 0.0
        )
        rate_color = CLR_GREEN if compliance_rate == 100.0 else CLR_RED
        print(f"  {CLR_BOLD}Compliance Rate:{CLR_RESET} {rate_color}{compliance_rate:.2f}%{CLR_RESET}\n")

        # Log Level Distribution Table
        print(f"  {CLR_BOLD}Log Level Distribution:{CLR_RESET}")
        print(f"  {CLR_GRAY}----------------------------------------{CLR_RESET}")
        for lvl in ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]:
            count = self.level_counts.get(lvl, 0)
            color = CLR_GREEN if lvl in ("DEBUG", "INFO") else (CLR_YELLOW if lvl == "WARNING" else CLR_RED)
            bar = "█" * min(30, int((count / max(1, self.valid_entries)) * 30))
            print(f"  {color}{lvl:<9}{CLR_RESET} : {count:>5}  {CLR_GRAY}{bar}{CLR_RESET}")

        # Metadata Summaries
        print(f"\n  {CLR_BOLD}Discovered Metadata:{CLR_RESET}")
        print(f"  • Services ({len(self.distinct_services)}): {', '.join(sorted(self.distinct_services)) or 'None'}")
        print(f"  • Loggers ({len(self.distinct_loggers)}): {', '.join(sorted(self.distinct_loggers)) or 'None'}")
        print(f"  • Unique Trace Correlation IDs: {len(self.distinct_traces)}")
        if self.http_status_counts:
            status_summary = ", ".join(
                f"{code}: {cnt}" for code, cnt in sorted(self.http_status_counts.items())
            )
            print(f"  • HTTP Status Codes: {status_summary}")

        # Detailed Failure Listing
        if self.failures:
            print(f"\n{CLR_RED}{CLR_BOLD}  ⚠️  VIOLATION DETAILS ({len(self.failures)} occurrences):{CLR_RESET}")
            for idx, fail in enumerate(self.failures[:15], start=1):
                print(f"\n  [{idx}] Line {fail['line_number']} - {CLR_YELLOW}{fail['error_type']}{CLR_RESET}:")
                print(f"      Reason : {fail['details']}")
                print(f"      Snippet: {CLR_GRAY}{fail['raw_line']}{CLR_RESET}")
            if len(self.failures) > 15:
                print(f"\n  ... and {len(self.failures) - 15} additional violations omitted.")

        print(f"\n{CLR_CYAN}" + "=" * 70 + f"{CLR_RESET}\n")


# ------------------------------------------------------------------------------
# Test Scenarios Traffic Generator
# ------------------------------------------------------------------------------
def run_live_test_scenarios(base_url: str = "http://localhost:8000") -> None:
    """Send synthetic requests to trigger various logging scenarios."""
    print(f"\n{CLR_CYAN}▶ Sending synthetic requests to {base_url}...{CLR_RESET}")

    endpoints = [
        ("GET", "/health", None, {}),
        ("GET", "/ready", None, {}),
        ("GET", "/", None, {}),
        (
            "POST",
            "/api/orders",
            json.dumps(
                {
                    "customer_id": "cust_test_456",
                    "items": [
                        {"sku": "SKU-ABC-1", "quantity": 2, "unit_price": 25.50},
                        {"sku": "SKU-XYZ-9", "quantity": 1, "unit_price": 99.00},
                    ],
                    "payment_method": "credit_card",
                }
            ).encode("utf-8"),
            {"Content-Type": "application/json", "X-Correlation-ID": "550e8400-e29b-41d4-a716-446655440000"},
        ),
        ("GET", "/api/inventory/item_101", None, {}),
        ("GET", "/api/inventory/item_99?simulate_miss=true", None, {}),
        ("GET", "/api/users/user_42", None, {}),
        ("GET", "/api/users/missing", None, {}),  # 404
        ("POST", "/api/checkout/payment-failure", b"{}", {"Content-Type": "application/json"}),  # 502
        ("GET", "/api/database/deadlock", None, {}),  # 500
        ("GET", "/api/external/rate-limit", None, {}),  # 429
        ("GET", "/api/auth/unauthorized", None, {}),  # 401
        (
            "POST",
            "/api/batch/process",
            json.dumps(
                {
                    "batch_name": "validator_test_batch",
                    "items": [
                        {"id": "doc-1", "action": "parse", "should_fail": False},
                        {"id": "doc-2", "action": "encrypt", "should_fail": True},
                        {"id": "doc-3", "action": "archive", "should_fail": False},
                    ],
                }
            ).encode("utf-8"),
            {"Content-Type": "application/json"},
        ),
    ]

    for method, path, data, headers in endpoints:
        url = f"{base_url}{path}"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                print(f"  [{CLR_GREEN}{response.status}{CLR_RESET}] {method:<5} {path}")
        except urllib.error.HTTPError as err:
            # HTTP errors (4xx, 5xx) are expected for failure scenarios
            print(f"  [{CLR_YELLOW}{err.code}{CLR_RESET}] {method:<5} {path} (expected simulation)")
        except Exception as exc:
            print(f"  [{CLR_RED}ERR{CLR_RESET}] {method:<5} {path}: {exc}")


# ------------------------------------------------------------------------------
# CLI Argument Parser & Entrypoint
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Structured JSON Log Schema Validator & Compliance Checker."
    )
    parser.add_argument(
        "--schema",
        default=os.path.join(
            os.path.dirname(__file__), "schema", "log_event_schema.json"
        ),
        help="Path to JSON schema file (default: schema/log_event_schema.json)",
    )
    parser.add_argument(
        "--file",
        help="Path to a log file to validate.",
    )
    parser.add_argument(
        "--docker",
        help="Docker container name to fetch logs from (e.g. structured-logging-app).",
    )
    parser.add_argument(
        "--pipe",
        action="store_true",
        help="Read raw log lines from stdin pipe.",
    )
    parser.add_argument(
        "--live-test",
        nargs="?",
        const="http://localhost:8000",
        help="Run live synthetic traffic suite against base URL (default: http://localhost:8000) and validate logs via Docker.",
    )
    args = parser.parse_args()

    # Locate schema
    schema_path = os.path.abspath(args.schema)
    validator = LogSchemaValidator(schema_path)

    log_lines: List[str] = []

    if args.live_test:
        run_live_test_scenarios(args.live_test)
        # Give a moment for async logs to flush
        container_name = args.docker or "structured-logging-app"
        try:
            output = subprocess.check_output(
                ["docker", "logs", "--tail", "100", container_name],
                stderr=subprocess.STDOUT,
                text=True,
            )
            log_lines = output.splitlines()
        except subprocess.CalledProcessError as exc:
            print(
                f"{CLR_RED}[FAIL] Could not fetch docker logs from '{container_name}': {exc}{CLR_RESET}",
                file=sys.stderr,
            )
            sys.exit(1)

    elif args.docker:
        try:
            output = subprocess.check_output(
                ["docker", "logs", args.docker],
                stderr=subprocess.STDOUT,
                text=True,
            )
            log_lines = output.splitlines()
        except subprocess.CalledProcessError as exc:
            print(
                f"{CLR_RED}[FAIL] Could not fetch docker logs from '{args.docker}': {exc}{CLR_RESET}",
                file=sys.stderr,
            )
            sys.exit(1)

    elif args.file:
        if not os.path.exists(args.file):
            print(
                f"{CLR_RED}[FAIL] Log file does not exist: {args.file}{CLR_RESET}",
                file=sys.stderr,
            )
            sys.exit(1)
        with open(args.file, "r", encoding="utf-8") as f:
            log_lines = f.readlines()

    elif args.pipe or not sys.stdin.isatty():
        log_lines = sys.stdin.readlines()

    else:
        # If no input mode provided, run synthetic scenarios via subprocess or print help
        print(f"{CLR_YELLOW}No input source specified. Checking standard stream or container...{CLR_RESET}")
        parser.print_help()
        sys.exit(1)

    if not log_lines:
        print(f"{CLR_YELLOW}[WARN] No log lines received for validation.{CLR_RESET}")
        sys.exit(1)

    # Perform validation
    validator.validate_stream(log_lines)
    validator.print_report()

    # Success assertion
    if (
        validator.total_lines > 0
        and validator.schema_violations == 0
        and validator.non_json_lines == 0
    ):
        print(f"{CLR_GREEN}{CLR_BOLD}✅ SUCCESS: 100% of scanned log entries strictly conform to the schema!{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"{CLR_RED}{CLR_BOLD}❌ FAILED: Log schema violations or unformatted lines detected.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
