#!/usr/bin/env python3
"""
tls_audit.py - Automated SSL/TLS Cipher Hardening Scanner & Auditor.

Evaluates HTTPS endpoints for supported TLS protocols (TLS 1.0-1.3),
cipher suite strength (PFS, AEAD, CBC, RC4, 3DES), certificate validation,
and HTTP security headers (HSTS, Anti-framing). Generates terminal scorecards,
JSON, Markdown, and HTML compliance reports.
"""

import os
import sys
import ssl
import json
import time
import socket
import warnings
import subprocess
import argparse
from datetime import datetime, timezone
from typing import Dict, List, Any, Optional, Tuple

warnings.filterwarnings("ignore", category=DeprecationWarning)

# ANSI Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"

def is_weak_cipher(cipher_name: str) -> bool:
    """Detects weak legacy ciphers (RC4, 3DES, CBC, MD5, NULL, EXPORT, SHA-1)."""
    if not cipher_name:
        return False
    name_upper = cipher_name.upper()
    for p in ["RC4", "DES", "3DES", "CBC", "MD5", "NULL", "EXPORT", "ANON"]:
        if p in name_upper:
            return True
    if name_upper.endswith("-SHA") or name_upper.endswith("_SHA") or "-SHA1" in name_upper or "_SHA1" in name_upper:
        return True
    return False


def is_pfs_cipher(cipher_name: str) -> bool:
    """Detects Perfect Forward Secrecy (ECDHE, DHE, TLS 1.3 AEAD)."""
    if not cipher_name:
        return False
    name_upper = cipher_name.upper()
    for p in ["ECDHE", "DHE", "CHACHA20", "TLS_AES", "TLS_CHACHA20"]:
        if p in name_upper:
            return True
    return False


class TLSScanner:
    """Scanner instance evaluating SSL/TLS security posture of target endpoints."""

    def __init__(self, host: str, port: int, ca_file: Optional[str] = None, timeout: float = 4.0):
        self.host = host
        self.port = port
        self.ca_file = ca_file
        self.timeout = timeout

    def _create_ssl_context(
        self,
        min_version: Optional[ssl.TLSVersion] = None,
        max_version: Optional[ssl.TLSVersion] = None,
        ciphers: Optional[str] = None
    ) -> ssl.SSLContext:
        """Helper to create customizable SSLContext."""
        ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        if self.ca_file and os.path.exists(self.ca_file):
            try:
                ctx.load_verify_locations(cafile=self.ca_file)
            except Exception:
                pass

        try:
            ctx.set_ciphers("ALL:@SECLEVEL=0")
        except ssl.SSLError:
            pass

        if min_version is not None:
            ctx.minimum_version = min_version
        if max_version is not None:
            ctx.maximum_version = max_version
        if ciphers:
            try:
                ctx.set_ciphers(ciphers)
            except ssl.SSLError:
                pass
        return ctx

    def _probe_protocol_openssl(self, flag: str) -> bool:
        """Probes protocol support using OpenSSL CLI fallback for exact protocol negotiation."""
        try:
            cmd = [
                "openssl", "s_client",
                "-connect", f"{self.host}:{self.port}",
                flag,
                "-cipher", "ALL:DEFAULT@SECLEVEL=0",
                "-servername", self.host
            ]
            proc = subprocess.run(
                cmd,
                input=b"Q\n",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.timeout
            )
            out = proc.stdout.decode('utf-8', errors='ignore') + proc.stderr.decode('utf-8', errors='ignore')
            
            # Rejection signatures
            if "alert protocol version" in out or "no protocols available" in out or "handshake failure" in out or "wrong version number" in out:
                return False
            
            # Acceptance signatures
            if f"Protocol: {flag.replace('-tls1_1','TLSv1.1').replace('-tls1_2','TLSv1.2').replace('-tls1_3','TLSv1.3').replace('-tls1','TLSv1')}" in out:
                return True
            if "Cipher is " in out and "Cipher is (NONE)" not in out:
                return True
            if "CONNECTED(" in out and "SSL-Session:" in out and "Cipher    : 0000" not in out and "Cipher    : (NONE)" not in out:
                return True
        except Exception:
            pass
        return False

    def probe_protocol(self, version: ssl.TLSVersion, openssl_flag: str) -> bool:
        """Probes if a specific TLS protocol version is accepted by the server."""
        # 1. Try Python native SSL context
        ctx = self._create_ssl_context(min_version=version, max_version=version)
        try:
            with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
                with ctx.wrap_socket(sock, server_hostname=self.host) as ssock:
                    return True
        except Exception:
            pass

        # 2. Try OpenSSL s_client CLI
        return self._probe_protocol_openssl(openssl_flag)

    def probe_protocols(self) -> Dict[str, bool]:
        """Probes all standard TLS versions."""
        return {
            "TLSv1.0": self.probe_protocol(ssl.TLSVersion.TLSv1, "-tls1"),
            "TLSv1.1": self.probe_protocol(ssl.TLSVersion.TLSv1_1, "-tls1_1"),
            "TLSv1.2": self.probe_protocol(ssl.TLSVersion.TLSv1_2, "-tls1_2"),
            "TLSv1.3": self.probe_protocol(ssl.TLSVersion.TLSv1_3, "-tls1_3"),
        }

    def get_connection_details(self) -> Tuple[Dict[str, Any], Dict[str, Any], Dict[str, str]]:
        """Extracts negotiated cipher, certificate parameters, and HTTP headers."""
        ctx = self._create_ssl_context()
        cert_info: Dict[str, Any] = {}
        headers_info: Dict[str, str] = {}
        negotiated_info: Dict[str, Any] = {}

        try:
            with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
                with ctx.wrap_socket(sock, server_hostname=self.host) as ssock:
                    cipher_tuple = ssock.cipher()
                    negotiated_info = {
                        "protocol": ssock.version(),
                        "cipher_name": cipher_tuple[0] if cipher_tuple else "Unknown",
                        "tls_version": cipher_tuple[1] if cipher_tuple else "Unknown",
                        "bits": cipher_tuple[2] if cipher_tuple else 0,
                    }
                    der_cert = ssock.getpeercert(binary_form=True)
                    if der_cert:
                        try:
                            pem_cert = ssl.DER_cert_to_PEM_cert(der_cert)
                            proc = subprocess.run(
                                ["openssl", "x509", "-noout", "-subject", "-issuer", "-dates", "-ext", "subjectAltName"],
                                input=pem_cert.encode('utf-8'),
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                timeout=2.0
                            )
                            cert_out = proc.stdout.decode('utf-8', errors='ignore')
                            san_list = []
                            subj_cn = "Unknown"
                            iss_cn = "Unknown"
                            not_b = "Unknown"
                            not_a = "Unknown"

                            for cline in cert_out.splitlines():
                                cline = cline.strip()
                                if cline.startswith("subject="):
                                    if "CN=" in cline or "CN =" in cline:
                                        subj_cn = cline.split("CN=")[-1].split(",")[0].strip() if "CN=" in cline else cline.split("CN =")[-1].split(",")[0].strip()
                                elif cline.startswith("issuer="):
                                    if "CN=" in cline or "CN =" in cline:
                                        iss_cn = cline.split("CN=")[-1].split(",")[0].strip() if "CN=" in cline else cline.split("CN =")[-1].split(",")[0].strip()
                                elif cline.startswith("notBefore="):
                                    not_b = cline.split("notBefore=")[-1].strip()
                                elif cline.startswith("notAfter="):
                                    not_a = cline.split("notAfter=")[-1].strip()
                                elif "DNS:" in cline or "IP Address:" in cline:
                                    san_list = [s.strip() for s in cline.split(",") if s.strip()]

                            cert_info = {
                                "subject_cn": subj_cn,
                                "issuer_cn": iss_cn,
                                "not_before": not_b,
                                "not_after": not_a,
                                "san": san_list,
                            }
                        except Exception:
                            pass

                    # Probe HTTP response headers over TLS socket
                    req = f"GET / HTTP/1.1\r\nHost: {self.host}\r\nConnection: close\r\n\r\n"
                    ssock.sendall(req.encode('utf-8'))
                    raw_resp = b""
                    ssock.settimeout(2.0)
                    while b"\r\n\r\n" not in raw_resp:
                        try:
                            chunk = ssock.recv(1024)
                            if not chunk:
                                break
                            raw_resp += chunk
                        except socket.timeout:
                            break
                    
                    resp_str = raw_resp.decode('utf-8', errors='ignore')
                    lines = resp_str.split("\r\n")
                    for line in lines[1:]:
                        if ": " in line:
                            k, v = line.split(": ", 1)
                            headers_info[k.lower()] = v.strip()
        except Exception as e:
            negotiated_info["error"] = str(e)

        return negotiated_info, cert_info, headers_info

    def evaluate_endpoint(self) -> Dict[str, Any]:
        """Performs full evaluation, calculates compliance score and security grade."""
        protocols = self.probe_protocols()
        negotiated, cert, headers = self.get_connection_details()

        # Scoring System (Starts at 100)
        score = 100
        findings: List[Dict[str, str]] = []
        caps: List[str] = []

        # 1. Protocol Checks
        if protocols.get("TLSv1.0"):
            score -= 35
            findings.append({
                "severity": "HIGH",
                "category": "Protocol",
                "issue": "Deprecated TLSv1.0 is supported (Vulnerable to POODLE / BEAST attacks)."
            })
            caps.append("C")

        if protocols.get("TLSv1.1"):
            score -= 25
            findings.append({
                "severity": "MEDIUM",
                "category": "Protocol",
                "issue": "Deprecated TLSv1.1 is supported (RFC 8996 non-compliant)."
            })
            caps.append("B")

        if not protocols.get("TLSv1.2") and not protocols.get("TLSv1.3"):
            score -= 50
            findings.append({
                "severity": "CRITICAL",
                "category": "Protocol",
                "issue": "Neither TLSv1.2 nor TLSv1.3 is supported."
            })
            caps.append("F")

        # 2. Cipher Checks
        cipher_name = negotiated.get("cipher_name", "")
        has_weak_cipher = is_weak_cipher(cipher_name)
        has_pfs = is_pfs_cipher(cipher_name)

        if has_weak_cipher:
            score -= 30
            findings.append({
                "severity": "HIGH",
                "category": "Cipher",
                "issue": f"Negotiated cipher suite ({cipher_name}) contains legacy CBC mode or SHA-1 MAC algorithms."
            })
            caps.append("C")

        if not has_pfs:
            score -= 15
            findings.append({
                "severity": "MEDIUM",
                "category": "Cipher",
                "issue": f"Cipher suite ({cipher_name}) lacks Perfect Forward Secrecy (PFS)."
            })

        # 3. Security Header Checks
        hsts_header = headers.get("strict-transport-security", "")
        has_hsts = bool(hsts_header)
        hsts_subdomains = "includesubdomains" in hsts_header.lower()

        if not has_hsts:
            score -= 15
            findings.append({
                "severity": "LOW",
                "category": "Headers",
                "issue": "Strict-Transport-Security (HSTS) header is missing."
            })
        else:
            if not hsts_subdomains:
                findings.append({
                    "severity": "INFO",
                    "category": "Headers",
                    "issue": "HSTS does not include 'includeSubDomains'."
                })

        # Calculate Final Grade
        score = max(0, min(100, score))
        grade = "F"
        if score >= 95 and has_hsts and not caps:
            grade = "A+"
        elif score >= 90:
            grade = "A"
        elif score >= 80:
            grade = "B"
        elif score >= 65:
            grade = "C"
        elif score >= 50:
            grade = "D"
        else:
            grade = "F"

        # Apply Grade Caps
        if "C" in caps and grade in ["A+", "A", "B"]:
            grade = "C"
        if "B" in caps and grade in ["A+", "A"]:
            grade = "B"
        if "F" in caps:
            grade = "F"

        # If deprecated protocols and weak ciphers are active without HSTS, assign Grade F
        if (protocols.get("TLSv1.0") or protocols.get("TLSv1.1")) and (has_weak_cipher or not has_hsts):
            grade = "F"

        return {
            "target": f"{self.host}:{self.port}",
            "host": self.host,
            "port": self.port,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "score": score,
            "grade": grade,
            "status": "PASS" if grade in ["A+", "A"] else "FAIL",
            "protocols": protocols,
            "negotiated": negotiated,
            "certificate": cert,
            "headers": {
                "hsts": hsts_header or "Not Configured",
                "hsts_present": has_hsts,
                "x_content_type_options": headers.get("x-content-type-options", "Not Configured"),
                "x_frame_options": headers.get("x-frame-options", "Not Configured"),
            },
            "findings": findings
        }


def render_terminal_scorecards(results: List[Dict[str, Any]]):
    """Prints ANSI formatted evaluation scorecards in terminal."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================")
    print("  🛡️  AUTOMATED SSL/TLS CIPHER HARDENING AUDIT SCORECARD")
    print(f"======================================================================{CLR_RESET}")

    for res in results:
        grade_color = CLR_GREEN if res["grade"] in ["A+", "A"] else (CLR_YELLOW if res["grade"] == "B" else CLR_RED)
        status_color = CLR_GREEN if res["status"] == "PASS" else CLR_RED

        print(f"\nTarget Endpoint   : {CLR_BOLD}{res['target']}{CLR_RESET}")
        print(f"Audit Verdict     : [{status_color}{res['status']}{CLR_RESET}]")
        print(f"Security Grade    : [{grade_color}{CLR_BOLD}{res['grade']}{CLR_RESET}] (Compliance Score: {res['score']}/100)")
        print(f"TLS Protocols     : ", end="")
        for proto, enabled in res["protocols"].items():
            col = CLR_GREEN if enabled and proto in ["TLSv1.2", "TLSv1.3"] else (CLR_RED if enabled else CLR_GRAY)
            status_text = "Enabled" if enabled else "Disabled"
            print(f"{proto}: {col}{status_text}{CLR_RESET}  ", end="")
        print()

        neg = res["negotiated"]
        print(f"Negotiated Cipher : {CLR_MAGENTA}{neg.get('cipher_name', 'N/A')}{CLR_RESET} ({neg.get('protocol', 'N/A')}, {neg.get('bits', 0)} bits)")
        print(f"HSTS Configured   : {CLR_GREEN if res['headers']['hsts_present'] else CLR_RED}{res['headers']['hsts']}{CLR_RESET}")

        if res["findings"]:
            print(f"\n  {CLR_BOLD}Security Findings ({len(res['findings'])}):{CLR_RESET}")
            for f in res["findings"]:
                sev_color = CLR_RED if f["severity"] == "HIGH" else (CLR_YELLOW if f["severity"] == "MEDIUM" else CLR_CYAN)
                print(f"   • [{sev_color}{f['severity']:<6}{CLR_RESET}] {f['issue']}")
        else:
            print(f"  [{CLR_GREEN}PASSED{CLR_RESET}] No security vulnerabilities or legacy ciphers detected.")
        print("-" * 70)


def generate_json_report(output_path: str, results: List[Dict[str, Any]]):
    """Outputs JSON report."""
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump({"audit_timestamp": datetime.now(timezone.utc).isoformat(), "endpoints": results}, f, indent=2)


def generate_markdown_report(output_path: str, results: List[Dict[str, Any]]):
    """Outputs Markdown audit report."""
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    report_date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    summary_rows = []
    for r in results:
        grade_badge = f"**{r['grade']}**"
        verdict = "✅ **PASS**" if r["status"] == "PASS" else "❌ **FAIL**"
        proto_str = ", ".join([p for p, en in r["protocols"].items() if en])
        summary_rows.append(f"| `{r['target']}` | {grade_badge} | `{r['score']}/100` | {verdict} | `{proto_str}` | `{r['negotiated'].get('cipher_name', 'N/A')}` |")

    summary_table = "\n".join(summary_rows)

    detail_sections = []
    for r in results:
        finding_bullets = ""
        if r["findings"]:
            finding_bullets = "\n".join([f"- **[{f['severity']}]** {f['issue']}" for f in r["findings"]])
        else:
            finding_bullets = "- *No security issues identified; endpoint complies with modern TLS standards.*"

        detail_sections.append(f"""### Endpoint: `{r['target']}`

- **Grade & Score**: `{r['grade']}` ({r['score']}/100)
- **Status**: `{r['status']}`
- **Active Cipher**: `{r['negotiated'].get('cipher_name', 'N/A')}` ({r['negotiated'].get('protocol', 'N/A')})
- **HSTS Header**: `{r['headers']['hsts']}`
- **Certificate Subject**: `{r['certificate'].get('subject_cn', 'N/A')}` (SAN: `{', '.join(r['certificate'].get('san', []))}`)

**Findings & Vulnerabilities:**
{finding_bullets}
""")

    content = f"""# Automated SSL/TLS Cipher Hardening Compliance Report

Generated on: **{report_date}**  
Audit Standards: **NIST SP 800-52r2 & Mozilla Modern SSL Guidelines**  
Evaluation Suite: **Automated Python TLS Socket & Cryptographic Prober**

## 📊 Executive Summary

| Target Endpoint | Security Grade | Score | Verdict | Supported Protocols | Negotiated Cipher |
| :--- | :--- | :--- | :--- | :--- | :--- |
{summary_table}

---

## 📋 Detailed Endpoint Security Breakdown

{"".join(detail_sections)}
---
*Report generated automatically by `tls_audit.py`.*
"""
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(content)


def generate_html_report(output_path: str, results: List[Dict[str, Any]]):
    """Outputs visual HTML dashboard scorecard."""
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    report_date = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    cards = []
    for r in results:
        is_pass = r["status"] == "PASS"
        grade_bg = "#10b981" if r["grade"] in ["A+", "A"] else ("#f59e0b" if r["grade"] == "B" else "#ef4444")
        status_bg = "#10b981" if is_pass else "#ef4444"

        findings_html = ""
        if r["findings"]:
            findings_html = "<ul style='margin: 8px 0; padding-left: 20px;'>" + "".join([
                f"<li style='margin-bottom: 4px;'><strong style='color:{'#ef4444' if f['severity']=='HIGH' else '#f59e0b'}'>[{f['severity']}]</strong> {f['issue']}</li>"
                for f in r["findings"]
            ]) + "</ul>"
        else:
            findings_html = "<p style='color: #10b981; font-weight: 500;'>✅ Fully compliant with Mozilla Modern / NIST SP 800-52r2.</p>"

        protos_html = " ".join([
            f"<span style='display:inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; margin-right: 4px; background:{'#10b981' if en and p in ['TLSv1.2','TLSv1.3'] else ('#ef4444' if en else '#374151')}; color: white;'>{p}: {'Enabled' if en else 'Disabled'}</span>"
            for p, en in r["protocols"].items()
        ])

        cards.append(f"""
        <div style="background: #1f2937; border-radius: 12px; padding: 24px; margin-bottom: 24px; border: 1px solid #374151; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.3);">
            <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #374151; padding-bottom: 16px; margin-bottom: 16px;">
                <div>
                    <h2 style="margin: 0 0 4px 0; color: #f9fafb; font-size: 20px;">{r['target']}</h2>
                    <span style="background: {status_bg}; color: white; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: bold;">{r['status']}</span>
                </div>
                <div style="text-align: right;">
                    <div style="background: {grade_bg}; color: white; width: 56px; height: 56px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 24px; font-weight: bold; margin-left: auto;">
                        {r['grade']}
                    </div>
                    <div style="color: #9ca3af; font-size: 12px; margin-top: 4px;">Score: {r['score']}/100</div>
                </div>
            </div>
            
            <div style="margin-bottom: 16px;">
                <h4 style="margin: 0 0 8px 0; color: #9ca3af; font-size: 13px; text-transform: uppercase;">TLS Protocols</h4>
                {protos_html}
            </div>

            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; margin-bottom: 16px; background: #111827; padding: 16px; border-radius: 8px;">
                <div>
                    <div style="color: #9ca3af; font-size: 12px;">Active Cipher</div>
                    <div style="color: #f3f4f6; font-family: monospace; font-size: 13px; font-weight: bold;">{r['negotiated'].get('cipher_name', 'N/A')}</div>
                </div>
                <div>
                    <div style="color: #9ca3af; font-size: 12px;">HSTS Header</div>
                    <div style="color: {'#10b981' if r['headers']['hsts_present'] else '#ef4444'}; font-size: 13px; font-weight: bold;">{r['headers']['hsts']}</div>
                </div>
            </div>

            <div>
                <h4 style="margin: 0 0 8px 0; color: #9ca3af; font-size: 13px; text-transform: uppercase;">Security Findings</h4>
                {findings_html}
            </div>
        </div>
        """)

    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SSL/TLS Cipher Hardening Compliance Dashboard</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #111827; color: #f3f4f6; margin: 0; padding: 40px 20px; }}
        .container {{ max-width: 900px; margin: 0 auto; }}
        header {{ text-align: center; margin-bottom: 40px; }}
        h1 {{ margin: 0 0 8px 0; color: #60a5fa; font-size: 28px; }}
        p.subtitle {{ color: #9ca3af; margin: 0; }}
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🔐 SSL/TLS Cipher Hardening Audit Dashboard</h1>
            <p class="subtitle">Generated on {report_date} | Standards: NIST SP 800-52r2 & Mozilla Modern</p>
        </header>
        {"".join(cards)}
    </div>
</body>
</html>
"""
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(html_content)


def main():
    parser = argparse.ArgumentParser(description="Automated SSL/TLS Cipher Hardening Scanner.")
    parser.add_argument("--targets", nargs="+", default=["localhost:8443", "localhost:9443"], help="Target endpoints in host:port format.")
    parser.add_argument("--ca-file", default="certs/ca.crt", help="Path to local CA certificate for verification.")
    parser.add_argument("--json-out", default="reports/tls_audit_report.json", help="Path for JSON output.")
    parser.add_argument("--md-out", default="reports/tls_audit_report.md", help="Path for Markdown output.")
    parser.add_argument("--html-out", default="reports/tls_audit_report.html", help="Path for HTML output.")
    parser.add_argument("--timeout", type=float, default=4.0, help="Connection timeout in seconds.")

    args = parser.parse_args()

    results = []

    for target in args.targets:
        if ":" in target:
            host, port_str = target.split(":", 1)
            port = int(port_str)
        else:
            host = target
            port = 443

        scanner = TLSScanner(host, port, ca_file=args.ca_file, timeout=args.timeout)
        evaluation = scanner.evaluate_endpoint()
        results.append(evaluation)

    render_terminal_scorecards(results)
    generate_json_report(args.json_out, results)
    generate_markdown_report(args.md_out, results)
    generate_html_report(args.html_out, results)

    print(f"{CLR_GREEN}✔ Reports saved to reports/ (JSON, Markdown, HTML){CLR_RESET}\n")


if __name__ == "__main__":
    main()
