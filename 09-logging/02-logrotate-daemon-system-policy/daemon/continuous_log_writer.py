#!/usr/bin/env python3
"""Continuous Log Writer Daemon with SIGHUP File Descriptor Reopening.

Simulates a high-throughput enterprise application writing sequentially indexed logs
to an open file descriptor while responding gracefully to logrotate SIGHUP signals.
"""

import argparse
import datetime
import json
import os
import signal
import sys
import time
from typing import Optional, TextIO

# ANSI Terminal Colors
CLR_RESET = "\033[0m"
CLR_GREEN = "\033[1;32m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_RED = "\033[1;31m"


class ContinuousLogWriter:
    """Daemon that continuously writes indexed log events and re-opens its FD upon SIGHUP."""

    def __init__(
        self,
        log_file: str,
        pid_file: str,
        rate_per_sec: float = 50.0,
        verbose: bool = False,
    ):
        self.log_file = os.path.abspath(log_file)
        self.pid_file = os.path.abspath(pid_file)
        self.interval = 1.0 / max(1.0, rate_per_sec)
        self.verbose = verbose

        self.running: bool = True
        self.reopen_requested: bool = False
        self.sequence_number: int = 0
        self.file_handle: Optional[TextIO] = None
        self.current_inode: int = 0
        self.reloads_count: int = 0

    def _setup_signal_handlers(self) -> None:
        """Register POSIX signal handlers for non-disruptive log rotation and termination."""
        signal.signal(signal.SIGHUP, self._on_sighup)
        signal.signal(signal.SIGUSR1, self._on_sighup)
        signal.signal(signal.SIGTERM, self._on_terminate)
        signal.signal(signal.SIGINT, self._on_terminate)

    def _on_sighup(self, signum: int, frame) -> None:
        """Signal handler for SIGHUP / SIGUSR1."""
        self.reopen_requested = True
        if self.verbose:
            sig_name = "SIGHUP" if signum == signal.SIGHUP else "SIGUSR1"
            print(
                f"{CLR_CYAN}[DAEMON] Received signal {sig_name}. Queuing file descriptor reload.{CLR_RESET}",
                file=sys.stderr,
            )

    def _on_terminate(self, signum: int, frame) -> None:
        """Signal handler for graceful shutdown."""
        self.running = False
        if self.verbose:
            print(
                f"\n{CLR_YELLOW}[DAEMON] Termination signal received. Shutting down cleanly...{CLR_RESET}",
                file=sys.stderr,
            )

    def _write_pid_file(self) -> None:
        """Write current process ID to pidfile for logrotate postrotate discovery."""
        pid_dir = os.path.dirname(self.pid_file)
        if pid_dir:
            os.makedirs(pid_dir, exist_ok=True)
        with open(self.pid_file, "w", encoding="utf-8") as f:
            f.write(f"{os.getpid()}\n")

    def _remove_pid_file(self) -> None:
        """Clean up pidfile on shutdown."""
        if os.path.exists(self.pid_file):
            try:
                os.remove(self.pid_file)
            except OSError:
                pass

    def _open_log_file(self) -> None:
        """Open or reopen the target log file in append mode and track its inode."""
        log_dir = os.path.dirname(self.log_file)
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)

        # Close existing handle if open
        if self.file_handle:
            try:
                self.file_handle.flush()
                os.fsync(self.file_handle.fileno())
                self.file_handle.close()
            except Exception as exc:
                print(
                    f"{CLR_RED}[DAEMON ERR] Failed closing old file handle: {exc}{CLR_RESET}",
                    file=sys.stderr,
                )

        # Open target path in append mode
        self.file_handle = open(self.log_file, "a", encoding="utf-8")
        self.current_inode = os.fstat(self.file_handle.fileno()).st_ino

        if self.verbose:
            print(
                f"{CLR_GREEN}[DAEMON] Attached to log file '{self.log_file}' (Inode: {self.current_inode}){CLR_RESET}",
                file=sys.stderr,
            )

    def _reopen_log_file(self) -> None:
        """Perform non-disruptive file descriptor reopening after SIGHUP."""
        old_inode = self.current_inode
        self._open_log_file()
        self.reloads_count += 1
        self.reopen_requested = False

        # Emit structured audit record indicating successful FD transition
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        reload_record = {
            "seq": self.sequence_number + 1,
            "timestamp": now,
            "level": "INFO",
            "event": "log_file_reopened",
            "pid": os.getpid(),
            "old_inode": old_inode,
            "new_inode": self.current_inode,
            "reload_count": self.reloads_count,
            "message": f"Closed old inode {old_inode}, opened new inode {self.current_inode} after SIGHUP.",
        }
        self.sequence_number += 1
        self._write_raw_entry(reload_record)

    def _write_raw_entry(self, entry_dict: dict) -> None:
        """Serialize and write a single JSON line to the active file descriptor."""
        if self.file_handle:
            line = json.dumps(entry_dict, ensure_ascii=False) + "\n"
            self.file_handle.write(line)
            self.file_handle.flush()

    def run(self, max_records: Optional[int] = None) -> None:
        """Main daemon loop generating monotonic log stream."""
        self._setup_signal_handlers()
        self._write_pid_file()
        self._open_log_file()

        if self.verbose:
            print(
                f"{CLR_CYAN}[DAEMON] Started with PID {os.getpid()}. Writing {1.0/self.interval:.0f} logs/sec...{CLR_RESET}",
                file=sys.stderr,
            )

        try:
            while self.running:
                # Handle pending SIGHUP reload before next write
                if self.reopen_requested:
                    self._reopen_log_file()

                self.sequence_number += 1
                now = datetime.datetime.now(datetime.timezone.utc).isoformat()

                record = {
                    "seq": self.sequence_number,
                    "timestamp": now,
                    "level": "INFO" if self.sequence_number % 10 != 0 else "WARNING",
                    "pid": os.getpid(),
                    "inode": self.current_inode,
                    "service": "custom-app",
                    "message": f"Application transaction #{self.sequence_number} processed successfully.",
                    "context": {
                        "batch_id": f"batch_{self.sequence_number // 100}",
                        "worker_thread": "worker-main",
                        "status": "success",
                    },
                }

                self._write_raw_entry(record)

                if max_records and self.sequence_number >= max_records:
                    break

                time.sleep(self.interval)

        finally:
            if self.file_handle:
                self.file_handle.flush()
                self.file_handle.close()
            self._remove_pid_file()
            if self.verbose:
                print(
                    f"{CLR_GREEN}[DAEMON] Shutdown complete. Emitted {self.sequence_number} records.{CLR_RESET}",
                    file=sys.stderr,
                )


# ------------------------------------------------------------------------------
# CLI Entrypoint
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Continuous Log Writer Daemon with SIGHUP reload support."
    )
    parser.add_argument(
        "--log-file",
        default="/var/log/custom-app/app.log",
        help="Path to output log file (default: /var/log/custom-app/app.log)",
    )
    parser.add_argument(
        "--pid-file",
        default="/var/run/custom-app.pid",
        help="Path to daemon PID file (default: /var/run/custom-app.pid)",
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=50.0,
        help="Logs emitted per second (default: 50.0)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=None,
        help="Optional total number of records to emit before stopping.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print daemon lifecycle events to stderr.",
    )
    args = parser.parse_args()

    daemon = ContinuousLogWriter(
        log_file=args.log_file,
        pid_file=args.pid_file,
        rate_per_sec=args.rate,
        verbose=args.verbose,
    )
    daemon.run(max_records=args.count)


if __name__ == "__main__":
    main()
