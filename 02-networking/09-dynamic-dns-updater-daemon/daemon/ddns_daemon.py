#!/usr/bin/env python3
"""
Dynamic DNS (DDNS) Updater Daemon
Resilient background service that detects WAN IP changes, manages local state cache
to eliminate redundant API calls, updates Cloudflare / Route53 DNS records,
and handles transient failures using exponential backoff with jitter.
"""

import ipaddress
import json
import os
import random
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

# Configuration from Environment Variables
CHECK_INTERVAL_SEC = float(os.environ.get("CHECK_INTERVAL", "3.0"))
API_BASE_URL = os.environ.get("API_BASE_URL", "http://mock-dns-server:8080").rstrip("/")
API_TOKEN = os.environ.get("API_TOKEN", "mock_cloudflare_bearer_token_secret")
ZONE_ID = os.environ.get("ZONE_ID", "zone_1234567890abcdef")
DOMAINS = [d.strip() for d in os.environ.get("DOMAINS", "home.example.com,vpn.example.com").split(",") if d.strip()]
IP_DISCOVERY_URLS = [
    u.strip() for u in os.environ.get(
        "IP_DISCOVERY_URLS",
        f"{API_BASE_URL}/ip,{API_BASE_URL}/json/ip"
    ).split(",") if u.strip()
]
CACHE_FILE = os.environ.get("CACHE_FILE", "/data/ddns_cache.json")
STATUS_PORT = int(os.environ.get("STATUS_PORT", "8000"))
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "4"))
INITIAL_BACKOFF_SEC = float(os.environ.get("INITIAL_BACKOFF_SEC", "1.0"))

# State tracking for SRE Observability
DAEMON_STATE = {
    "status": "STARTING",
    "last_discovered_ip": None,
    "last_synced_ip": None,
    "last_check_time": None,
    "last_update_time": None,
    "total_checks": 0,
    "total_ip_changes_detected": 0,
    "total_api_updates_sent": 0,
    "total_api_errors": 0,
    "redundant_calls_avoided": 0,
    "consecutive_errors": 0,
    "managed_domains": DOMAINS,
    "cached_records": {}
}

def log(msg, level="INFO"):
    t = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sys.stdout.write(f"[{t}] [{level}] [DDNS-Daemon] {msg}\n")
    sys.stdout.flush()

def load_cache():
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                log(f"Loaded persistent cache: last_ip={data.get('last_ip')} (updated: {data.get('updated_at')})")
                return data
        except Exception as e:
            log(f"Error reading cache file {CACHE_FILE}: {e}", level="WARN")
    return {"last_ip": None, "updated_at": None, "records": {}}

def save_cache(cache_data):
    os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
    try:
        tmp_file = f"{CACHE_FILE}.tmp"
        with open(tmp_file, "w", encoding="utf-8") as f:
            json.dump(cache_data, f, indent=2)
        os.replace(tmp_file, CACHE_FILE)
    except Exception as e:
        log(f"Failed to persist cache to {CACHE_FILE}: {e}", level="ERROR")

def is_valid_ipv4(ip_str):
    if not ip_str:
        return False
    ip_str = ip_str.strip()
    try:
        ipaddress.IPv4Address(ip_str)
        return True
    except ValueError:
        return False

def discover_public_ip():
    for url in IP_DISCOVERY_URLS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "DDNS-Daemon/1.0"})
            with urllib.request.urlopen(req, timeout=4) as resp:
                raw = resp.read().decode("utf-8").strip()
                # Check JSON payload
                if raw.startswith("{") and "ip" in raw:
                    parsed = json.loads(raw)
                    candidate = parsed.get("ip", "").strip()
                else:
                    candidate = raw

                # Extract IPv4
                match = re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", candidate)
                if match:
                    ip = match.group(0)
                    if is_valid_ipv4(ip):
                        return ip
        except Exception as e:
            log(f"IP discovery failed on endpoint {url}: {e}", level="WARN")
            continue
    return None

def fetch_zone_dns_records():
    url = f"{API_BASE_URL}/client/v4/zones/{ZONE_ID}/dns_records"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {API_TOKEN}",
        "Content-Type": "application/json",
        "User-Agent": "DDNS-Daemon/1.0"
    })
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("success"):
                return {r["name"]: r for r in data.get("result", [])}
            else:
                log(f"Cloudflare API returned error: {data.get('errors')}", level="ERROR")
    except Exception as e:
        log(f"Error fetching DNS records from {url}: {e}", level="ERROR")
    return {}

def update_dns_record_with_backoff(record, new_ip):
    record_id = record["id"]
    domain = record["name"]
    url = f"{API_BASE_URL}/client/v4/zones/{ZONE_ID}/dns_records/{record_id}"
    payload = {
        "type": "A",
        "name": domain,
        "content": new_ip,
        "ttl": 120,
        "proxied": record.get("proxied", False)
    }
    body_bytes = json.dumps(payload).encode("utf-8")

    backoff = INITIAL_BACKOFF_SEC
    for attempt in range(1, MAX_RETRIES + 1):
        DAEMON_STATE["total_api_updates_sent"] += 1
        try:
            req = urllib.request.Request(url, data=body_bytes, method="PUT", headers={
                "Authorization": f"Bearer {API_TOKEN}",
                "Content-Type": "application/json",
                "User-Agent": "DDNS-Daemon/1.0"
            })
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("success"):
                    log(f"✅ Successfully updated DNS record [{domain}] -> {new_ip} (Attempt {attempt})")
                    DAEMON_STATE["consecutive_errors"] = 0
                    return True
                else:
                    log(f"API update unsuccessful for [{domain}]: {data.get('errors')}", level="WARN")
        except urllib.error.HTTPError as e:
            DAEMON_STATE["total_api_errors"] += 1
            DAEMON_STATE["consecutive_errors"] += 1
            log(f"HTTP Error {e.code} updating [{domain}] (Attempt {attempt}/{MAX_RETRIES}): {e.reason}", level="WARN")
        except Exception as e:
            DAEMON_STATE["total_api_errors"] += 1
            DAEMON_STATE["consecutive_errors"] += 1
            log(f"Network error updating [{domain}] (Attempt {attempt}/{MAX_RETRIES}): {e}", level="WARN")

        if attempt < MAX_RETRIES:
            jitter = random.uniform(0.1, 0.5)
            sleep_time = backoff + jitter
            log(f"⏳ Retrying in {sleep_time:.2f}s (Exponential backoff)...")
            time.sleep(sleep_time)
            backoff *= 2

    log(f"❌ Exhausted all {MAX_RETRIES} retries updating [{domain}]", level="ERROR")
    return False

# ------------------------------------------------------------------------------
# Embedded Status HTTP Server for Observability & Health Probes
# ------------------------------------------------------------------------------
class StatusHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health", "/status"):
            payload = json.dumps(DAEMON_STATE, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Quiet logging for health probes

def start_status_server():
    server = HTTPServer(("0.0.0.0", STATUS_PORT), StatusHandler)
    server.serve_forever()

# ------------------------------------------------------------------------------
# Core Daemon Execution Loop
# ------------------------------------------------------------------------------
def run_daemon():
    log(f"🚀 Starting Dynamic DNS Updater Daemon")
    log(f"Target Domains       : {', '.join(DOMAINS)}")
    log(f"Poll Interval        : {CHECK_INTERVAL_SEC}s")
    log(f"Cache File           : {CACHE_FILE}")
    log(f"API Endpoint         : {API_BASE_URL}")

    # Start health status server in background thread
    t = threading.Thread(target=start_status_server, daemon=True)
    t.start()

    cache = load_cache()
    cached_ip = cache.get("last_ip")
    DAEMON_STATE["last_synced_ip"] = cached_ip
    DAEMON_STATE["status"] = "ACTIVE"

    while True:
        DAEMON_STATE["total_checks"] += 1
        DAEMON_STATE["last_check_time"] = datetime.now(timezone.utc).isoformat()

        discovered_ip = discover_public_ip()
        if not discovered_ip:
            log("Unable to discover WAN IP from any configured endpoint", level="WARN")
            time.sleep(CHECK_INTERVAL_SEC)
            continue

        DAEMON_STATE["last_discovered_ip"] = discovered_ip

        # ----------------------------------------------------------------------
        # IP Change Detection & Cache Evaluation
        # ----------------------------------------------------------------------
        if discovered_ip == cached_ip:
            DAEMON_STATE["redundant_calls_avoided"] += 1
            # Redundant call avoided - do not hammer Cloudflare / Route53 API
            time.sleep(CHECK_INTERVAL_SEC)
            continue

        # WAN IP has changed!
        DAEMON_STATE["total_ip_changes_detected"] += 1
        log(f"🚨 WAN IP Transition Detected: Old=[{cached_ip or 'NONE'}] -> New=[{discovered_ip}]")
        DAEMON_STATE["status"] = "SYNCING"

        dns_records = fetch_zone_dns_records()
        all_updated = True

        for domain in DOMAINS:
            if domain in dns_records:
                record = dns_records[domain]
                current_record_ip = record.get("content")
                if current_record_ip != discovered_ip:
                    log(f"Syncing DNS record [{domain}]: {current_record_ip} -> {discovered_ip}")
                    success = update_dns_record_with_backoff(record, discovered_ip)
                    if not success:
                        all_updated = False
                else:
                    log(f"Record [{domain}] already points to {discovered_ip} on DNS provider")
            else:
                log(f"Record [{domain}] not found in DNS zone {ZONE_ID}. Skipping.", level="WARN")
                all_updated = False

        if all_updated:
            cached_ip = discovered_ip
            DAEMON_STATE["last_synced_ip"] = cached_ip
            DAEMON_STATE["last_update_time"] = datetime.now(timezone.utc).isoformat()
            DAEMON_STATE["status"] = "ACTIVE"
            cache["last_ip"] = cached_ip
            cache["updated_at"] = DAEMON_STATE["last_update_time"]
            save_cache(cache)
            log(f"🎉 All records synced and local cache updated for IP {cached_ip}")
        else:
            DAEMON_STATE["status"] = "ERROR_RETRYING"

        time.sleep(CHECK_INTERVAL_SEC)

if __name__ == "__main__":
    run_daemon()
