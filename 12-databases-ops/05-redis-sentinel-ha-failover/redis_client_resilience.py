#!/usr/bin/env python3
"""
redis_client_resilience.py - Resilient Redis Sentinel Client & Failover Benchmark

Continuously streams transactional writes to the active Redis Master resolved dynamically
via Sentinel consensus using native RESP protocol sockets (zero external dependencies).
Measures failover detection latency (RTO), unacknowledged write losses (RPO),
and auto-reconnection upon Master crash and promotion.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone

# Optional tabulate support
try:
    from tabulate import tabulate
    HAS_TABULATE = True
except ImportError:
    HAS_TABULATE = False

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_CYAN = "\033[1;36m"
CLR_YELLOW = "\033[1;33m"
CLR_RED = "\033[1;31m"
CLR_GRAY = "\033[0;90m"

# Static mapping for container names to host ports
CONTAINER_TO_HOST_MAP = {
    "redis-master": 6379,
    "redis-replica-1": 6380,
    "redis-replica-2": 6381,
    "127.0.0.1": 6379,
    "localhost": 6379,
}


def resolve_container_to_host_endpoint(ip_or_host, original_port):
    """Translates container hostnames or internal Docker IPs into accessible localhost host ports."""
    clean_host = str(ip_or_host).strip().lstrip("/")
    
    if clean_host in ["localhost", "127.0.0.1"]:
        return "localhost", original_port, clean_host

    if clean_host in CONTAINER_TO_HOST_MAP:
        return "localhost", CONTAINER_TO_HOST_MAP[clean_host], clean_host

    # Query docker inspect to dynamically resolve internal container IP to container name
    try:
        res = subprocess.run(
            ["docker", "inspect", "--format", "{{.Name}}:{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
             "redis-master", "redis-replica-1", "redis-replica-2"],
            capture_output=True, text=True, timeout=2
        )
        if res.returncode == 0:
            for line in res.stdout.strip().split("\n"):
                if ":" in line:
                    cname, cip = line.strip().lstrip("/").split(":")
                    if cip == clean_host or cname == clean_host:
                        host_port = CONTAINER_TO_HOST_MAP.get(cname, original_port)
                        return "localhost", host_port, cname
    except Exception:
        pass

    return clean_host, original_port, clean_host


class RedisSocketClient:
    """Lightweight pure-Python client communicating via Redis Serialization Protocol (RESP)."""

    def __init__(self, host="localhost", port=6379, timeout=1.0):
        self.host = host
        self.port = int(port)
        self.timeout = timeout

    def execute_command(self, *args):
        """Sends RESP encoded command array and parses the response."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect((self.host, self.port))
            # Encode RESP Array
            payload = f"*{len(args)}\r\n"
            for arg in args:
                arg_str = str(arg)
                payload += f"${len(arg_str.encode('utf-8'))}\r\n{arg_str}\r\n"
            s.sendall(payload.encode("utf-8"))

            response = self._read_resp(s)
            return response
        finally:
            s.close()

    def _read_resp(self, sock):
        """Parses RESP protocol message from socket."""
        line = self._read_line(sock)
        if not line:
            return None

        prefix = line[0:1]
        content = line[1:]

        if prefix == "+":  # Simple string
            return content
        elif prefix == "-":  # Error string
            raise RuntimeError(f"Redis Error: {content}")
        elif prefix == ":":  # Integer
            return int(content)
        elif prefix == "$":  # Bulk string
            length = int(content)
            if length == -1:
                return None
            data = b""
            while len(data) < length:
                chunk = sock.recv(min(4096, length - len(data)))
                if not chunk:
                    break
                data += chunk
            sock.recv(2)  # Consume trailing \r\n
            return data.decode("utf-8", errors="replace")
        elif prefix == "*":  # Array
            count = int(content)
            if count == -1:
                return None
            items = []
            for _ in range(count):
                items.append(self._read_resp(sock))
            return items
        return content

    def _read_line(self, sock):
        """Reads characters until \r\n."""
        buf = []
        while True:
            char = sock.recv(1)
            if not char or char == b"\n":
                break
            if char != b"\r":
                buf.append(char)
        return b"".join(buf).decode("utf-8", errors="replace")


def discover_master_address(sentinel_hosts, master_name="mymaster"):
    """Queries Sentinel nodes to discover current active Master host and port."""
    for host, port in sentinel_hosts:
        try:
            client = RedisSocketClient(host, port, timeout=0.8)
            res = client.execute_command("SENTINEL", "get-master-addr-by-name", master_name)
            if isinstance(res, list) and len(res) >= 2:
                m_host = res[0]
                m_port = int(res[1])
                resolved_host, resolved_port, friendly_name = resolve_container_to_host_endpoint(m_host, m_port)
                return resolved_host, resolved_port, friendly_name
        except Exception:
            continue

    return None, None, None


def get_cluster_topology(sentinel_hosts, master_name="mymaster"):
    """Fetches full cluster topology: master, replicas, and sentinels."""
    master_host, master_port, raw_master_name = discover_master_address(sentinel_hosts, master_name)
    
    slaves_info = []
    sentinels_info = []

    for host, port in sentinel_hosts:
        try:
            client = RedisSocketClient(host, port, timeout=1.0)
            raw_slaves = client.execute_command("SENTINEL", "slaves", master_name) or []
            for s in raw_slaves:
                if isinstance(s, list):
                    s_dict = dict(zip(s[0::2], s[1::2]))
                    slaves_info.append(s_dict)
            
            raw_sentinels = client.execute_command("SENTINEL", "sentinels", master_name) or []
            for sent in raw_sentinels:
                if isinstance(sent, list):
                    sent_dict = dict(zip(sent[0::2], sent[1::2]))
                    sentinels_info.append(sent_dict)
            break
        except Exception:
            continue

    return {
        "master_name": master_name,
        "active_master": f"{master_host}:{master_port} ({raw_master_name})",
        "raw_master_host": raw_master_name,
        "master_port": master_port,
        "sentinels_count": len(sentinel_hosts),
        "replicas_count": len(slaves_info),
        "replicas": slaves_info,
        "other_sentinels": sentinels_info
    }


def execute_write_command(host, port, key, value):
    """Writes a key-value pair to the target Redis node."""
    client = RedisSocketClient(host, port, timeout=0.6)
    res = client.execute_command("SET", key, value)
    return res == "OK"


def run_resilience_stream(sentinel_hosts, master_name="mymaster", duration_sec=15, rate_hz=20, json_output=False):
    """
    Streams continuous writes to the active master while handling failovers dynamically.
    Tracks failover detection delay, recovery time (RTO), and total write continuity.
    """
    if not json_output:
        print(f"\n{CLR_CYAN}{CLR_BOLD}▶ Starting Resilient Redis Sentinel Stream Benchmark{CLR_RESET}")
        print(f"  Duration: {CLR_BOLD}{duration_sec}s{CLR_RESET} | Stream Rate: {CLR_BOLD}{rate_hz} writes/sec{CLR_RESET}\n")

    current_master_host, current_master_port, raw_name = discover_master_address(sentinel_hosts, master_name)
    if not current_master_host:
        raise RuntimeError("Failed to discover initial Redis Master via Sentinels.")

    if not json_output:
        print(f"  Initial Active Master : {CLR_GREEN}{raw_name} (localhost:{current_master_port}){CLR_RESET}")

    total_attempts = 0
    successful_writes = 0
    failed_writes = 0
    failover_events = []
    
    start_time = time.perf_counter()
    interval = 1.0 / rate_hz
    in_failover = False
    failover_start_time = None
    initial_master = raw_name

    while (time.perf_counter() - start_time) < duration_sec:
        loop_start = time.perf_counter()
        total_attempts += 1
        key = f"sentinel:heartbeat:{total_attempts}"
        val = f"payload_ts_{datetime.now(timezone.utc).isoformat()}"

        try:
            success = execute_write_command(current_master_host, current_master_port, key, val)
            if success:
                successful_writes += 1
                if in_failover:
                    # Failover completed!
                    rto_duration_ms = (time.perf_counter() - failover_start_time) * 1000.0
                    new_host, new_port, new_raw_name = discover_master_address(sentinel_hosts, master_name)
                    failover_events.append({
                        "event": "FAILOVER_COMPLETED",
                        "previous_master": initial_master,
                        "promoted_master": new_raw_name,
                        "promoted_port": new_port,
                        "rto_downtime_ms": round(rto_duration_ms, 2)
                    })
                    if not json_output:
                        print(f"\n{CLR_GREEN}{CLR_BOLD}✔ Failover Reconnection Succeeded!{CLR_RESET}")
                        print(f"  New Promoted Master : {CLR_BOLD}{new_raw_name} (Port {new_port}){CLR_RESET}")
                        print(f"  Failover Downtime (RTO): {CLR_BOLD}{rto_duration_ms:.2f} ms{CLR_RESET}\n")
                    in_failover = False
                elif not json_output and total_attempts % 20 == 0:
                    print(f"  [WRITING] {total_attempts} keys written to {raw_name}...", end="\r")
            else:
                raise RuntimeError("Write returned non-OK")
        except Exception:
            failed_writes += 1
            if not in_failover:
                in_failover = True
                failover_start_time = time.perf_counter()
                if not json_output:
                    print(f"\n{CLR_RED}{CLR_BOLD}🚨 Master Outage Detected! Initiating Sentinel Discovery...{CLR_RESET}")

            # Re-discover active master from Sentinels
            new_host, new_port, new_raw_name = discover_master_address(sentinel_hosts, master_name)
            if new_host and (new_raw_name != raw_name or new_port != current_master_port):
                current_master_host = new_host
                current_master_port = new_port
                raw_name = new_raw_name

        elapsed = time.perf_counter() - loop_start
        sleep_time = interval - elapsed
        if sleep_time > 0:
            time.sleep(sleep_time)

    total_test_duration = time.perf_counter() - start_time
    success_rate = (successful_writes / total_attempts) * 100.0 if total_attempts > 0 else 0.0

    report = {
        "total_duration_sec": round(total_test_duration, 2),
        "total_write_attempts": total_attempts,
        "successful_writes": successful_writes,
        "failed_writes_during_failover": failed_writes,
        "availability_pct": round(success_rate, 2),
        "initial_master": initial_master,
        "final_master": raw_name,
        "failover_events": failover_events
    }

    if not json_output:
        print(f"\n\n{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  📊 Sentinel Stream & Failover Resilience Report{CLR_RESET}")
        print(f"{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"  Total Test Duration           : {report['total_duration_sec']}s")
        print(f"  Total Write Attempts          : {report['total_write_attempts']}")
        print(f"  Successful Writes Confirmed   : {CLR_GREEN}{report['successful_writes']}{CLR_RESET}")
        print(f"  Transient Failover Rejections : {CLR_YELLOW}{report['failed_writes_during_failover']}{CLR_RESET}")
        print(f"  Availability Percentage       : {CLR_BOLD}{report['availability_pct']}%{CLR_RESET}")
        print(f"  Initial Master Node           : {report['initial_master']}")
        print(f"  Final Master Node             : {CLR_GREEN}{report['final_master']}{CLR_RESET}")
        if failover_events:
            print(f"  Recorded Failover RTO         : {CLR_BOLD}{failover_events[0]['rto_downtime_ms']} ms{CLR_RESET}")
        print(f"{CLR_BOLD}======================================================================{CLR_RESET}\n")

    return report


def main():
    parser = argparse.ArgumentParser(description="Redis Sentinel High Availability & Failover Resilience Tool.")
    parser.add_argument("--master-name", default=os.getenv("REDIS_MASTER_NAME", "mymaster"))
    parser.add_argument("--sentinels", default="localhost:26379,localhost:26380,localhost:26381",
                        help="Comma-separated sentinel host:port list")
    parser.add_argument("--stream", action="store_true", help="Run continuous write stream with failover tracking")
    parser.add_argument("--duration", type=int, default=15, help="Stream duration in seconds (default: 15)")
    parser.add_argument("--rate", type=int, default=20, help="Write rate in Hz (default: 20)")
    parser.add_argument("--info", action="store_true", help="Display cluster topology and Sentinel quorum status")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")

    args = parser.parse_args()

    sentinel_hosts = []
    for item in args.sentinels.split(","):
        if ":" in item:
            h, p = item.strip().split(":")
            sentinel_hosts.append((h, int(p)))

    if args.info:
        topo = get_cluster_topology(sentinel_hosts, args.master_name)
        if args.json:
            print(json.dumps(topo, indent=2))
        else:
            print(f"\n{CLR_CYAN}{CLR_BOLD}🔍 Redis Sentinel Cluster Topology{CLR_RESET}")
            print(f"  Master Name          : {CLR_BOLD}{topo['master_name']}{CLR_RESET}")
            print(f"  Active Master Node   : {CLR_GREEN}{topo['active_master']}{CLR_RESET}")
            print(f"  Configured Sentinels : {CLR_BOLD}{topo['sentinels_count']} nodes (Quorum: 2){CLR_RESET}")
            print(f"  Connected Replicas   : {CLR_BOLD}{topo['replicas_count']} nodes{CLR_RESET}\n")
        return

    if args.stream or not args.info:
        report = run_resilience_stream(
            sentinel_hosts,
            master_name=args.master_name,
            duration_sec=args.duration,
            rate_hz=args.rate,
            json_output=args.json
        )
        if args.json:
            print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
