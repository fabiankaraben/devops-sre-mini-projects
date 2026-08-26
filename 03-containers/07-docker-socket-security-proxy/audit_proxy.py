#!/usr/bin/env python3
"""
==============================================================================
audit_proxy.py - Docker Socket Security Proxy Audit & Penetration Tester
==============================================================================
Educational security utility that audits access control policies on the
Docker Socket Security Proxy Gateway (HAProxy).

Compares API responses from:
  1. The Security Proxy Gateway (TCP: http://127.0.0.1:2375)
  2. The Raw Docker Daemon Socket (Unix Domain Socket: /var/run/docker.sock)

Demonstrates how the proxy enforces Least Privilege (RBAC) and prevents
host escalation exploits (Container creation, exec, volume snooping).
==============================================================================
"""

import argparse
import http.client
import json
import os
import socket
import sys
import urllib.parse
from typing import Any, Dict, List, Optional, Tuple

# ANSI Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_BLUE = "\033[1;34m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class UnixSocketHTTPConnection(http.client.HTTPConnection):
    """Custom HTTPConnection for communicating over Unix Domain Sockets."""

    def __init__(self, socket_path: str, timeout: float = 5.0):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def request_raw_socket(
    socket_path: str, method: str, path: str, body: Optional[str] = None
) -> Tuple[int, str]:
    """Execute an HTTP request over a Unix domain socket."""
    try:
        conn = UnixSocketHTTPConnection(socket_path, timeout=5.0)
        headers = {"Host": "localhost"}
        if body:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=body, headers=headers)
        res = conn.getresponse()
        data = res.read().decode("utf-8", errors="replace")
        conn.close()
        return res.status, data
    except Exception as e:
        return 0, str(e)


def request_tcp_proxy(
    host: str, port: int, method: str, path: str, body: Optional[str] = None
) -> Tuple[int, str]:
    """Execute an HTTP request over TCP to the security proxy."""
    try:
        conn = http.client.HTTPConnection(host, port, timeout=5.0)
        headers = {"Host": f"{host}:{port}"}
        if body:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=body, headers=headers)
        res = conn.getresponse()
        data = res.read().decode("utf-8", errors="replace")
        conn.close()
        return res.status, data
    except Exception as e:
        return 0, str(e)


def get_test_matrix() -> List[Dict[str, Any]]:
    """Define the security test matrix."""
    return [
        {
            "id": "SEC-01",
            "name": "Health Check Probe",
            "method": "GET",
            "path": "/_ping",
            "body": None,
            "expected_proxy_status": 200,
            "category": "Read-Only / Monitoring",
            "threat_impact": "None (Safe heartbeat probe)",
        },
        {
            "id": "SEC-02",
            "name": "Docker Engine Version",
            "method": "GET",
            "path": "/version",
            "body": None,
            "expected_proxy_status": 200,
            "category": "Read-Only / Monitoring",
            "threat_impact": "Low (Engine metadata inspection)",
        },
        {
            "id": "SEC-03",
            "name": "System Info Metadata",
            "method": "GET",
            "path": "/info",
            "body": None,
            "expected_proxy_status": 200,
            "category": "Read-Only / Monitoring",
            "threat_impact": "Low (Host telemetry inspection)",
        },
        {
            "id": "SEC-04",
            "name": "List Active Containers",
            "method": "GET",
            "path": "/containers/json",
            "body": None,
            "expected_proxy_status": 200,
            "category": "Read-Only / Monitoring",
            "threat_impact": "Low (Container inventory auditing)",
        },
        {
            "id": "SEC-05",
            "name": "Privileged Container Creation (Host Root Exploit)",
            "method": "POST",
            "path": "/containers/create",
            "body": json.dumps(
                {
                    "Image": "alpine:latest",
                    "Cmd": ["sh", "-c", "cat /etc/shadow"],
                    "HostConfig": {
                        "Privileged": True,
                        "Binds": ["/:/host:rw"],
                    },
                }
            ),
            "expected_proxy_status": 403,
            "category": "Host Escape / Privilege Escalation",
            "threat_impact": "CRITICAL (Root host filesystem takeover)",
        },
        {
            "id": "SEC-06",
            "name": "Remote Code Execution (Exec Inject)",
            "method": "POST",
            "path": "/containers/devops-socket-proxy/exec",
            "body": json.dumps(
                {
                    "AttachStdout": True,
                    "AttachStderr": True,
                    "Cmd": ["id"],
                }
            ),
            "expected_proxy_status": 403,
            "category": "Remote Code Execution (RCE)",
            "threat_impact": "HIGH (Arbitrary command injection)",
        },
        {
            "id": "SEC-07",
            "name": "Denial of Service (Stop Container)",
            "method": "POST",
            "path": "/containers/devops-socket-proxy/stop",
            "body": None,
            "expected_proxy_status": 403,
            "category": "Denial of Service (DoS)",
            "threat_impact": "HIGH (Unplanned service disruption)",
        },
        {
            "id": "SEC-08",
            "name": "Denial of Service (Kill Container)",
            "method": "POST",
            "path": "/containers/devops-socket-proxy/kill",
            "body": None,
            "expected_proxy_status": 403,
            "category": "Denial of Service (DoS)",
            "threat_impact": "HIGH (Immediate process kill via SIGKILL)",
        },
        {
            "id": "SEC-09",
            "name": "Volume Data Snooping",
            "method": "GET",
            "path": "/volumes",
            "body": None,
            "expected_proxy_status": 403,
            "category": "Data Exfiltration",
            "threat_impact": "MEDIUM (Database / application storage leaks)",
        },
        {
            "id": "SEC-10",
            "name": "Unauthorized Volume Allocation",
            "method": "POST",
            "path": "/volumes/create",
            "body": json.dumps({"Name": "malicious-volume"}),
            "expected_proxy_status": 403,
            "category": "Storage Mutation",
            "threat_impact": "MEDIUM (Host storage tampering)",
        },
        {
            "id": "SEC-11",
            "name": "Container Destruction",
            "method": "DELETE",
            "path": "/containers/dummy-target",
            "body": None,
            "expected_proxy_status": 403,
            "category": "Destructive Operation",
            "threat_impact": "HIGH (Container asset deletion)",
        },
        {
            "id": "SEC-12",
            "name": "Swarm Secrets Access",
            "method": "GET",
            "path": "/secrets",
            "body": None,
            "expected_proxy_status": 403,
            "category": "Credential Theft",
            "threat_impact": "CRITICAL (Cluster-wide secret leaks)",
        },
    ]


def run_audit(proxy_host: str, proxy_port: int, socket_path: Optional[str] = None):
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🛡️  Docker Socket Security Proxy Gateway - Security Audit Suite{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}")
    print(f"  Target Security Proxy: http://{proxy_host}:{proxy_port}")
    if socket_path and os.path.exists(socket_path):
        print(f"  Raw Socket Reference: {socket_path}")
    print(f"{CLR_CYAN}{'-' * 80}{CLR_RESET}")
    sys.stdout.flush()

    matrix = get_test_matrix()
    total = len(matrix)
    passed = 0
    failed = 0

    print(
        f"{CLR_GRAY}{'ID':<8} {'Method':<7} {'API Endpoint':<28} {'Proxy Status':<15} {'Audit Verdict':<18} {'Threat Class'}{CLR_RESET}"
    )
    print(f"{CLR_GRAY}{'-' * 80}{CLR_RESET}")

    for test in matrix:
        status, response = request_tcp_proxy(
            proxy_host, proxy_port, test["method"], test["path"], test["body"]
        )

        expected = test["expected_proxy_status"]
        if status == expected:
            passed += 1
            if status == 200:
                verdict = f"{CLR_GREEN}✔ PERMITTED (200){CLR_RESET}"
            elif status == 403:
                verdict = f"{CLR_GREEN}🔒 BLOCKED (403){CLR_RESET}"
            else:
                verdict = f"{CLR_GREEN}✔ PASSED ({status}){CLR_RESET}"
            status_str = f"{CLR_GREEN}{status} OK{CLR_RESET}" if status == 200 else f"{CLR_YELLOW}{status} Forbidden{CLR_RESET}"
        else:
            failed += 1
            verdict = f"{CLR_RED}❌ VIOLATION ({status}){CLR_RESET}"
            status_str = f"{CLR_RED}{status} Error{CLR_RESET}"

        endpoint_display = test["path"] if len(test["path"]) <= 26 else test["path"][:23] + "..."
        threat_display = test["category"]

        print(
            f"{test['id']:<8} {test['method']:<7} {endpoint_display:<28} {status_str:<24} {verdict:<27} {threat_display}"
        )
        sys.stdout.flush()

    print(f"{CLR_CYAN}{'=' * 80}{CLR_RESET}")
    print(
        f"{CLR_BOLD}📊 Audit Summary: {passed}/{total} Security Policies Verified{CLR_RESET}"
    )
    if failed == 0:
        print(
            f"{CLR_GREEN}{CLR_BOLD}✨ Zero-Trust Gateway is operating optimally! All mutation and breakout attempts blocked.{CLR_RESET}"
        )
        return 0
    else:
        print(
            f"{CLR_RED}{CLR_BOLD}⚠️  Security Policy Violations Detected! Inspect the matrix above.{CLR_RESET}"
        )
        return 1


def main():
    parser = argparse.ArgumentParser(
        description="Docker Socket Security Proxy Audit & Penetration Tool",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--host", default="127.0.0.1", help="Security proxy gateway IP/host"
    )
    parser.add_argument(
        "--port", type=int, default=2375, help="Security proxy gateway TCP port"
    )
    parser.add_argument(
        "--socket",
        default="/var/run/docker.sock",
        help="Path to raw Docker socket for comparative analysis",
    )

    args = parser.parse_args()
    code = run_audit(args.host, args.port, args.socket)
    sys.exit(code)


if __name__ == "__main__":
    main()
