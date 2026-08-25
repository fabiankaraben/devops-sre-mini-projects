#!/usr/bin/env bash
# ==============================================================================
# Script Name: benchmark_network.sh
# Description: TCP Socket Micro-Benchmark measuring connection throughput,
#              concurrency limits, and handshake latency before and after kernel tuning.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -uo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
DIM="\033[2m"
NC="\033[0m"

PORT=18888
TOTAL_REQS=200
CONCURRENCY=20
JSON_OUTPUT=0

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

TCP Socket Concurrency & Latency Benchmark

Options:
  -p, --port <port>          Port for local benchmarking listener (default: 18888)
  -n, --requests <count>     Total connection requests to generate (default: 200)
  -c, --concurrency <count>  Concurrent connection workers (default: 20)
  -j, --json                 Output benchmark metrics in JSON format
  -h, --help                 Display this help message and exit

Examples:
  $(basename "$0") -n 500 -c 50
  $(basename "$0") --json
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -n|--requests)
            TOTAL_REQS="$2"
            shift 2
            ;;
        -c|--concurrency)
            CONCURRENCY="$2"
            shift 2
            ;;
        -j|--json)
            JSON_OUTPUT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            usage
            exit 3
            ;;
    esac
done

# Python helper to run benchmark server and concurrent client load
BENCHMARK_RESULT=$(python3 - << EOF
import socket
import threading
import time
import sys
import json

HOST = "127.0.0.1"
PORT = $PORT
TOTAL = $TOTAL_REQS
CONCURRENCY = $CONCURRENCY

server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    server_sock.bind((HOST, PORT))
    server_sock.listen(1024)
except Exception as e:
    print(json.dumps({"error": f"Failed to bind benchmark listener: {e}"}))
    sys.exit(1)

stop_server = False

def server_worker():
    while not stop_server:
        try:
            server_sock.settimeout(0.2)
            conn, _ = server_sock.accept()
            conn.sendall(b"OK\n")
            conn.close()
        except socket.timeout:
            continue
        except Exception:
            break

srv_thread = threading.Thread(target=server_worker, daemon=True)
srv_thread.start()

time.sleep(0.1)

latencies = []
successful = 0
failed = 0
lock = threading.Lock()
reqs_per_worker = TOTAL // CONCURRENCY

start_time = time.perf_counter()

def client_worker():
    global successful, failed
    for _ in range(reqs_per_worker):
        t0 = time.perf_counter()
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect((HOST, PORT))
            data = s.recv(16)
            s.close()
            t1 = time.perf_counter()
            lat_ms = (t1 - t0) * 1000.0
            with lock:
                latencies.append(lat_ms)
                successful += 1
        except Exception:
            with lock:
                failed += 1

workers = []
for _ in range(CONCURRENCY):
    w = threading.Thread(target=client_worker)
    w.start()
    workers.append(w)

for w in workers:
    w.join()

end_time = time.perf_counter()
stop_server = True
server_sock.close()

duration_s = max(0.001, end_time - start_time)
rate_rps = successful / duration_s

avg_lat = sum(latencies) / len(latencies) if latencies else 0.0
sorted_lat = sorted(latencies) if latencies else [0.0]
p50 = sorted_lat[int(len(sorted_lat) * 0.50)]
p95 = sorted_lat[min(len(sorted_lat) - 1, int(len(sorted_lat) * 0.95))]
p99 = sorted_lat[min(len(sorted_lat) - 1, int(len(sorted_lat) * 0.99))]

data = {
    "total_requests": TOTAL,
    "concurrency": CONCURRENCY,
    "duration_seconds": round(duration_s, 4),
    "successful_connections": successful,
    "failed_connections": failed,
    "connections_per_second": round(rate_rps, 2),
    "latency_ms": {
        "avg": round(avg_lat, 2),
        "p50": round(p50, 2),
        "p95": round(p95, 2),
        "p99": round(p99, 2)
    }
}
print(json.dumps(data))
EOF
)

if [[ $JSON_OUTPUT -eq 1 ]]; then
    echo "$BENCHMARK_RESULT"
    exit 0
fi

# Pretty ANSI Output
python3 -c "
import sys, json

data = json.loads('''$BENCHMARK_RESULT''')
if 'error' in data:
    print('\033[0;31m' + data['error'] + '\033[0m')
    sys.exit(1)

print('\n\033[1;34m========================================================================================================\033[0m')
print('\033[1m                       TCP SOCKET CONCURRENCY & LATENCY BENCHMARK                                       \033[0m')
print('\033[1;34m========================================================================================================\033[0m\n')
print(f'  Total Requests    : \033[1m{data[\"total_requests\"]}\033[0m')
print(f'  Concurrency Level : \033[1m{data[\"concurrency\"]}\033[0m simultaneous workers')
print(f'  Completed Duration: {data[\"duration_seconds\"]} seconds\n')

succ = data['successful_connections']
fail = data['failed_connections']
print(f'  \033[0;32m✔ Successful Connections\033[0m : {succ}')
print(f'  \033[0;31m✖ Failed / Dropped Sockets\033[0m: {fail}')
print(f'  \033[1;36m⚡ Connection Throughput\033[0m : \033[1m{data[\"connections_per_second\"]} req/sec\033[0m\n')

lat = data['latency_ms']
print('LATENCY PROFILING (Milliseconds):')
print(f'  - Average Handshake: {lat[\"avg\"]} ms')
print(f'  - 50th Percentile  : {lat[\"p50\"]} ms')
print(f'  - 95th Percentile  : {lat[\"p95\"]} ms')
print(f'  - 99th Percentile  : {lat[\"p99\"]} ms\n')
print('\033[2m========================================================================================================\033[0m\n')
"
