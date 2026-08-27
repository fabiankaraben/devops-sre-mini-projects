#!/usr/bin/env python3
"""
database_node.py - Replicated Database Node with WAL Stream & Promotion
========================================================================
Implements an Active-Standby database engine supporting:
1. Primary role (Read/Write) streaming Write-Ahead Log (WAL) events to replica.
2. Replica role (Read-Only) replaying incoming WAL stream.
3. Instantaneous promotion (/promote) without data corruption.
4. Fencing (/fence) for split-brain prevention (STONITH).
5. Cryptographic SHA-256 state auditing (/api/dump).
"""

import argparse
import hashlib
import http.server
import json
import logging
import os
import signal
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(threadName)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("database_node")


class DatabaseEngine:
    """ACID in-memory storage engine with sequence tracking and WAL replication."""

    def __init__(self, node_name: str, az: str, role: str = "PRIMARY", replica_url: Optional[str] = None):
        self.node_name = node_name
        self.az = az
        self.role = role.upper()  # PRIMARY or REPLICA
        self.replica_url = replica_url
        self.is_fenced = False
        self.seq_id = 0
        self.store: Dict[str, Dict[str, Any]] = {}
        self.wal_log: List[Dict[str, Any]] = []
        self.lock = threading.RLock()

    def commit_transaction(self, tx_data: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        """Commits a transaction on PRIMARY and streams WAL to REPLICA."""
        with self.lock:
            if self.is_fenced:
                return 423, {"error": "Node is FENCED (STONITH)", "node": self.node_name}

            if self.role != "PRIMARY":
                return 403, {
                    "error": "ReadOnly: Cannot write to database in REPLICA mode",
                    "role": self.role,
                    "node": self.node_name,
                }

            self.seq_id += 1
            tx_id = tx_data.get("tx_id") or f"tx_{self.seq_id}_{int(time.time()*1000)}"
            tx_record = {
                "tx_id": str(tx_id),
                "seq_id": self.seq_id,
                "account": tx_data.get("account", "UNKNOWN"),
                "amount": float(tx_data.get("amount", 0.0)),
                "payload": tx_data.get("payload", {}),
                "committed_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "committed_by_node": self.node_name,
                "az": self.az,
            }

            # Cryptographic record checksum
            record_str = json.dumps(tx_record, sort_keys=True)
            tx_record["checksum"] = hashlib.sha256(record_str.encode("utf-8")).hexdigest()

            # Save locally
            self.store[str(tx_id)] = tx_record
            self.wal_log.append(tx_record)

            # Stream WAL to replica synchronously/semi-synchronously
            if self.replica_url:
                self._stream_wal_to_replica(tx_record)

            return 201, {"status": "COMMITTED", "transaction": tx_record}

    def _stream_wal_to_replica(self, wal_entry: Dict[str, Any]) -> None:
        """Sends committed WAL entry to replica endpoint."""
        target_url = f"{self.replica_url.rstrip('/')}/api/replicate"
        try:
            payload_bytes = json.dumps(wal_entry).encode("utf-8")
            req = urllib.request.Request(
                target_url,
                data=payload_bytes,
                headers={"Content-Type": "application/json", "User-Agent": "DB-WAL-Stream/1.0"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=1.5) as resp:
                if resp.status not in (200, 201):
                    logger.warning(f"Replica returned unexpected status {resp.status} on WAL stream")
        except Exception as e:
            # In real DR, replication lag is logged
            logger.debug(f"WAL stream to {target_url} failed (replica may be down/promoted): {e}")

    def apply_replicated_wal(self, wal_entry: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        """Applies incoming WAL entry on REPLICA node."""
        with self.lock:
            if self.is_fenced:
                return 423, {"error": "Node is FENCED", "node": self.node_name}

            tx_id = str(wal_entry.get("tx_id"))
            incoming_seq = int(wal_entry.get("seq_id", 0))

            # Store transaction
            self.store[tx_id] = wal_entry
            self.wal_log.append(wal_entry)
            self.seq_id = max(self.seq_id, incoming_seq)

            return 200, {"status": "REPLICATED", "applied_seq_id": self.seq_id}

    def promote_to_primary(self) -> Tuple[int, Dict[str, Any]]:
        """Promotes this replica to PRIMARY role."""
        with self.lock:
            if self.is_fenced:
                return 423, {"error": "Cannot promote fenced node", "node": self.node_name}

            prev_role = self.role
            self.role = "PRIMARY"
            # Clear old upstream replication pointer
            self.replica_url = None
            logger.critical(
                f"🚨 [FAILOVER_PROMOTION] Node '{self.node_name}' ({self.az}) PROMOTED from {prev_role} to PRIMARY! "
                f"Active Sequence ID: {self.seq_id}, Total Records: {len(self.store)}"
            )
            return 200, {
                "status": "PROMOTED",
                "node": self.node_name,
                "new_role": "PRIMARY",
                "seq_id": self.seq_id,
                "total_records": len(self.store),
                "promoted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }

    def fence_node(self) -> Tuple[int, Dict[str, Any]]:
        """Applies STONITH fencing to isolate node from further mutations."""
        with self.lock:
            self.is_fenced = True
            logger.critical(f"🛑 [STONITH_FENCE] Node '{self.node_name}' has been FENCED. All operations locked.")
            return 200, {"status": "FENCED", "node": self.node_name}

    def dump_state(self) -> Dict[str, Any]:
        """Calculates global cryptographic SHA-256 checksum of database state."""
        with self.lock:
            # Sort transactions by seq_id for deterministic hash calculation
            sorted_txs = sorted(self.store.values(), key=lambda t: t.get("seq_id", 0))
            dump_str = json.dumps(sorted_txs, sort_keys=True)
            global_hash = hashlib.sha256(dump_str.encode("utf-8")).hexdigest()

            return {
                "node_name": self.node_name,
                "az": self.az,
                "role": self.role,
                "is_fenced": self.is_fenced,
                "seq_id": self.seq_id,
                "record_count": len(self.store),
                "global_state_sha256": global_hash,
                "transactions": sorted_txs,
            }


db_engine: Optional[DatabaseEngine] = None


class DatabaseHTTPHandler(http.server.BaseHTTPRequestHandler):
    """REST API Handler for Database Node."""

    protocol_version = "HTTP/1.1"

    def _send_json(self, status_code: int, data: Dict[str, Any]) -> None:
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if db_engine:
            self.send_header("X-DB-Role", db_engine.role)
            self.send_header("X-DB-AZ", db_engine.az)
            self.send_header("X-DB-SeqID", str(db_engine.seq_id))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(payload)
            self.wfile.flush()
        except Exception:
            pass

    def _read_json_body(self) -> Dict[str, Any]:
        content_len = int(self.headers.get("Content-Length", 0))
        if content_len == 0:
            return {}
        body = self.rfile.read(content_len).decode("utf-8")
        return json.loads(body)

    def do_GET(self) -> None:
        if not db_engine:
            self._send_json(500, {"error": "Engine uninitialized"})
            return

        path = self.path.split("?")[0]

        if path in ("/health", "/healthz"):
            status_code = 503 if db_engine.is_fenced else 200
            self._send_json(status_code, {
                "status": "FENCED" if db_engine.is_fenced else "HEALTHY",
                "node_name": db_engine.node_name,
                "az": db_engine.az,
                "role": db_engine.role,
                "seq_id": db_engine.seq_id,
                "is_fenced": db_engine.is_fenced,
                "record_count": len(db_engine.store),
            })
            return

        if path == "/api/dump":
            self._send_json(200, db_engine.dump_state())
            return

        if path.startswith("/api/tx/"):
            tx_id = path[len("/api/tx/"):]
            with db_engine.lock:
                if tx_id in db_engine.store:
                    self._send_json(200, {"status": "FOUND", "transaction": db_engine.store[tx_id]})
                else:
                    self._send_json(404, {"error": "Transaction not found", "tx_id": tx_id})
            return

        self._send_json(200, {
            "service": "database-node",
            "node_name": db_engine.node_name,
            "role": db_engine.role,
            "az": db_engine.az,
        })

    def do_POST(self) -> None:
        if not db_engine:
            self._send_json(500, {"error": "Engine uninitialized"})
            return

        path = self.path.split("?")[0]

        if path == "/promote":
            code, resp = db_engine.promote_to_primary()
            self._send_json(code, resp)
            return

        if path == "/fence":
            code, resp = db_engine.fence_node()
            self._send_json(code, resp)
            return

        if path == "/api/replicate":
            data = self._read_json_body()
            code, resp = db_engine.apply_replicated_wal(data)
            self._send_json(code, resp)
            return

        if path in ("/api/tx", "/api/transactions"):
            data = self._read_json_body()
            code, resp = db_engine.commit_transaction(data)
            self._send_json(code, resp)
            return

        self._send_json(404, {"error": f"Endpoint not found: {path}"})

    def log_message(self, format: str, *args: Any) -> None:
        pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    global db_engine

    parser = argparse.ArgumentParser(description="Replicated Database Node")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 9001)))
    parser.add_argument("--node-name", type=str, default=os.environ.get("NODE_NAME", "db-primary"))
    parser.add_argument("--az", type=str, default=os.environ.get("AZ", "us-east-1a"))
    parser.add_argument("--role", type=str, default=os.environ.get("ROLE", "PRIMARY"), choices=["PRIMARY", "REPLICA"])
    parser.add_argument("--replica-url", type=str, default=os.environ.get("REPLICA_URL", None))

    args = parser.parse_args()

    db_engine = DatabaseEngine(
        node_name=args.node_name,
        az=args.az,
        role=args.role,
        replica_url=args.replica_url,
    )

    server = ThreadedHTTPServer(("0.0.0.0", args.port), DatabaseHTTPHandler)
    logger.info(
        f"🗄️ Database Node '{args.node_name}' listening on 0.0.0.0:{args.port} | "
        f"Role: {args.role} | AZ: {args.az} | Replica URL: {args.replica_url}"
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
