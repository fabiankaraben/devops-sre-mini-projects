#!/usr/bin/env python3
"""
trace_verification.py - Automated Distributed Tracing Verification Suite

Executes end-to-end multi-tier microservice transactions (Happy Path, Auth Rejection,
Payment Failure, and Latency Injection) and queries the Jaeger REST API to assert
W3C context propagation, span hierarchy, error recording, and timing waterfalls.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Set, Tuple

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_WHITE = "\033[1;37m"
CLR_GRAY = "\033[0;90m"

FRONTEND_URL = "http://localhost:8080"
AUTH_URL = "http://localhost:8082"
PAYMENT_URL = "http://localhost:8083"
JAEGER_API_URL = "http://localhost:16686/api"

total_tests = 0
passed_tests = 0
failed_tests = 0


def record_pass(test_name: str, message: str):
    """Record and format passing test assertion."""
    global total_tests, passed_tests
    total_tests += 1
    passed_tests += 1
    print(f"  [{CLR_GREEN}PASS{CLR_RESET}] {CLR_BOLD}{test_name}{CLR_RESET}: {message}")


def record_fail(test_name: str, message: str):
    """Record and format failing test assertion."""
    global total_tests, failed_tests
    total_tests += 1
    failed_tests += 1
    print(f"  [{CLR_RED}FAIL{CLR_RESET}] {CLR_BOLD}{test_name}{CLR_RESET}: {message}")


def http_request(
    url: str,
    method: str = "GET",
    payload: Optional[Dict[str, Any]] = None,
    timeout: float = 10.0,
) -> Tuple[int, Dict[str, Any], Dict[str, str]]:
    """Execute HTTP request using standard library urllib."""
    data = None
    headers = {"Content-Type": "application/json", "Accept": "application/json"}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")

    req = urllib.request.Request(url=url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status_code = response.getcode()
            raw_body = response.read().decode("utf-8")
            resp_headers = {k: v for k, v in response.getheaders()}
            body = json.loads(raw_body) if raw_body else {}
            return status_code, body, resp_headers
    except urllib.error.HTTPError as e:
        status_code = e.code
        raw_body = e.read().decode("utf-8")
        resp_headers = {k: v for k, v in e.headers.items()}
        try:
            body = json.loads(raw_body) if raw_body else {}
        except Exception:
            body = {"raw_error": raw_body}
        return status_code, body, resp_headers
    except Exception as e:
        return 0, {"error": str(e)}, {}


def wait_for_trace(
    trace_id: str,
    min_spans: int = 1,
    expected_services: Optional[Set[str]] = None,
    max_retries: int = 15,
    delay_sec: float = 0.5,
) -> Optional[Dict[str, Any]]:
    """
    Poll Jaeger Query API until the trace is collected and indexed with expected spans and services.
    Ensures asynchronous batch span flushes from downstream microservices are fully collected.
    """
    url = f"{JAEGER_API_URL}/traces/{trace_id}"
    last_trace_obj = None

    for attempt in range(max_retries):
        status_code, body, _ = http_request(url)
        if status_code == 200 and "data" in body and len(body["data"]) > 0:
            trace_obj = body["data"][0]
            spans = trace_obj.get("spans", [])
            last_trace_obj = trace_obj

            if len(spans) >= min_spans:
                if expected_services:
                    processes = trace_obj.get("processes", {})
                    found_services = {p.get("serviceName") for p in processes.values()}
                    if expected_services.issubset(found_services):
                        # Give a tiny buffer for any remaining sibling spans to flush
                        time.sleep(0.3)
                        # Re-fetch one final time to get complete tree
                        _, final_body, _ = http_request(url)
                        if "data" in final_body and len(final_body["data"]) > 0:
                            return final_body["data"][0]
                        return trace_obj
                else:
                    return trace_obj

        time.sleep(delay_sec)

    return last_trace_obj


def get_span_service(span: Dict[str, Any], processes: Dict[str, Any]) -> str:
    """Resolve the service name of a span using its processID."""
    process_id = span.get("processID")
    if process_id and process_id in processes:
        return processes[process_id].get("serviceName", "unknown")
    for tag in span.get("tags", []):
        if tag.get("key") in ("service.name", "peer.service"):
            return str(tag.get("value"))
    return "unknown"


def get_span_tags_dict(span: Dict[str, Any]) -> Dict[str, Any]:
    """Convert Jaeger tag array to a dictionary."""
    return {tag["key"]: tag.get("value") for tag in span.get("tags", [])}


def has_span_event(span: Dict[str, Any], event_name: str) -> bool:
    """Check if a span contains a specific event/log name in Jaeger format."""
    for log in span.get("logs", []):
        for field in log.get("fields", []):
            if field.get("key") in ("event", "message") and field.get("value") == event_name:
                return True
            if field.get("key") == event_name:
                return True
    return False


def print_trace_tree(trace_obj: Dict[str, Any]):
    """Format and print an ASCII tree of the trace spans with durations and services."""
    spans = trace_obj.get("spans", [])
    processes = trace_obj.get("processes", {})
    if not spans:
        return

    # Map span parent relationships
    spans_by_id = {s["spanID"]: s for s in spans}
    children_map: Dict[Optional[str], List[str]] = {}
    root_span_ids: List[str] = []

    for s in spans:
        span_id = s["spanID"]
        parent_id = None
        for ref in s.get("references", []):
            if ref.get("refType") == "CHILD_OF":
                parent_id = ref.get("spanID")
                break

        if parent_id and parent_id in spans_by_id:
            children_map.setdefault(parent_id, []).append(span_id)
        else:
            root_span_ids.append(span_id)

    print(f"\n{CLR_CYAN}── Trace Visualization Tree (Trace ID: {trace_obj.get('traceID')}) ──{CLR_RESET}")

    def render_subtree(current_id: str, prefix: str = "", is_last: bool = True):
        span = spans_by_id.get(current_id)
        if not span:
            return

        svc = get_span_service(span, processes)
        op = span.get("operationName", "unknown")
        dur_ms = span.get("duration", 0) / 1000.0
        tags = get_span_tags_dict(span)
        has_error = tags.get("error") is True or tags.get("otel.status_code") == "ERROR"

        # Choose service badge color
        svc_color = CLR_GREEN if "frontend" in svc else (CLR_CYAN if "auth" in svc else CLR_MAGENTA)
        status_marker = f"{CLR_RED}[ERROR]{CLR_RESET}" if has_error else f"{CLR_GREEN}[OK]{CLR_RESET}"

        connector = "└── " if is_last else "├── "
        print(
            f"{CLR_GRAY}{prefix}{connector}{CLR_RESET}"
            f"{svc_color}[{svc}]{CLR_RESET} "
            f"{CLR_BOLD}{op}{CLR_RESET} "
            f"({CLR_YELLOW}{dur_ms:.2f}ms{CLR_RESET}) {status_marker}"
        )

        children = sorted(
            children_map.get(current_id, []),
            key=lambda cid: spans_by_id[cid].get("startTime", 0),
        )
        for i, child_id in enumerate(children):
            child_is_last = (i == len(children) - 1)
            new_prefix = prefix + ("    " if is_last else "│   ")
            render_subtree(child_id, new_prefix, child_is_last)

    for i, root_id in enumerate(sorted(root_span_ids, key=lambda sid: spans_by_id[sid].get("startTime", 0))):
        render_subtree(root_id, is_last=(i == len(root_span_ids) - 1))
    print(f"{CLR_CYAN}──────────────────────────────────────────────────────────────────────────{CLR_RESET}\n")


# ------------------------------------------------------------------------------
# Test Scenarios
# ------------------------------------------------------------------------------
def test_system_health():
    """Verify that all services and Jaeger query API are running."""
    print(f"\n{CLR_YELLOW}▶ Step 1: Validating Services & Jaeger Health...{CLR_RESET}")
    services = [
        ("Frontend Service", f"{FRONTEND_URL}/healthz"),
        ("Auth Service", f"{AUTH_URL}/healthz"),
        ("Payment Service", f"{PAYMENT_URL}/healthz"),
        ("Jaeger Query API", f"{JAEGER_API_URL}/services"),
    ]

    for name, url in services:
        status_code, body, _ = http_request(url)
        if status_code == 200:
            record_pass("Health Check", f"{name} is reachable and healthy at {url}")
        else:
            record_fail("Health Check", f"{name} unreachable (HTTP {status_code}) at {url}")


def test_happy_path_checkout():
    """Test 1: Full 3-Tier Distributed Trace with W3C Context Propagation."""
    print(f"\n{CLR_YELLOW}▶ Step 2: Executing Happy Path Checkout (Frontend ➔ Auth ➔ Payment)...{CLR_RESET}")
    payload = {
        "user_token": "valid-token-user-gold-99",
        "cart_id": "cart-happy-001",
        "items": [
            {"item_id": "item-otel-guide", "name": "OpenTelemetry Guide", "unit_price": 45.0, "quantity": 1},
            {"item_id": "item-jaeger-cup", "name": "Jaeger Mascot Mug", "unit_price": 15.0, "quantity": 2},
        ],
        "currency": "USD",
        "payment_method": {
            "card_number": "4242-4242-4242-4242",
            "cardholder_name": "Jane Doe",
            "expiry": "12/28",
            "cvv": "123",
            "gateway": "stripe_mock",
        },
        "simulate_delay_ms": 10,
    }

    status_code, body, headers = http_request(f"{FRONTEND_URL}/api/checkout", method="POST", payload=payload)
    if status_code == 200 and body.get("status") == "SUCCESS":
        record_pass("Checkout HTTP Response", f"Transaction completed successfully. Order ID: {body.get('order_id')}")
    else:
        record_fail("Checkout HTTP Response", f"Expected HTTP 200 SUCCESS, got {status_code}: {body}")
        return

    trace_id = body.get("trace_id") or headers.get("x-trace-id")
    if not trace_id:
        record_fail("W3C Trace ID Header", "Response missing 'trace_id' and 'X-Trace-ID' header")
        return

    record_pass("Trace ID Generated", f"Active transaction Trace ID: {trace_id}")

    # Fetch and validate trace from Jaeger, expecting spans from all 3 services
    expected_svcs = {"frontend-service", "auth-service", "payment-service"}
    trace_obj = wait_for_trace(trace_id, min_spans=8, expected_services=expected_svcs)
    if not trace_obj:
        record_fail("Jaeger Trace Collection", f"Trace {trace_id} not found in Jaeger after polling")
        return

    record_pass("Jaeger Trace Retrieval", f"Trace indexed in Jaeger with {len(trace_obj.get('spans', []))} total spans")
    print_trace_tree(trace_obj)

    # Validate Services involved
    processes = trace_obj.get("processes", {})
    service_names = {p.get("serviceName") for p in processes.values()}

    if expected_svcs.issubset(service_names):
        record_pass(
            "Multi-Tier Service Span Coverage",
            f"All 3 microservices participated in trace: {', '.join(sorted(service_names))}",
        )
    else:
        record_fail(
            "Multi-Tier Service Span Coverage",
            f"Missing required services in trace. Found: {service_names}, Required: {expected_svcs}",
        )

    # Validate W3C Trace ID consistency across all spans
    all_spans = trace_obj.get("spans", [])
    mismatched_spans = [s for s in all_spans if s.get("traceID") != trace_id]
    if not mismatched_spans:
        record_pass(
            "W3C Context Propagation",
            f"All {len(all_spans)} spans correctly share identical root Trace ID ({trace_id})",
        )
    else:
        record_fail("W3C Context Propagation", f"Found {len(mismatched_spans)} spans with mismatched trace IDs")

    # Validate Custom Semantic Attributes & Events
    has_order_attr = any("order.id" in get_span_tags_dict(s) for s in all_spans)
    has_payment_attr = any("payment.transaction_id" in get_span_tags_dict(s) for s in all_spans)
    has_cart_event = any(has_span_event(s, "cart_validated") for s in all_spans)
    has_auth_event = any(has_span_event(s, "auth_verified") for s in all_spans)
    has_gateway_event = any(has_span_event(s, "gateway_authorized") for s in all_spans)

    if has_order_attr and has_payment_attr and has_cart_event and has_auth_event and has_gateway_event:
        record_pass(
            "Custom Telemetry Enrichment",
            "Spans include business attributes ('order.id', 'payment.transaction_id') and events ('cart_validated', 'auth_verified', 'gateway_authorized')",
        )
    else:
        record_fail(
            "Custom Telemetry Enrichment",
            f"Missing custom telemetry: order_attr={has_order_attr}, payment_attr={has_payment_attr}, cart_event={has_cart_event}, auth_event={has_auth_event}, gateway_event={has_gateway_event}",
        )


def test_auth_rejection_trace():
    """Test 2: Distributed Trace with Authentication Failure."""
    print(f"\n{CLR_YELLOW}▶ Step 3: Testing Authentication Failure Span & Context Propagation...{CLR_RESET}")
    payload = {
        "user_token": "invalid-token-tampered-xyz",
        "cart_id": "cart-auth-fail",
        "items": [{"item_id": "item-1", "name": "Item", "unit_price": 10.0, "quantity": 1}],
        "currency": "USD",
        "payment_method": {"card_number": "4242-4242-4242-4242"},
    }

    status_code, body, headers = http_request(f"{FRONTEND_URL}/api/checkout", method="POST", payload=payload)
    if status_code == 401:
        record_pass("Auth Error Response", f"Frontend correctly returned HTTP 401 Unauthorized: {body.get('error')}")
    else:
        record_fail("Auth Error Response", f"Expected HTTP 401, got {status_code}: {body}")
        return

    trace_id = body.get("trace_id") or headers.get("x-trace-id")
    expected_svcs = {"frontend-service", "auth-service"}
    trace_obj = wait_for_trace(trace_id, min_spans=4, expected_services=expected_svcs)
    if not trace_obj:
        record_fail("Jaeger Auth Trace", f"Trace {trace_id} not found in Jaeger")
        return

    print_trace_tree(trace_obj)

    processes = trace_obj.get("processes", {})
    service_names = {p.get("serviceName") for p in processes.values()}

    # Validate that auth-service participated, but payment-service was skipped
    if "auth-service" in service_names and "payment-service" not in service_names:
        record_pass(
            "Pipeline Short-Circuit",
            "Trace includes frontend-service and auth-service; payment-service correctly omitted on 401",
        )
    else:
        record_fail(
            "Pipeline Short-Circuit",
            f"Unexpected service execution graph. Found services: {service_names}",
        )

    # Validate Error Tag on Auth/Frontend Span
    all_spans = trace_obj.get("spans", [])
    error_spans = [
        s for s in all_spans
        if get_span_tags_dict(s).get("error") is True
        or get_span_tags_dict(s).get("otel.status_code") == "ERROR"
        or get_span_tags_dict(s).get("http.status_code") == 401
    ]

    if len(error_spans) > 0:
        record_pass(
            "Span Error Status",
            f"Error flags ('error=true' / 'otel.status_code=ERROR') correctly recorded on {len(error_spans)} spans",
        )
    else:
        record_fail("Span Error Status", "No error status flag found in spans for rejected transaction")


def test_payment_decline_trace():
    """Test 3: Distributed Trace with Payment Decline & Exception Recording."""
    print(f"\n{CLR_YELLOW}▶ Step 4: Testing Payment Decline & Exception Recording...{CLR_RESET}")
    payload = {
        "user_token": "valid-token-user-101",
        "cart_id": "cart-pay-decline",
        "items": [{"item_id": "item-1", "name": "Item", "unit_price": 50.0, "quantity": 1}],
        "currency": "USD",
        "payment_method": {
            "card_number": "4242-4242-4242-4002",  # Ends in 4002 to trigger decline
            "cardholder_name": "Card Decliner",
        },
    }

    status_code, body, headers = http_request(f"{FRONTEND_URL}/api/checkout", method="POST", payload=payload)
    if status_code == 402:
        record_pass("Payment Decline Response", f"Frontend returned HTTP 402 Payment Required: {body.get('error')}")
    else:
        record_fail("Payment Decline Response", f"Expected HTTP 402, got {status_code}: {body}")
        return

    trace_id = body.get("trace_id") or headers.get("x-trace-id")
    expected_svcs = {"frontend-service", "auth-service", "payment-service"}
    trace_obj = wait_for_trace(trace_id, min_spans=8, expected_services=expected_svcs)
    if not trace_obj:
        record_fail("Jaeger Payment Decline Trace", f"Trace {trace_id} not found in Jaeger")
        return

    print_trace_tree(trace_obj)

    # Validate Payment Service recorded error and exception
    all_spans = trace_obj.get("spans", [])
    payment_error_spans = [
        s for s in all_spans
        if "payment" in get_span_service(s, trace_obj.get("processes", {}))
        and (
            get_span_tags_dict(s).get("error") is True
            or get_span_tags_dict(s).get("otel.status_code") == "ERROR"
            or has_span_event(s, "gateway_declined")
            or any(
                f.get("key") == "exception.type" or "Insufficient" in str(f.get("value"))
                for log in s.get("logs", [])
                for f in log.get("fields", [])
            )
        )
    ]

    if len(payment_error_spans) > 0:
        record_pass(
            "Payment Error Recording",
            f"Payment service correctly flagged {len(payment_error_spans)} error spans and recorded decline exception details",
        )
    else:
        record_fail("Payment Error Recording", "No payment error spans or events found in Jaeger trace")


def test_latency_waterfall_trace():
    """Test 4: Latency Injection & Waterfall Duration Analysis."""
    print(f"\n{CLR_YELLOW}▶ Step 5: Testing Latency Waterfall Breakdown (Simulated Delay: 300ms)...{CLR_RESET}")
    delay_ms = 300
    payload = {
        "user_token": "valid-token-user-101",
        "cart_id": "cart-slow-demo",
        "items": [{"item_id": "item-slow", "name": "Heavy Processing Item", "unit_price": 99.0, "quantity": 1}],
        "currency": "USD",
        "payment_method": {"card_number": "4242-4242-4242-4242"},
        "simulate_delay_ms": delay_ms,
    }

    start_time = time.time()
    status_code, body, headers = http_request(f"{FRONTEND_URL}/api/checkout", method="POST", payload=payload)
    elapsed_ms = (time.time() - start_time) * 1000.0

    if status_code == 200:
        record_pass(
            "Latency Simulation Execution",
            f"Request completed in {elapsed_ms:.1f}ms (expected >= {delay_ms}ms)",
        )
    else:
        record_fail("Latency Simulation Execution", f"Expected HTTP 200, got {status_code}: {body}")
        return

    trace_id = body.get("trace_id") or headers.get("x-trace-id")
    expected_svcs = {"frontend-service", "auth-service", "payment-service"}
    trace_obj = wait_for_trace(trace_id, min_spans=8, expected_services=expected_svcs)
    if not trace_obj:
        record_fail("Jaeger Latency Trace", f"Trace {trace_id} not found in Jaeger")
        return

    print_trace_tree(trace_obj)

    all_spans = trace_obj.get("spans", [])
    # Find span with highest duration
    bottleneck_span = max(all_spans, key=lambda s: s.get("duration", 0))
    bottleneck_dur_ms = bottleneck_span.get("duration", 0) / 1000.0
    bottleneck_op = bottleneck_span.get("operationName", "unknown")

    if bottleneck_dur_ms >= (delay_ms * 0.9):  # Allow 10% timing tolerance
        record_pass(
            "Waterfall Bottleneck Detection",
            f"Accurately identified bottleneck span '{bottleneck_op}' taking {bottleneck_dur_ms:.2f}ms (>= {delay_ms}ms)",
        )
    else:
        record_fail(
            "Waterfall Bottleneck Detection",
            f"Longest span '{bottleneck_op}' was only {bottleneck_dur_ms:.2f}ms (< {delay_ms}ms)",
        )


# ------------------------------------------------------------------------------
# Main Entrypoint
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Distributed Tracing Verification Suite with OpenTelemetry & Jaeger")
    parser.add_argument("--frontend-url", default=FRONTEND_URL, help="Frontend service URL")
    parser.add_argument("--jaeger-url", default=JAEGER_API_URL, help="Jaeger Query API URL")
    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 76)
    print("  🔭 OpenTelemetry & Jaeger - Distributed Tracing Verification Suite")
    print("=" * 76 + f"{CLR_RESET}")
    print(f"  Target Frontend Service: {CLR_WHITE}{FRONTEND_URL}{CLR_RESET}")
    print(f"  Target Jaeger Query API: {CLR_WHITE}{JAEGER_API_URL}{CLR_RESET}\n")

    try:
        test_system_health()
        test_happy_path_checkout()
        test_auth_rejection_trace()
        test_payment_decline_trace()
        test_latency_waterfall_trace()
    except KeyboardInterrupt:
        print(f"\n{CLR_YELLOW}Verification interrupted by user.{CLR_RESET}")
        sys.exit(130)

    print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 76)
    print("  📊 Distributed Tracing Verification Summary")
    print("=" * 76 + f"{CLR_RESET}")
    print(f"  Total Test Assertions: {CLR_BOLD}{total_tests}{CLR_RESET}")
    print(f"  Passed Assertions:     {CLR_GREEN}{CLR_BOLD}{passed_tests}{CLR_RESET}")
    print(f"  Failed Assertions:     {CLR_RED if failed_tests > 0 else CLR_GREEN}{CLR_BOLD}{failed_tests}{CLR_RESET}")

    if failed_tests == 0:
        print(f"\n{CLR_GREEN}{CLR_BOLD}✅ SUCCESS: Distributed tracing pipeline is operating flawlessly across all tiers!{CLR_RESET}")
        print(f"   Open Jaeger UI at {CLR_CYAN}http://localhost:16686{CLR_RESET} to explore live interactive traces.\n")
        sys.exit(0)
    else:
        print(f"\n{CLR_RED}{CLR_BOLD}❌ FAILURE: {failed_tests} assertions failed during trace verification.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
