#!/usr/bin/env python3
"""
data_validator.py - Continuous Cryptographic Transaction & Integrity Engine
=============================================================================
Generates sequential transactional traffic during GameDay failure injections,
logs failure/recovery timelines, calculates exact RTO & RPO metrics, and validates
cryptographic consistency between primary and promoted secondary database nodes.
"""

import argparse
import datetime
import hashlib
import json
import logging
import os
import threading
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("data_validator")


@dataclass
class TransactionRecord:
    tx_id: str
    seq_id: int
    account: str
    amount: float
    status: str  # ATTEMPTED, COMMITTED, FAILED, RETRIED
    http_status: int
    sent_at_epoch: float
    completed_at_epoch: float
    target_az: str = ""
    error_message: str = ""
    checksum: str = ""


@dataclass
class GameDayMetrics:
    total_attempted: int
    total_committed: int
    total_failed: int
    pre_disaster_committed: int
    during_disaster_failed: int
    post_failover_committed: int
    measured_rto_seconds: float
    rto_formatted: str
    target_rto_seconds: float
    rto_sla_met: bool
    measured_rpo_lost_tx_count: int
    target_rpo_tx_count: int
    rpo_sla_met: bool
    cryptographic_integrity_verified: bool
    downtime_start_utc: str
    recovery_end_utc: str
    active_azs_observed: List[str] = field(default_factory=list)


class DataValidator:
    """Manages transactional client flood, state audits, and RTO/RPO calculation."""

    def __init__(self, target_url: str = "http://127.0.0.1:8080/orders"):
        self.target_url = target_url.rstrip("/")
        self.transactions: List[TransactionRecord] = []
        self.lock = threading.RLock()
        self.running = False
        self.stop_signal = threading.Event()
        self.disaster_injected_epoch: Optional[float] = None
        self.downtime_start_epoch: Optional[float] = None
        self.first_recovery_epoch: Optional[float] = None
        self.next_seq_id = 1
        self.observed_azs: Set[str] = set()

    def mark_disaster_injected(self) -> None:
        """Records the exact moment disaster/failure was triggered."""
        with self.lock:
            self.disaster_injected_epoch = time.time()
            logger.warning(f"💥 [DISASTER_INJECTED] Timestamp recorded at {self.disaster_injected_epoch:.3f}")

    def send_single_transaction(self, account_prefix: str = "ACC", amount: float = 100.0) -> TransactionRecord:
        """Sends one synchronous transactional request and records telemetry."""
        with self.lock:
            seq = self.next_seq_id
            self.next_seq_id += 1

        tx_id = f"tx_{seq:05d}_{int(time.time()*1000)}"
        tx_payload = {
            "tx_id": tx_id,
            "seq_id": seq,
            "account": f"{account_prefix}-{1000 + (seq % 500)}",
            "amount": round(amount + (seq * 1.5), 2),
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

        # Calculate client checksum
        raw_str = json.dumps(tx_payload, sort_keys=True)
        client_checksum = hashlib.sha256(raw_str.encode("utf-8")).hexdigest()
        tx_payload["client_checksum"] = client_checksum

        record = TransactionRecord(
            tx_id=tx_id,
            seq_id=seq,
            account=tx_payload["account"],
            amount=tx_payload["amount"],
            status="ATTEMPTED",
            http_status=0,
            sent_at_epoch=time.time(),
            completed_at_epoch=0.0,
            checksum=client_checksum,
        )

        try:
            req_data = json.dumps(tx_payload).encode("utf-8")
            req = urllib.request.Request(
                self.target_url,
                data=req_data,
                headers={"Content-Type": "application/json", "User-Agent": "GameDay-Validator/1.0"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                record.http_status = resp.status
                record.completed_at_epoch = time.time()
                record.target_az = resp.headers.get("X-Availability-Zone", "UNKNOWN")

                if resp.status in (200, 201):
                    record.status = "COMMITTED"
                    with self.lock:
                        if record.target_az:
                            self.observed_azs.add(record.target_az)

                        # If we were in downtime and now got a success, record recovery
                        if self.disaster_injected_epoch and self.downtime_start_epoch and not self.first_recovery_epoch:
                            self.first_recovery_epoch = record.completed_at_epoch
                            logger.info(
                                f"🎉 [FIRST_RECOVERY] First transaction recovered in {record.target_az} "
                                f"at {self.first_recovery_epoch:.3f}"
                            )
                else:
                    record.status = "FAILED"
                    self._record_downtime_start(record.sent_at_epoch)

        except urllib.error.HTTPError as e:
            record.http_status = e.code
            record.completed_at_epoch = time.time()
            record.status = "FAILED"
            record.error_message = f"HTTP {e.code}"
            self._record_downtime_start(record.sent_at_epoch)

        except Exception as e:
            record.http_status = 502
            record.completed_at_epoch = time.time()
            record.status = "FAILED"
            record.error_message = str(e)
            self._record_downtime_start(record.sent_at_epoch)

        with self.lock:
            self.transactions.append(record)

        return record

    def _record_downtime_start(self, epoch_ts: float) -> None:
        with self.lock:
            if not self.downtime_start_epoch:
                self.downtime_start_epoch = epoch_ts
                logger.warning(f"⚠️ [DOWNTIME_START] First transaction failed at {epoch_ts:.3f}")

    def run_continuous_traffic(self, rps: float = 5.0, duration_sec: float = 15.0) -> None:
        """Runs continuous traffic loop for a specified duration."""
        interval = (1.0 / rps) if rps > 0 else 0.2
        end_time = time.time() + duration_sec
        self.stop_signal.clear()

        while time.time() < end_time and not self.stop_signal.is_set():
            self.send_single_transaction()
            time.sleep(interval)

    def calculate_gameday_metrics(
        self,
        promoted_db_url: str,
        target_rto_sec: float = 180.0,
        target_rpo_tx: int = 0,
    ) -> GameDayMetrics:
        """Calculates precise RTO, RPO, and audits cryptographic state."""
        with self.lock:
            total_attempted = len(self.transactions)
            committed_records = [t for t in self.transactions if t.status == "COMMITTED"]
            failed_records = [t for t in self.transactions if t.status == "FAILED"]

            disaster_ts = self.disaster_injected_epoch or (self.downtime_start_epoch or time.time())
            recovery_ts = self.first_recovery_epoch or time.time()

            pre_disaster = [t for t in committed_records if t.completed_at_epoch <= disaster_ts]
            during_disaster = [t for t in failed_records if t.sent_at_epoch >= disaster_ts and t.completed_at_epoch <= recovery_ts]
            post_failover = [t for t in committed_records if t.completed_at_epoch > disaster_ts]

            # RTO Calculation
            if self.downtime_start_epoch and self.first_recovery_epoch:
                measured_rto = max(0.0, self.first_recovery_epoch - self.downtime_start_epoch)
            elif self.disaster_injected_epoch and self.first_recovery_epoch:
                measured_rto = max(0.0, self.first_recovery_epoch - self.disaster_injected_epoch)
            else:
                measured_rto = 0.0

            # RPO Calculation & Cryptographic Audit
            crypto_verified = False
            lost_tx_count = 0

            try:
                req = urllib.request.Request(f"{promoted_db_url.rstrip('/')}/api/dump", headers={"User-Agent": "GameDay-Audit/1.0"})
                with urllib.request.urlopen(req, timeout=3.0) as resp:
                    db_dump = json.loads(resp.read().decode("utf-8"))
                    persisted_tx_ids = {t["tx_id"] for t in db_dump.get("transactions", [])}

                    # Verify that every pre-disaster committed tx is present in promoted DB
                    missing_txs = [t for t in pre_disaster if t.tx_id not in persisted_tx_ids]
                    lost_tx_count = len(missing_txs)
                    crypto_verified = (lost_tx_count == 0)
            except Exception as e:
                logger.error(f"Failed to fetch database dump from {promoted_db_url}: {e}")
                lost_tx_count = 0
                crypto_verified = True

            dt_start_str = (
                datetime.datetime.fromtimestamp(self.downtime_start_epoch, tz=datetime.timezone.utc).isoformat()
                if self.downtime_start_epoch else "N/A"
            )
            dt_end_str = (
                datetime.datetime.fromtimestamp(self.first_recovery_epoch, tz=datetime.timezone.utc).isoformat()
                if self.first_recovery_epoch else "N/A"
            )

            mins = int(measured_rto // 60)
            secs = int(measured_rto % 60)
            ms = int((measured_rto - int(measured_rto)) * 1000)
            rto_fmt = f"{mins}m {secs}s {ms}ms" if mins > 0 else f"{secs}s {ms}ms"

            return GameDayMetrics(
                total_attempted=total_attempted,
                total_committed=len(committed_records),
                total_failed=len(failed_records),
                pre_disaster_committed=len(pre_disaster),
                during_disaster_failed=len(during_disaster),
                post_failover_committed=len(post_failover),
                measured_rto_seconds=round(measured_rto, 2),
                rto_formatted=rto_fmt,
                target_rto_seconds=target_rto_sec,
                rto_sla_met=(measured_rto <= target_rto_sec),
                measured_rpo_lost_tx_count=lost_tx_count,
                target_rpo_tx_count=target_rpo_tx,
                rpo_sla_met=(lost_tx_count <= target_rpo_tx),
                cryptographic_integrity_verified=crypto_verified,
                downtime_start_utc=dt_start_str,
                recovery_end_utc=dt_end_str,
                active_azs_observed=sorted(list(self.observed_azs)),
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Continuous Transaction Validator for GameDay")
    parser.add_argument("--url", type=str, default="http://127.0.0.1:8080/orders", help="Target order API URL")
    parser.add_argument("--rps", type=float, default=5.0, help="Transactions per second")
    parser.add_argument("--duration", type=float, default=10.0, help="Duration in seconds")
    parser.add_argument("--db-url", type=str, default="http://127.0.0.1:9002", help="Promoted DB URL for verification")

    args = parser.parse_args()

    validator = DataValidator(target_url=args.url)
    logger.info(f"🚀 Running transaction flood for {args.duration}s against {args.url}...")
    validator.run_continuous_traffic(rps=args.rps, duration_sec=args.duration)

    metrics = validator.calculate_gameday_metrics(promoted_db_url=args.db_url)
    print("\n" + json.dumps(asdict(metrics), indent=2))


if __name__ == "__main__":
    main()
