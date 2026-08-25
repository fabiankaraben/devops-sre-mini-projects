#!/usr/bin/env python3
"""
Network Port Scanner and Troubleshooter
=======================================
A high-performance, non-blocking asynchronous CLI tool for network diagnostic
scans, TCP connect auditing, firewall filtering detection (OPEN vs CLOSED vs FILTERED),
service banner grabbing, and DNS latency benchmarking.

Part of: DevOps & SRE Mini-Projects
Domain:  01. Linux Scripting
"""

import argparse
import asyncio
from datetime import datetime, timezone
import ipaddress
import json
import os
import re
import socket
import sys
import time
from typing import Any, Dict, List, Optional, Set, Tuple

# Terminal ANSI Color Codes
COLOR_RESET = "\033[0m"
COLOR_BOLD = "\033[1m"
COLOR_DIM = "\033[2m"
COLOR_RED = "\033[0;31m"
COLOR_BOLD_RED = "\033[1;31m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[0;33m"
COLOR_BLUE = "\033[0;34m"
COLOR_MAGENTA = "\033[0;35m"
COLOR_CYAN = "\033[0;36m"
COLOR_WHITE = "\033[1;37m"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Well-known service mappings
COMMON_SERVICES: Dict[int, str] = {
    21: "FTP",
    22: "SSH",
    23: "Telnet",
    25: "SMTP",
    53: "DNS",
    80: "HTTP",
    110: "POP3",
    143: "IMAP",
    443: "HTTPS",
    465: "SMTPS",
    587: "Submission",
    993: "IMAPS",
    995: "POP3S",
    1433: "MSSQL",
    1521: "Oracle",
    3306: "MySQL",
    3389: "RDP",
    5432: "PostgreSQL",
    6379: "Redis",
    8000: "HTTP-Alt",
    8080: "HTTP-Proxy",
    8443: "HTTPS-Alt",
    9000: "Management",
    9022: "SSH-Mock",
    9080: "HTTP-Mock",
    9081: "API-Mock",
    9200: "Elasticsearch",
    9379: "Redis-Mock",
    9432: "Postgres-Mock",
    9843: "HTTPS-Mock",
    9999: "Filtered-Mock",
    27017: "MongoDB",
}

PORT_PROFILES: Dict[str, List[int]] = {
    "common": [21, 22, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995, 3306, 3389, 5432, 6379, 8000, 8080, 8443, 9000],
    "web": [80, 443, 8000, 8080, 8443, 8888, 9080, 9081, 9843],
    "db": [1433, 1521, 3306, 5432, 6379, 9200, 9432, 9379, 27017],
    "mock": [9080, 9081, 9432, 9379, 9022, 9843, 9999],
    "top10": [21, 22, 23, 25, 80, 110, 143, 443, 3306, 8080],
}


def parse_ports(port_input: str) -> List[int]:
    """
    Parses port specification strings into a sorted list of unique port integers.
    Supports:
      - Named profiles: 'web', 'db', 'common', 'mock', 'top10'
      - Comma-separated list: '80,443,8080'
      - Port ranges: '8000-8010'
      - Mixed: '80,443,9000-9005,web'
    """
    ports: Set[int] = set()
    tokens = [t.strip().lower() for t in port_input.split(",") if t.strip()]

    for token in tokens:
        if token in PORT_PROFILES:
            ports.update(PORT_PROFILES[token])
        elif "-" in token:
            parts = token.split("-", 1)
            try:
                start_p = int(parts[0])
                end_p = int(parts[1])
                if start_p > end_p:
                    start_p, end_p = end_p, start_p
                start_p = max(1, min(65535, start_p))
                end_p = max(1, min(65535, end_p))
                ports.update(range(start_p, end_p + 1))
            except ValueError:
                continue
        else:
            try:
                p = int(token)
                if 1 <= p <= 65535:
                    ports.add(p)
            except ValueError:
                continue

    return sorted(list(ports))


def expand_target(target_str: str) -> List[str]:
    """
    Expands a target string into a list of host strings.
    Supports:
      - Single IP: '127.0.0.1', '172.28.0.10'
      - Hostname: 'localhost', 'google.com'
      - CIDR Block: '172.28.0.0/28' -> returns all usable host IPs in subnet
    """
    target_str = target_str.strip()
    # Strip protocol if user passed http:// or https://
    target_str = re.sub(r"^https?://", "", target_str)
    target_str = target_str.split(":")[0].split("/")[0] if "/" not in target_str or ":" in target_str else target_str

    if "/" in target_str:
        try:
            net = ipaddress.ip_network(target_str, strict=False)
            hosts = [str(ip) for ip in net.hosts()]
            # If network is /31 or /32, net.hosts() might be empty or 1 IP
            if not hosts:
                hosts = [str(net.network_address)]
            return hosts
        except ValueError:
            return [target_str]

    return [target_str]


def benchmark_dns(hostname: str) -> Dict[str, Any]:
    """Measures DNS lookup latency in milliseconds."""
    dns_record: Dict[str, Any] = {
        "hostname": hostname,
        "resolved_ips": [],
        "latency_ms": 0.0,
        "error": None,
    }

    # If already an IP address, skip lookup
    try:
        ipaddress.ip_address(hostname)
        dns_record["resolved_ips"] = [hostname]
        dns_record["latency_ms"] = 0.0
        return dns_record
    except ValueError:
        pass

    start = time.time()
    try:
        addr_info = socket.getaddrinfo(hostname, None, family=socket.AF_INET)
        ips = list({info[4][0] for info in addr_info if info[4]})
        dns_record["resolved_ips"] = ips
        dns_record["latency_ms"] = round((time.time() - start) * 1000, 2)
    except socket.gaierror as e:
        dns_record["error"] = f"DNS resolution failed: {e.strerror}"
        dns_record["latency_ms"] = round((time.time() - start) * 1000, 2)
    except Exception as e:
        dns_record["error"] = str(e)
        dns_record["latency_ms"] = round((time.time() - start) * 1000, 2)

    return dns_record


async def grab_banner(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, host: str, port: int) -> str:
    """Attempts to grab a service banner or protocol response from an open TCP socket."""
    banner = ""
    try:
        # Step 1: Check if the server transmits an initial greeting banner (e.g. SSH, FTP, SMTP)
        try:
            initial_data = await asyncio.wait_for(reader.read(512), timeout=0.4)
            if initial_data:
                decoded = initial_data.decode("utf-8", errors="ignore").strip()
                if decoded:
                    # Clean up first line
                    first_line = decoded.splitlines()[0].strip()
                    return first_line[:60]
        except asyncio.TimeoutError:
            pass

        # Step 2: Send protocol-specific probes based on standard port expectations
        if port in (80, 8080, 9080, 9081, 8000, 8888) or port == 443 or port in (8443, 9843):
            # Send HTTP HEAD probe
            probe = f"HEAD / HTTP/1.0\r\nHost: {host}\r\nUser-Agent: NetTroubleshoot/1.0\r\n\r\n".encode("utf-8")
            writer.write(probe)
            await writer.drain()
            resp = await asyncio.wait_for(reader.read(1024), timeout=0.5)
            text = resp.decode("utf-8", errors="ignore")
            for line in text.splitlines():
                if line.lower().startswith("server:"):
                    return line.strip()[:60]
            if text:
                return text.splitlines()[0].strip()[:60]

        elif port in (6379, 9379):
            # Send Redis PING / INFO probe
            writer.write(b"PING\r\n")
            await writer.drain()
            resp = await asyncio.wait_for(reader.read(512), timeout=0.5)
            text = resp.decode("utf-8", errors="ignore").strip()
            if "+PONG" in text:
                return "Redis Key-Value Store (+PONG)"
            return text[:60]

        elif port in (5432, 9432):
            # Send PostgreSQL SSL probe
            writer.write(b"\x00\x00\x00\x08\x04\xd2\x16\x2f")
            await writer.drain()
            resp = await asyncio.wait_for(reader.read(512), timeout=0.5)
            if resp:
                cleaned = resp.decode("utf-8", errors="ignore").strip()
                if cleaned:
                    return cleaned.splitlines()[0][:60]
                return "PostgreSQL Database Engine"

        else:
            # Generic newline probe
            writer.write(b"\r\n\r\n")
            await writer.drain()
            resp = await asyncio.wait_for(reader.read(512), timeout=0.3)
            if resp:
                return resp.decode("utf-8", errors="ignore").splitlines()[0].strip()[:60]

    except Exception:
        pass

    return banner


async def probe_port(
    host: str,
    port: int,
    timeout: float,
    semaphore: asyncio.Semaphore,
    grab_banners: bool = True,
) -> Dict[str, Any]:
    """
    Performs a non-blocking TCP connect scan against a target port.
    Returns structured port state:
      - OPEN: TCP 3-way handshake succeeded (SYN-ACK received).
      - CLOSED: Connection actively refused with TCP RST packet.
      - FILTERED: Connection timed out (Packets dropped silently by firewall / iptables).
    """
    service_name = COMMON_SERVICES.get(port, "Unknown")
    record: Dict[str, Any] = {
        "host": host,
        "port": port,
        "service": service_name,
        "state": "UNKNOWN",
        "rtt_ms": None,
        "banner": "",
        "error": None,
    }

    async with semaphore:
        start_time = time.time()
        try:
            # Attempt TCP connect
            conn = asyncio.open_connection(host, port)
            reader, writer = await asyncio.wait_for(conn, timeout=timeout)
            rtt = (time.time() - start_time) * 1000
            record["state"] = "OPEN"
            record["rtt_ms"] = round(rtt, 2)

            if grab_banners:
                banner = await grab_banner(reader, writer, host, port)
                record["banner"] = banner

            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

        except asyncio.TimeoutError:
            # No SYN-ACK or RST received -> packet dropped (FILTERED)
            record["state"] = "FILTERED"
            record["rtt_ms"] = round(timeout * 1000, 2)
            record["error"] = "Connection timed out (firewall drop)"

        except ConnectionRefusedError:
            # TCP RST received immediately -> port closed
            rtt = (time.time() - start_time) * 1000
            record["state"] = "CLOSED"
            record["rtt_ms"] = round(rtt, 2)
            record["error"] = "Connection refused (TCP RST)"

        except OSError as e:
            # Check for unreachable network or host errors
            rtt = (time.time() - start_time) * 1000
            record["rtt_ms"] = round(rtt, 2)
            err_str = str(e).lower()
            if "refused" in err_str:
                record["state"] = "CLOSED"
                record["error"] = "Connection refused"
            elif "unreachable" in err_str or "no route" in err_str:
                record["state"] = "FILTERED"
                record["error"] = f"Host/Network unreachable: {str(e)}"
            elif "timeout" in err_str:
                record["state"] = "FILTERED"
                record["error"] = "Timed out"
            else:
                record["state"] = "CLOSED"
                record["error"] = str(e)

        except Exception as e:
            record["state"] = "ERROR"
            record["error"] = f"Scan error: {str(e)}"

    return record


async def scan_all_targets(
    hosts: List[str],
    ports: List[int],
    timeout: float = 1.0,
    concurrency: int = 50,
    grab_banners: bool = True,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Runs concurrent port probes across all host-port combinations."""
    semaphore = asyncio.Semaphore(concurrency)

    # 1. DNS Resolution Phase
    dns_records: List[Dict[str, Any]] = []
    unique_hosts = sorted(list(set(hosts)))
    for h in unique_hosts:
        dns_info = benchmark_dns(h)
        dns_records.append(dns_info)

    # 2. Port Probing Phase
    tasks = []
    for h in unique_hosts:
        for p in ports:
            tasks.append(probe_port(h, p, timeout, semaphore, grab_banners))

    results = await asyncio.gather(*tasks)
    # Sort by host, then port
    results_list = list(results)
    results_list.sort(key=lambda x: (x["host"], x["port"]))
    return results_list, dns_records


def format_state_badge(state: str) -> str:
    """Renders colorized status badges for terminal table."""
    if state == "OPEN":
        return f"{COLOR_GREEN}[ OPEN  ]{COLOR_RESET}"
    elif state == "CLOSED":
        return f"{COLOR_DIM}[CLOSED ]{COLOR_RESET}"
    elif state == "FILTERED":
        return f"{COLOR_RED}[FILTER ]{COLOR_RESET}"
    elif state == "ERROR":
        return f"{COLOR_MAGENTA}[ ERROR ]{COLOR_RESET}"
    return f"{COLOR_YELLOW}[ {state} ]{COLOR_RESET}"


def print_cli_table(
    results: List[Dict[str, Any]],
    dns_records: List[Dict[str, Any]],
    scan_duration_s: float,
    show_all: bool = False,
):
    """Renders formatted ANSI color terminal table."""
    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                         NETWORK PORT SCANNER & TROUBLESHOOTER REPORT                                   {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Scan Time : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"Execution : {round(scan_duration_s, 3)} seconds\n")

    # DNS Resolution Section
    if dns_records:
        print(f"{COLOR_BOLD}DNS RESOLUTION & LATENCY:{COLOR_RESET}")
        for d in dns_records:
            if d["error"]:
                print(f"  - {d['hostname']:<25} -> {COLOR_RED}FAILED{COLOR_RESET} ({d['error']}) [{d['latency_ms']} ms]")
            else:
                ips_str = ", ".join(d["resolved_ips"])
                print(f"  - {d['hostname']:<25} -> {COLOR_CYAN}{ips_str:<25}{COLOR_RESET} [Latency: {COLOR_GREEN}{d['latency_ms']} ms{COLOR_RESET}]")
        print()

    # Table Header
    # STATE(9) | TARGET(22) | PORT(6) | SERVICE(14) | RTT(9) | BANNER / DETAILS(35)
    header_fmt = "{:<9}  {:<20}  {:<6}  {:<14}  {:<9}  {:<35}"
    print(COLOR_BOLD + header_fmt.format("STATE", "TARGET HOST", "PORT", "SERVICE", "RTT", "BANNER / DIAGNOSTIC") + COLOR_RESET)
    print(COLOR_DIM + "-" * 104 + COLOR_RESET)

    open_count = sum(1 for r in results if r["state"] == "OPEN")
    closed_count = sum(1 for r in results if r["state"] == "CLOSED")
    filtered_count = sum(1 for r in results if r["state"] == "FILTERED")
    error_count = sum(1 for r in results if r["state"] == "ERROR")

    # Filter display: if show_all is False and many ports scanned, highlight open and filtered
    display_results = results if show_all or len(results) <= 30 else [r for r in results if r["state"] != "CLOSED"]

    for r in display_results:
        badge = format_state_badge(r["state"])
        host_display = r["host"]
        if len(host_display) > 20:
            host_display = host_display[:17] + "..."

        port_display = str(r["port"])
        service_display = r["service"]
        rtt_str = f"{r['rtt_ms']} ms" if r["rtt_ms"] is not None else "N/A"

        detail_display = ""
        if r["state"] == "OPEN":
            detail_display = f"{COLOR_GREEN}{r['banner'] or 'TCP Handshake OK'}{COLOR_RESET}"
        elif r["state"] == "FILTERED":
            detail_display = f"{COLOR_RED}{r['error'] or 'Packet Dropped (Firewall)'}{COLOR_RESET}"
        elif r["state"] == "CLOSED":
            detail_display = f"{COLOR_DIM}{r['error'] or 'Connection Refused'}{COLOR_RESET}"
        else:
            detail_display = f"{COLOR_MAGENTA}{r['error'] or 'Unknown Error'}{COLOR_RESET}"

        if len(detail_display) > 55:
            detail_display = detail_display[:52] + "..."

        print(f"{badge}  {host_display:<20}  {port_display:<6}  {service_display:<14}  {rtt_str:<9}  {detail_display}")

    if not show_all and len(results) > len(display_results):
        hidden = len(results) - len(display_results)
        print(f"{COLOR_DIM}... ({hidden} closed ports omitted. Use --all to display all closed ports) ...{COLOR_RESET}")

    print(COLOR_DIM + "-" * 104 + COLOR_RESET)
    print(f"\n{COLOR_BOLD}SUMMARY STATISTICS:{COLOR_RESET}")
    print(f"  Total Probes : {COLOR_BOLD}{len(results)}{COLOR_RESET}")
    print(f"  {COLOR_GREEN}✔ OPEN Ports   {COLOR_RESET}: {open_count}")
    print(f"  {COLOR_DIM}○ CLOSED Ports {COLOR_RESET}: {closed_count}")
    print(f"  {COLOR_RED}✖ FILTERED Port{COLOR_RESET}: {filtered_count}")
    print(f"  {COLOR_MAGENTA}⚠ Errors       {COLOR_RESET}: {error_count}")
    print(f"  Scan Duration: {round(scan_duration_s, 3)}s\n")


def generate_markdown_report(
    results: List[Dict[str, Any]],
    dns_records: List[Dict[str, Any]],
    scan_duration_s: float,
) -> str:
    """Generates a clean GitHub Flavored Markdown report table."""
    open_count = sum(1 for r in results if r["state"] == "OPEN")
    closed_count = sum(1 for r in results if r["state"] == "CLOSED")
    filtered_count = sum(1 for r in results if r["state"] == "FILTERED")

    lines = [
        "# Network Port Scan & Troubleshooter Report",
        "",
        f"- **Scan Timestamp**: `{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}`",
        f"- **Scan Duration**: `{round(scan_duration_s, 3)} seconds`",
        f"- **Total Probes**: `{len(results)}` (Open: `{open_count}`, Closed: `{closed_count}`, Filtered: `{filtered_count}`)",
        "",
    ]

    if dns_records:
        lines.append("## DNS Resolution Benchmarks")
        lines.append("")
        lines.append("| Hostname | Resolved IPs | Latency (ms) | Status |")
        lines.append("| :--- | :--- | :--- | :--- |")
        for d in dns_records:
            ips = ", ".join(d["resolved_ips"]) if d["resolved_ips"] else "N/A"
            status = "FAILED" if d["error"] else "OK"
            lines.append(f"| `{d['hostname']}` | `{ips}` | `{d['latency_ms']} ms` | **{status}** |")
        lines.append("")

    lines.append("## Port Status Diagnostics")
    lines.append("")
    lines.append("| Host | Port | Service | State | RTT (ms) | Banner / Details |")
    lines.append("| :--- | :--- | :--- | :--- | :--- | :--- |")

    for r in results:
        state_badge = f"**`{r['state']}`**"
        rtt = f"{r['rtt_ms']} ms" if r["rtt_ms"] is not None else "N/A"
        details = (r["banner"] or r["error"] or "N/A").replace("|", "\\|")
        lines.append(f"| `{r['host']}` | `{r['port']}` | `{r['service']}` | {state_badge} | `{rtt}` | {details} |")

    lines.append("")
    return "\n".join(lines) + "\n"


def generate_json_report(
    results: List[Dict[str, Any]],
    dns_records: List[Dict[str, Any]],
    scan_duration_s: float,
) -> str:
    """Generates structured machine-parseable JSON."""
    open_count = sum(1 for r in results if r["state"] == "OPEN")
    closed_count = sum(1 for r in results if r["state"] == "CLOSED")
    filtered_count = sum(1 for r in results if r["state"] == "FILTERED")
    error_count = sum(1 for r in results if r["state"] == "ERROR")

    data = {
        "scan_metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "duration_seconds": round(scan_duration_s, 3),
            "total_probes": len(results),
            "open_count": open_count,
            "closed_count": closed_count,
            "filtered_count": filtered_count,
            "error_count": error_count,
        },
        "dns_benchmarks": dns_records,
        "results": results,
    }
    return json.dumps(data, indent=2)


def generate_prometheus_metrics(
    results: List[Dict[str, Any]],
    dns_records: List[Dict[str, Any]],
) -> str:
    """
    Generates Prometheus / OpenMetrics text exposition format.
    Metrics exported:
      - net_port_state{host="...",port="...",service="...",state="open|closed|filtered"} 1|0
      - net_port_rtt_seconds{host="...",port="..."} <sec>
      - net_dns_lookup_latency_seconds{hostname="..."} <sec>
      - net_scan_total_ports <count>
      - net_scan_open_ports <count>
      - net_scan_filtered_ports <count>
    """
    lines = [
        "# HELP net_port_state Binary indicator of port status (1=matching state, 0=otherwise)",
        "# TYPE net_port_state gauge",
    ]

    for r in results:
        h = r["host"]
        p = r["port"]
        svc = r["service"]
        for st in ("open", "closed", "filtered"):
            val = 1 if r["state"].lower() == st else 0
            lines.append(f'net_port_state{{host="{h}",port="{p}",service="{svc}",state="{st}"}} {val}')

    lines.append("")
    lines.append("# HELP net_port_rtt_seconds Round trip time of the TCP connect handshake in seconds")
    lines.append("# TYPE net_port_rtt_seconds gauge")
    for r in results:
        if r["rtt_ms"] is not None:
            sec = round(r["rtt_ms"] / 1000.0, 5)
            lines.append(f'net_port_rtt_seconds{{host="{r["host"]}",port="{r["port"]}"}} {sec}')

    lines.append("")
    lines.append("# HELP net_dns_lookup_latency_seconds Latency of DNS hostname resolution in seconds")
    lines.append("# TYPE net_dns_lookup_latency_seconds gauge")
    for d in dns_records:
        sec = round(d["latency_ms"] / 1000.0, 5)
        lines.append(f'net_dns_lookup_latency_seconds{{hostname="{d["hostname"]}"}} {sec}')

    lines.append("")
    lines.append("# HELP net_scan_total_ports Total number of target host/port combinations probed")
    lines.append("# TYPE net_scan_total_ports gauge")
    lines.append(f"net_scan_total_ports {len(results)}")

    lines.append("")
    lines.append("# HELP net_scan_open_ports Total number of accessible open ports found")
    lines.append("# TYPE net_scan_open_ports gauge")
    open_c = sum(1 for r in results if r["state"] == "OPEN")
    lines.append(f"net_scan_open_ports {open_c}")

    lines.append("")
    lines.append("# HELP net_scan_filtered_ports Total number of filtered / firewall-dropped ports found")
    lines.append("# TYPE net_scan_filtered_ports gauge")
    filt_c = sum(1 for r in results if r["state"] == "FILTERED")
    lines.append(f"net_scan_filtered_ports {filt_c}")

    return "\n".join(lines) + "\n"


def load_targets_from_file(file_path: str) -> List[str]:
    """Loads target lines from file, ignoring comments and whitespace."""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Targets file not found: {file_path}")

    targets = []
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            cleaned = line.strip()
            if cleaned and not cleaned.startswith("#"):
                targets.append(cleaned)
    return targets


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Network Port Scanner and Troubleshooter - High-performance async diagnostic CLI for SREs and Network Engineers.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "-t", "--target",
        action="append",
        dest="targets",
        help="Target host, IP address, or CIDR block (e.g. '127.0.0.1', 'localhost', '172.28.0.0/28'). Can be repeated.",
    )
    parser.add_argument(
        "-f", "--file",
        dest="target_file",
        help="Path to file containing list of targets (one per line).",
    )
    parser.add_argument(
        "-p", "--ports",
        default="mock",
        help="Port specification (e.g. '80,443', '8000-8020', profile names: 'mock', 'web', 'db', 'common', 'top10'). Default: 'mock'.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=1.0,
        help="TCP connection timeout in seconds (default: 1.0s).",
    )
    parser.add_argument(
        "-c", "--concurrency",
        type=int,
        default=50,
        help="Maximum concurrent connection probes (default: 50).",
    )
    parser.add_argument(
        "--no-banner",
        action="store_true",
        help="Disable service banner grabbing for faster scans.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        dest="show_all",
        help="Display all scanned ports in CLI table, including closed ports.",
    )
    parser.add_argument(
        "-m", "--markdown",
        action="store_true",
        dest="markdown_output",
        help="Output report formatted as GitHub Flavored Markdown.",
    )
    parser.add_argument(
        "-j", "--json",
        action="store_true",
        dest="json_output",
        help="Output report in machine-readable JSON format.",
    )
    parser.add_argument(
        "--prometheus",
        action="store_true",
        dest="prom_output",
        help="Output results in Prometheus / OpenMetrics text exposition format.",
    )
    parser.add_argument(
        "-o", "--output",
        dest="output_file",
        help="Write output report directly to specified file path inside project directory.",
    )
    parser.add_argument(
        "--require-open",
        action="append",
        dest="required_ports",
        help="Assert specific ports MUST be OPEN (e.g. --require-open 80). If closed/filtered, exit with code 1.",
    )
    parser.add_argument(
        "--no-fail",
        action="store_true",
        help="Always exit with code 0 regardless of port states.",
    )

    args = parser.parse_args()

    # Collect raw target inputs
    raw_targets: List[str] = []
    if args.targets:
        for t in args.targets:
            for item in t.split(","):
                cleaned = item.strip()
                if cleaned:
                    raw_targets.append(cleaned)

    if args.target_file:
        try:
            raw_targets.extend(load_targets_from_file(args.target_file))
        except Exception as e:
            print(f"{COLOR_RED}Error loading targets file:{COLOR_RESET} {e}", file=sys.stderr)
            return 3

    if not raw_targets:
        # Default to localhost if nothing specified
        raw_targets = ["127.0.0.1"]

    # Expand CIDRs and hostnames
    all_hosts: List[str] = []
    for t in raw_targets:
        expanded = expand_target(t)
        all_hosts.extend(expanded)

    # Deduplicate hosts
    seen_hosts = set()
    deduped_hosts: List[str] = []
    for h in all_hosts:
        if h not in seen_hosts:
            seen_hosts.add(h)
            deduped_hosts.append(h)

    # Parse ports
    ports_to_scan = parse_ports(args.ports)
    if not ports_to_scan:
        print(f"{COLOR_RED}Error: Invalid port specification '{args.ports}'.{COLOR_RESET}", file=sys.stderr)
        return 3

    # Execute Scan
    start_time = time.time()
    try:
        results, dns_records = asyncio.run(
            scan_all_targets(
                hosts=deduped_hosts,
                ports=ports_to_scan,
                timeout=args.timeout,
                concurrency=args.concurrency,
                grab_banners=not args.no_banner,
            )
        )
    except Exception as e:
        print(f"{COLOR_RED}Scan execution error:{COLOR_RESET} {e}", file=sys.stderr)
        return 3

    total_duration = time.time() - start_time

    # Render Output Format
    if args.json_output:
        rendered = generate_json_report(results, dns_records, total_duration)
        if args.output_file:
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(rendered + "\n")
        else:
            print(rendered)
    elif args.markdown_output:
        rendered = generate_markdown_report(results, dns_records, total_duration)
        if args.output_file:
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(rendered)
        else:
            print(rendered)
    elif args.prom_output:
        rendered = generate_prometheus_metrics(results, dns_records)
        if args.output_file:
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(rendered)
        else:
            print(rendered, end="")
    else:
        if args.output_file:
            md_text = generate_markdown_report(results, dns_records, total_duration)
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(md_text)
        print_cli_table(results, dns_records, total_duration, show_all=args.show_all)

    if args.no_fail:
        return 0

    # Verification of Required Ports
    if args.required_ports:
        req_ports: Set[int] = set()
        for rp in args.required_ports:
            try:
                req_ports.add(int(rp))
            except ValueError:
                pass
        
        for r in results:
            if r["port"] in req_ports and r["state"] != "OPEN":
                return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
