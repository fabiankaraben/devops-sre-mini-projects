#!/usr/bin/env python3
"""
SSL/TLS Certificate Expiry Auditor
==================================
A high-performance, concurrent network auditing CLI tool that scans web domains
or IP endpoints, establishes TLS handshakes, extracts certificate metadata,
evaluates expiration status, and exports ANSI tables, JSON, or Prometheus metrics.

Part of: DevOps & SRE Mini-Projects
Domain:  01. Linux Scripting
"""

import argparse
import concurrent.futures
from datetime import datetime, timezone
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

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


def parse_target(target_str: str) -> Tuple[str, int, str]:
    """
    Parses a target string into (host, port, sni_hostname).
    Supports formats:
      - 'example.com'          -> ('example.com', 443, 'example.com')
      - 'example.com:8443'     -> ('example.com', 8443, 'example.com')
      - '127.0.0.1:8443@valid.local' -> ('127.0.0.1', 8443, 'valid.local')
      - '[::1]:8443'           -> ('::1', 8443, '::1')
    """
    target_str = target_str.strip()
    sni_override = ""

    if "@" in target_str:
        target_str, sni_override = target_str.split("@", 1)
        sni_override = sni_override.strip()

    # Strip URL schemes if user passed https://
    target_str = re.sub(r"^https?://", "", target_str)
    # Strip any trailing path or query
    target_str = target_str.split("/")[0]

    # Handle IPv6 [::1]:port
    if target_str.startswith("["):
        match = re.match(r"^\[([a-fA-F0-9:]+)\](?::(\d+))?$", target_str)
        if match:
            host = match.group(1)
            port = int(match.group(2)) if match.group(2) else 443
            sni = sni_override if sni_override else host
            return host, port, sni

    if ":" in target_str:
        parts = target_str.rsplit(":", 1)
        host = parts[0]
        try:
            port = int(parts[1])
        except ValueError:
            port = 443
    else:
        host = target_str
        port = 443

    sni = sni_override if sni_override else host
    return host, port, sni


def parse_asn1_date(date_str: str) -> Optional[datetime]:
    """
    Parses standard ASN.1 / OpenSSL timestamp strings or ISO-8601 strings into timezone-aware UTC datetime.
    Examples:
      - 'Sep  4 02:56:47 2026 GMT'
      - 'Nov 23 02:56:47 2026 GMT'
      - '2026-11-23T02:58:20+00:00'
      - '2026-09-04 02:56:47'
    """
    if not date_str:
        return None

    date_str = date_str.strip()

    # First attempt standard ISO-8601 format
    try:
        dt = datetime.fromisoformat(date_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except ValueError:
        pass

    formats = [
        "%b %d %H:%M:%S %Y %Z",      # 'Sep 4 02:56:47 2026 GMT'
        "%b  %d %H:%M:%S %Y %Z",     # 'Sep  4 02:56:47 2026 GMT' (double space)
        "%B %d %H:%M:%S %Y %Z",
        "%B  %d %H:%M:%S %Y %Z",
        "%Y-%m-%d %H:%M:%SZ",
        "%Y-%m-%d %H:%M:%S %Z",
        "%Y-%m-%d %H:%M:%S",
    ]

    for fmt in formats:
        try:
            dt = datetime.strptime(date_str, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue

    # Clean double spaces and try once more
    cleaned = re.sub(r"\s+", " ", date_str)
    for fmt in ["%b %d %H:%M:%S %Y %Z", "%B %d %H:%M:%S %Y %Z"]:
        try:
            dt = datetime.strptime(cleaned, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue

    return None


def extract_cert_field(tuples_list: Any, field_name: str) -> str:
    """Extracts a specific attribute (e.g. commonName, organizationName) from an X.509 name tuple."""
    if not tuples_list:
        return ""
    for rdn in tuples_list:
        for key, val in rdn:
            if key == field_name:
                return str(val)
    return ""


def audit_endpoint(
    target: str,
    warning_days: int = 30,
    critical_days: int = 7,
    timeout: float = 5.0,
    insecure: bool = False,
    ca_file: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Establishes a TLS connection to the endpoint, extracts certificate details,
    calculates expiration days, and returns a structured audit record.
    """
    host, port, sni = parse_target(target)
    start_time = time.time()

    result: Dict[str, Any] = {
        "target": target,
        "host": host,
        "port": port,
        "sni": sni,
        "status": "UNKNOWN",
        "days_remaining": None,
        "valid_from": None,
        "valid_until": None,
        "subject_cn": None,
        "subject_alt_names": [],
        "issuer_org": None,
        "issuer_cn": None,
        "serial_number": None,
        "tls_version": None,
        "cipher": None,
        "cipher_bits": None,
        "error_message": None,
        "response_time_ms": 0.0,
    }

    # Prepare SSL Context
    try:
        if insecure:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        else:
            ctx = ssl.create_default_context()
            if ca_file:
                ctx.load_verify_locations(cafile=ca_file)
    except Exception as e:
        result["status"] = "ERROR"
        result["error_message"] = f"SSL Context Error: {str(e)}"
        result["response_time_ms"] = round((time.time() - start_time) * 1000, 2)
        return result

    # Perform socket connection and TLS handshake
    ssock = None
    try:
        raw_sock = socket.create_connection((host, port), timeout=timeout)
        ssock = ctx.wrap_socket(raw_sock, server_hostname=sni if sni else None)
        
        # TLS Protocol and Cipher Suite
        result["tls_version"] = ssock.version()
        cipher_tuple = ssock.cipher()
        if cipher_tuple:
            result["cipher"] = cipher_tuple[0]
            result["cipher_bits"] = cipher_tuple[2]

        # Extract certificate info
        cert_dict = ssock.getpeercert()
        der_bytes = ssock.getpeercert(binary_form=True)

        # In CERT_NONE mode, getpeercert() returns empty dict.
        # Fallback to test_decode_cert on temporary PEM file inside mini-project directory.
        if (not cert_dict or not cert_dict.get("notAfter")) and der_bytes:
            pem_str = ssl.DER_cert_to_PEM_cert(der_bytes)
            tmp_dir = os.path.join(SCRIPT_DIR, ".tmp_decode")
            os.makedirs(tmp_dir, exist_ok=True)
            tmp_file = os.path.join(tmp_dir, f"cert_{os.getpid()}_{int(time.time()*1000)}.pem")
            try:
                with open(tmp_file, "w", encoding="utf-8") as f:
                    f.write(pem_str)
                if hasattr(ssl, "_ssl") and hasattr(ssl._ssl, "_test_decode_cert"):
                    cert_dict = ssl._ssl._test_decode_cert(tmp_file)
            finally:
                if os.path.exists(tmp_file):
                    os.remove(tmp_file)
                try:
                    os.rmdir(tmp_dir)
                except OSError:
                    pass

        if not cert_dict:
            raise ssl.SSLError("Failed to decode peer certificate metadata.")

        # Extract Fields
        subject = cert_dict.get("subject", ())
        issuer = cert_dict.get("issuer", ())
        sans = cert_dict.get("subjectAltName", ())

        result["subject_cn"] = extract_cert_field(subject, "commonName")
        result["issuer_org"] = extract_cert_field(issuer, "organizationName") or extract_cert_field(issuer, "commonName")
        result["issuer_cn"] = extract_cert_field(issuer, "commonName")
        result["serial_number"] = cert_dict.get("serialNumber")

        # Extract SANs
        san_list = []
        for san_type, san_val in sans:
            san_list.append(f"{san_type}:{san_val}")
        result["subject_alt_names"] = san_list

        # Dates & Expiration
        not_before_raw = cert_dict.get("notBefore")
        not_after_raw = cert_dict.get("notAfter")

        dt_before = parse_asn1_date(not_before_raw)
        dt_after = parse_asn1_date(not_after_raw)

        if dt_before:
            result["valid_from"] = dt_before.isoformat()
        if dt_after:
            result["valid_until"] = dt_after.isoformat()

            now_utc = datetime.now(timezone.utc)
            delta_seconds = (dt_after - now_utc).total_seconds()
            days_left = delta_seconds / 86400.0
            result["days_remaining"] = round(days_left, 1)

            # Determine Status
            if days_left <= 0:
                result["status"] = "EXPIRED"
            elif days_left <= critical_days:
                result["status"] = "CRITICAL"
            elif days_left <= warning_days:
                result["status"] = "WARNING"
            else:
                result["status"] = "OK"
        else:
            result["status"] = "ERROR"
            result["error_message"] = f"Could not parse expiration date: '{not_after_raw}'"

    except socket.timeout:
        result["status"] = "ERROR"
        result["error_message"] = f"Connection timed out after {timeout}s"
    except ConnectionRefusedError:
        result["status"] = "ERROR"
        result["error_message"] = "Connection refused (port not listening or firewall drop)"
    except socket.gaierror as e:
        result["status"] = "ERROR"
        result["error_message"] = f"DNS resolution failed: {e.strerror}"
    except ssl.SSLCertVerificationError as e:
        result["status"] = "ERROR"
        result["error_message"] = f"Certificate verification failed: {e.verify_message} (use -k / --insecure for self-signed)"
    except ssl.SSLError as e:
        result["status"] = "ERROR"
        result["error_message"] = f"TLS Handshake failed: {str(e)}"
    except Exception as e:
        result["status"] = "ERROR"
        result["error_message"] = f"Network/Audit error: {str(e)}"
    finally:
        if ssock:
            try:
                ssock.close()
            except Exception:
                pass
        result["response_time_ms"] = round((time.time() - start_time) * 1000, 2)

    return result


def audit_all_targets(
    targets: List[str],
    warning_days: int = 30,
    critical_days: int = 7,
    timeout: float = 5.0,
    concurrency: int = 10,
    insecure: bool = False,
    ca_file: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Runs audits concurrently across all supplied targets using ThreadPoolExecutor."""
    results: List[Dict[str, Any]] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        future_to_target = {
            executor.submit(
                audit_endpoint,
                target=t,
                warning_days=warning_days,
                critical_days=critical_days,
                timeout=timeout,
                insecure=insecure,
                ca_file=ca_file,
            ): t
            for t in targets
        }

        for future in concurrent.futures.as_completed(future_to_target):
            try:
                data = future.result()
                results.append(data)
            except Exception as exc:
                t = future_to_target[future]
                results.append({
                    "target": t,
                    "host": t,
                    "port": 443,
                    "sni": t,
                    "status": "ERROR",
                    "days_remaining": None,
                    "error_message": f"Execution exception: {str(exc)}",
                    "response_time_ms": 0.0,
                })

    # Sort results alphabetically by target
    results.sort(key=lambda x: (x.get("target") or ""))
    return results


def format_status_badge(status: str) -> str:
    """Returns a colorized status badge for CLI table output."""
    if status == "OK":
        return f"{COLOR_GREEN}[  OK   ]{COLOR_RESET}"
    elif status == "WARNING":
        return f"{COLOR_YELLOW}[ WARN  ]{COLOR_RESET}"
    elif status == "CRITICAL":
        return f"{COLOR_RED}[ CRIT  ]{COLOR_RESET}"
    elif status == "EXPIRED":
        return f"{COLOR_BOLD_RED}[EXPIRED]{COLOR_RESET}"
    elif status == "ERROR":
        return f"{COLOR_MAGENTA}[ ERROR ]{COLOR_RESET}"
    else:
        return f"{COLOR_DIM}[ {status} ]{COLOR_RESET}"


def print_cli_table(results: List[Dict[str, Any]], warning_days: int, critical_days: int, total_duration_s: float):
    """Renders a structured, colorized terminal table."""
    print(f"\n{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_WHITE}                               SSL/TLS CERTIFICATE EXPIRY AUDIT REPORT                                  {COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}========================================================================================================{COLOR_RESET}")
    print(f"Audit Time : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"Thresholds : {COLOR_YELLOW}Warning <= {warning_days} days{COLOR_RESET} | {COLOR_RED}Critical <= {critical_days} days{COLOR_RESET}\n")

    header_fmt = "{:<9}  {:<26}  {:<20}  {:<19}  {:<10}  {:<14}"
    print(COLOR_BOLD + header_fmt.format("STATUS", "TARGET ENDPOINT", "ISSUER", "VALID UNTIL (UTC)", "DAYS LEFT", "PROTOCOL") + COLOR_RESET)
    print(COLOR_DIM + "-" * 104 + COLOR_RESET)

    total_count = len(results)
    ok_count = sum(1 for r in results if r["status"] == "OK")
    warn_count = sum(1 for r in results if r["status"] == "WARNING")
    crit_count = sum(1 for r in results if r["status"] == "CRITICAL")
    exp_count = sum(1 for r in results if r["status"] == "EXPIRED")
    err_count = sum(1 for r in results if r["status"] == "ERROR")

    for r in results:
        badge = format_status_badge(r["status"])
        target_display = f"{r['host']}:{r['port']}"
        if len(target_display) > 26:
            target_display = target_display[:23] + "..."

        if r["status"] == "ERROR":
            err_msg = r["error_message"] or "Unknown connection failure"
            if len(err_msg) > 65:
                err_msg = err_msg[:62] + "..."
            print(f"{badge}  {target_display:<26}  {COLOR_RED}{err_msg}{COLOR_RESET}")
            continue

        issuer = r["issuer_org"] or r["issuer_cn"] or "Unknown"
        if len(issuer) > 20:
            issuer = issuer[:17] + "..."

        valid_until_str = r["valid_until"][:10] if r["valid_until"] else "N/A"
        days_str = f"{r['days_remaining']} d" if r["days_remaining"] is not None else "N/A"
        
        # Color days left
        if r["status"] == "OK":
            days_formatted = f"{COLOR_GREEN}{days_str:<10}{COLOR_RESET}"
        elif r["status"] == "WARNING":
            days_formatted = f"{COLOR_YELLOW}{days_str:<10}{COLOR_RESET}"
        elif r["status"] in ("CRITICAL", "EXPIRED"):
            days_formatted = f"{COLOR_BOLD_RED}{days_str:<10}{COLOR_RESET}"
        else:
            days_formatted = f"{days_str:<10}"

        proto_info = f"{r['tls_version'] or 'TLS'}"
        print(f"{badge}  {target_display:<26}  {issuer:<20}  {valid_until_str:<19}  {days_formatted}  {proto_info:<14}")

    print(COLOR_DIM + "-" * 104 + COLOR_RESET)
    print(f"\n{COLOR_BOLD}SUMMARY STATISTICS:{COLOR_RESET}")
    print(f"  Total Audited : {COLOR_BOLD}{total_count}{COLOR_RESET}")
    print(f"  {COLOR_GREEN}✔ Healthy (OK){COLOR_RESET}   : {ok_count}")
    print(f"  {COLOR_YELLOW}▲ Expiring Soon{COLOR_RESET} : {warn_count}")
    print(f"  {COLOR_RED}✖ Critical/Exp{COLOR_RESET}  : {crit_count + exp_count} (Critical: {crit_count}, Expired: {exp_count})")
    print(f"  {COLOR_MAGENTA}⚠ Errors/Unreach{COLOR_RESET}: {err_count}")
    print(f"  Execution Time: {round(total_duration_s, 2)}s\n")


def generate_json_output(
    results: List[Dict[str, Any]],
    warning_days: int,
    critical_days: int,
    total_duration_s: float,
) -> str:
    """Generates structured, machine-parseable JSON."""
    ok_count = sum(1 for r in results if r["status"] == "OK")
    warn_count = sum(1 for r in results if r["status"] == "WARNING")
    crit_count = sum(1 for r in results if r["status"] == "CRITICAL")
    exp_count = sum(1 for r in results if r["status"] == "EXPIRED")
    err_count = sum(1 for r in results if r["status"] == "ERROR")

    overall_status = "HEALTHY"
    if exp_count > 0 or crit_count > 0:
        overall_status = "CRITICAL"
    elif warn_count > 0:
        overall_status = "WARNING"
    elif err_count > 0:
        overall_status = "DEGRADED"

    output = {
        "audit_metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "warning_threshold_days": warning_days,
            "critical_threshold_days": critical_days,
            "total_targets": len(results),
            "healthy_count": ok_count,
            "warning_count": warn_count,
            "critical_count": crit_count,
            "expired_count": exp_count,
            "error_count": err_count,
            "overall_status": overall_status,
            "execution_duration_seconds": round(total_duration_s, 3),
        },
        "results": results,
    }
    return json.dumps(output, indent=2)


def generate_prometheus_metrics(results: List[Dict[str, Any]]) -> str:
    """
    Generates Prometheus / OpenMetrics text exposition format.
    Metrics exported:
      - ssl_cert_days_until_expiry
      - ssl_cert_expiry_timestamp_seconds
      - ssl_cert_valid
      - ssl_cert_response_time_seconds
      - ssl_audit_targets_total
      - ssl_audit_targets_failed
    """
    lines = [
        "# HELP ssl_cert_days_until_expiry Number of days remaining before SSL/TLS certificate expires",
        "# TYPE ssl_cert_days_until_expiry gauge",
    ]

    for r in results:
        host = r["host"]
        port = r["port"]
        target = r["target"]
        issuer = (r["issuer_org"] or r["issuer_cn"] or "unknown").replace('"', '\\"')
        cn = (r["subject_cn"] or host).replace('"', '\\"')
        status = r["status"]

        if r["days_remaining"] is not None:
            days = r["days_remaining"]
            lines.append(
                f'ssl_cert_days_until_expiry{{target="{target}",host="{host}",port="{port}",cn="{cn}",issuer="{issuer}",status="{status}"}} {days}'
            )

    lines.append("")
    lines.append("# HELP ssl_cert_expiry_timestamp_seconds Unix timestamp when the certificate expires")
    lines.append("# TYPE ssl_cert_expiry_timestamp_seconds gauge")

    for r in results:
        if r["valid_until"]:
            dt = parse_asn1_date(r["valid_until"])
            if dt:
                epoch = int(dt.timestamp())
                lines.append(
                    f'ssl_cert_expiry_timestamp_seconds{{target="{r["target"]}",host="{r["host"]}",port="{r["port"]}"}} {epoch}'
                )

    lines.append("")
    lines.append("# HELP ssl_cert_valid Binary flag indicating whether the certificate is valid and unexpired (1=valid, 0=invalid/expired/error)")
    lines.append("# TYPE ssl_cert_valid gauge")

    for r in results:
        val = 1 if r["status"] in ("OK", "WARNING") else 0
        lines.append(f'ssl_cert_valid{{target="{r["target"]}",host="{r["host"]}",port="{r["port"]}"}} {val}')

    lines.append("")
    lines.append("# HELP ssl_cert_response_time_seconds Latency of the TLS handshake in seconds")
    lines.append("# TYPE ssl_cert_response_time_seconds gauge")
    for r in results:
        sec = round(r["response_time_ms"] / 1000.0, 4)
        lines.append(f'ssl_cert_response_time_seconds{{target="{r["target"]}",host="{r["host"]}",port="{r["port"]}"}} {sec}')

    lines.append("")
    lines.append("# HELP ssl_audit_targets_total Total number of endpoints scanned in this audit batch")
    lines.append("# TYPE ssl_audit_targets_total gauge")
    lines.append(f"ssl_audit_targets_total {len(results)}")

    failed_count = sum(1 for r in results if r["status"] in ("CRITICAL", "EXPIRED", "ERROR"))
    lines.append("# HELP ssl_audit_targets_failed Total number of audited targets in critical, expired, or error state")
    lines.append("# TYPE ssl_audit_targets_failed gauge")
    lines.append(f"ssl_audit_targets_failed {failed_count}")

    return "\n".join(lines) + "\n"


def send_webhook_alert(webhook_url: str, results: List[Dict[str, Any]], warning_days: int, critical_days: int) -> bool:
    """Sends a notification payload to an HTTP webhook (e.g. Slack / Discord / Webhook)."""
    degraded = [r for r in results if r["status"] in ("WARNING", "CRITICAL", "EXPIRED", "ERROR")]
    if not degraded:
        return True

    payload = {
        "text": f"🚨 *SSL/TLS Certificate Auditor Alert*: {len(degraded)} endpoints require attention!",
        "summary": {
            "total_scanned": len(results),
            "degraded_count": len(degraded),
            "warning_threshold": warning_days,
            "critical_threshold": critical_days,
        },
        "issues": [
            {
                "target": r["target"],
                "status": r["status"],
                "days_remaining": r["days_remaining"],
                "valid_until": r["valid_until"],
                "error": r["error_message"],
            }
            for r in degraded
        ],
    }

    try:
        req = urllib.request.Request(
            webhook_url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status in (200, 201, 204)
    except Exception as e:
        print(f"{COLOR_RED}[WARN] Failed to deliver webhook alert:{COLOR_RESET} {e}", file=sys.stderr)
        return False


def load_targets_from_file(file_path: str) -> List[str]:
    """Reads target lines from file, ignoring empty lines and comments."""
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
        description="SSL/TLS Certificate Expiry Auditor - Production-grade CLI scanner for certificate monitoring and SRE observability.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "-t", "--target",
        action="append",
        dest="targets",
        help="Target endpoint to audit (e.g. 'google.com', 'localhost:8443', '127.0.0.1:8443@valid.local'). Can be specified multiple times.",
    )
    parser.add_argument(
        "-f", "--file",
        dest="target_file",
        help="Path to file containing newline-delimited targets.",
    )
    parser.add_argument(
        "-w", "--warning-days",
        type=int,
        default=30,
        help="Warning threshold in days remaining before expiration (default: 30).",
    )
    parser.add_argument(
        "-c", "--critical-days",
        type=int,
        default=7,
        help="Critical threshold in days remaining before expiration (default: 7).",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="Socket and TLS handshake timeout in seconds (default: 5.0).",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=10,
        help="Maximum concurrent connection threads (default: 10).",
    )
    parser.add_argument(
        "-k", "--insecure",
        action="store_true",
        help="Disable CA certificate verification (audits self-signed/mock certificates without failing trust check).",
    )
    parser.add_argument(
        "--ca-file",
        dest="ca_file",
        help="Path to custom Certificate Authority (CA) bundle file.",
    )
    parser.add_argument(
        "-j", "--json",
        action="store_true",
        dest="json_output",
        help="Output results in machine-parseable JSON format.",
    )
    parser.add_argument(
        "-p", "--prometheus",
        action="store_true",
        dest="prom_output",
        help="Output results in Prometheus / OpenMetrics text exposition format.",
    )
    parser.add_argument(
        "-o", "--output",
        dest="output_file",
        help="Write output report directly to a specified destination file.",
    )
    parser.add_argument(
        "--webhook-url",
        dest="webhook_url",
        help="Optional HTTP Webhook URL to receive alert JSON if any certificate is warning/critical/expired.",
    )
    parser.add_argument(
        "--no-fail",
        action="store_true",
        help="Always return exit code 0 even if certificates are expiring or expired.",
    )

    args = parser.parse_args()

    # Collect all targets
    all_targets: List[str] = []
    if args.targets:
        all_targets.extend(args.targets)

    if args.target_file:
        try:
            file_targets = load_targets_from_file(args.target_file)
            all_targets.extend(file_targets)
        except Exception as e:
            print(f"{COLOR_RED}Error loading targets file:{COLOR_RESET} {e}", file=sys.stderr)
            return 3

    if not all_targets:
        parser.print_help(sys.stderr)
        print(f"\n{COLOR_RED}Error: No targets specified. Pass at least one --target or a --file.{COLOR_RESET}", file=sys.stderr)
        return 3

    # Remove duplicates preserving order
    seen = set()
    deduped_targets = []
    for t in all_targets:
        if t not in seen:
            seen.add(t)
            deduped_targets.append(t)

    start_audit_time = time.time()
    results = audit_all_targets(
        targets=deduped_targets,
        warning_days=args.warning_days,
        critical_days=args.critical_days,
        timeout=args.timeout,
        concurrency=args.concurrency,
        insecure=args.insecure,
        ca_file=args.ca_file,
    )
    total_duration = time.time() - start_audit_time

    # Generate Output Format
    if args.json_output:
        rendered_output = generate_json_output(results, args.warning_days, args.critical_days, total_duration)
        if args.output_file:
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(rendered_output + "\n")
        else:
            print(rendered_output)
    elif args.prom_output:
        rendered_output = generate_prometheus_metrics(results)
        if args.output_file:
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(rendered_output)
        else:
            print(rendered_output, end="")
    else:
        if args.output_file:
            json_text = generate_json_output(results, args.warning_days, args.critical_days, total_duration)
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(json_text + "\n")
        print_cli_table(results, args.warning_days, args.critical_days, total_duration)

    # Webhook Alerting
    if args.webhook_url:
        send_webhook_alert(args.webhook_url, results, args.warning_days, args.critical_days)

    if args.no_fail:
        return 0

    # Calculate Exit Code:
    # 0 = All OK
    # 1 = Warning (at least one expiring soon)
    # 2 = Critical / Expired (at least one expired or critical)
    # 3 = Error (at least one connection/DNS/audit error)
    has_expired = any(r["status"] in ("CRITICAL", "EXPIRED") for r in results)
    has_warning = any(r["status"] == "WARNING" for r in results)
    has_error = any(r["status"] == "ERROR" for r in results)

    if has_expired:
        return 2
    if has_warning:
        return 1
    if has_error:
        return 3

    return 0


if __name__ == "__main__":
    sys.exit(main())
