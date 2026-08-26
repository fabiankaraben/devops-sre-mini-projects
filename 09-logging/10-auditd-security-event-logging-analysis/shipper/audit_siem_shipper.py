#!/usr/bin/env python3
"""Auditd Log Shipper & Security Event Correlation Parser.

Tails /var/log/audit/audit.log, correlates multi-line audit events by event ID,
decodes hex-encoded proctitle / execve arguments, maps rule keys to MITRE ATT&CK
tactics, and forwards structured ECS events to the SIEM analytics backend.
"""

import binascii
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

AUDIT_LOG_PATH = os.environ.get("AUDIT_LOG_PATH", "/var/log/audit/audit.log")
SIEM_URL = os.environ.get("SIEM_URL", "http://127.0.0.1:9099").rstrip("/")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "0.5"))

# MITRE ATT&CK & Threat Level Knowledge Base
RULE_METADATA = {
    "identity_changes": {
        "threat_level": "CRITICAL",
        "category": "iam",
        "mitre_technique": "T1078 (Valid Accounts / User Management)",
        "summary": "Unauthorized modification to system user/password database (/etc/passwd, /etc/shadow)",
    },
    "privilege_escalation": {
        "threat_level": "CRITICAL",
        "category": "privilege-escalation",
        "mitre_technique": "T1548.003 (Sudo and Sudoers Tampering)",
        "summary": "Tampering with /etc/sudoers or elevated permissions map detected",
    },
    "sshd_tamper": {
        "threat_level": "HIGH",
        "category": "persistence",
        "mitre_technique": "T1098.004 (SSH Authorized Keys / Config Tampering)",
        "summary": "SSH daemon configuration file modified",
    },
    "priv_escalation_syscalls": {
        "threat_level": "HIGH",
        "category": "privilege-escalation",
        "mitre_technique": "T1068 (Exploitation for Privilege Escalation)",
        "summary": "Execution of setuid/setgid/setreuid privilege change syscall",
    },
    "user_commands": {
        "threat_level": "MEDIUM",
        "category": "execution",
        "mitre_technique": "T1059 (Command and Scripting Interpreter)",
        "summary": "Interactive execution of command by non-root / audited user",
    },
    "file_deletion": {
        "threat_level": "MEDIUM",
        "category": "defense-evasion",
        "mitre_technique": "T1070.004 (File Deletion / Indicator Removal)",
        "summary": "File deletion or renaming syscall executed",
    },
    "kernel_modules": {
        "threat_level": "CRITICAL",
        "category": "persistence",
        "mitre_technique": "T1547.006 (Kernel Modules and Drivers)",
        "summary": "Kernel module load/unload attempt detected",
    },
}

# Regex to parse key=value or key="value" in audit lines
AUDIT_KV_RE = re.compile(r'(\w+)=(?:"([^"]*)"|(\S+))')
MSG_ID_RE = re.compile(r'msg=audit\((\d+\.\d+):(\d+)\):')


def decode_hex_string(raw_val: str) -> str:
    """Decode hex-encoded audit strings (e.g. proctitle or command arguments)."""
    if not raw_val or len(raw_val) < 2 or len(raw_val) % 2 != 0:
        return raw_val
    # Hex detection: all hex chars and length > 4
    if re.fullmatch(r"[0-9A-Fa-f]+", raw_val):
        try:
            decoded = binascii.unhexlify(raw_val).decode("utf-8", errors="replace")
            # Replace null byte separators with spaces
            cleaned = decoded.replace("\x00", " ").strip()
            if cleaned and all(c.isprintable() or c in "\t\n\r" for c in cleaned):
                return cleaned
        except Exception:
            pass
    return raw_val


def parse_audit_line(line: str) -> Optional[Tuple[str, str, Dict[str, str]]]:
    """Parse raw audit line into (record_type, event_id, kv_dict)."""
    line = line.strip()
    if not line.startswith("type="):
        return None

    # Extract record type
    type_match = re.match(r"type=(\w+)", line)
    if not type_match:
        return None
    rec_type = type_match.group(1)

    # Extract msg=audit(ts:serial):
    id_match = MSG_ID_RE.search(line)
    if not id_match:
        return None
    event_id = f"{id_match.group(1)}:{id_match.group(2)}"

    # Parse key-values
    kv = {}
    for match in AUDIT_KV_RE.finditer(line):
        k = match.group(1)
        v = match.group(2) if match.group(2) is not None else match.group(3)
        if k != "type":
            kv[k] = v

    return rec_type, event_id, kv


class AuditLogShipper:
    """Correlates audit records and forwards normalized security events."""

    def __init__(self, log_path: str, siem_url: str):
        self.log_path = Path(log_path)
        self.siem_url = siem_url
        self.event_groups: Dict[str, Dict[str, Any]] = {}
        self.event_timestamps: Dict[str, float] = {}

    def _ensure_log_file(self):
        """Ensure parent dir and audit.log file exist."""
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        if not self.log_path.exists():
            self.log_path.touch(mode=0o640, exist_ok=True)

    def correlate_and_normalize(self, event_id: str, records: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Normalize grouped records into an ECS-compliant security alert object."""
        syscall_rec = records.get("SYSCALL", {})
        path_rec = records.get("PATH", {})
        proctitle_rec = records.get("PROCTITLE", {})
        execve_rec = records.get("EXECVE", {})
        user_cmd_rec = records.get("USER_CMD", {})

        # Determine rule key
        rule_key = syscall_rec.get("key") or path_rec.get("key") or "user_commands"
        rule_meta = RULE_METADATA.get(rule_key, {
            "threat_level": "MEDIUM" if rule_key != "user_commands" else "LOW",
            "category": "security",
            "mitre_technique": "T1059 (Command Execution)",
            "summary": f"Audit rule triggered: {rule_key}",
        })

        # Parse timestamp
        epoch_str = event_id.split(":")[0]
        try:
            dt = datetime.fromtimestamp(float(epoch_str), tz=timezone.utc)
            iso_time = dt.isoformat()
        except Exception:
            iso_time = datetime.now(timezone.utc).isoformat()

        # Decode command line
        cmdline = None
        if "proctitle" in proctitle_rec:
            cmdline = decode_hex_string(proctitle_rec["proctitle"])
        elif "cmd" in user_cmd_rec:
            cmdline = user_cmd_rec["cmd"]
        elif execve_rec:
            args = [execve_rec[k] for k in sorted(execve_rec.keys()) if k.startswith("a") and k[1:].isdigit()]
            cmdline = " ".join(decode_hex_string(a) for a in args)

        if not cmdline:
            cmdline = decode_hex_string(syscall_rec.get("comm", "unknown"))

        # Target file
        target_path = path_rec.get("name") or syscall_rec.get("name")
        if target_path:
            target_path = decode_hex_string(target_path)

        # Build ECS Document
        ecs_doc = {
            "timestamp": iso_time,
            "audit_event_id": event_id,
            "event": {
                "category": [rule_meta["category"], "process"],
                "action": rule_key,
                "outcome": "success" if syscall_rec.get("success") in ("yes", "1") else "failure",
            },
            "rule": {
                "name": rule_key,
                "threat_level": rule_meta["threat_level"],
                "mitre_technique": rule_meta["mitre_technique"],
                "summary": rule_meta["summary"],
            },
            "user": {
                "id": int(syscall_rec.get("uid", 0)) if syscall_rec.get("uid", "").isdigit() else 0,
                "audit_id": int(syscall_rec.get("auid", -1)) if syscall_rec.get("auid", "").isdigit() else -1,
                "effective_id": int(syscall_rec.get("euid", 0)) if syscall_rec.get("euid", "").isdigit() else 0,
                "session": int(syscall_rec.get("ses", 0)) if syscall_rec.get("ses", "").isdigit() else 0,
            },
            "process": {
                "pid": int(syscall_rec.get("pid", 0)) if syscall_rec.get("pid", "").isdigit() else 0,
                "ppid": int(syscall_rec.get("ppid", 0)) if syscall_rec.get("ppid", "").isdigit() else 0,
                "name": decode_hex_string(syscall_rec.get("comm", "unknown")),
                "executable": decode_hex_string(syscall_rec.get("exe", "unknown")),
                "command_line": cmdline,
            },
            "syscall": syscall_rec.get("syscall", "N/A"),
        }

        if target_path:
            ecs_doc["file"] = {
                "path": target_path,
                "inode": int(path_rec.get("inode", 0)) if path_rec.get("inode", "").isdigit() else 0,
            }

        return ecs_doc

    def ship_to_siem(self, doc: Dict[str, Any]) -> bool:
        """Transmit correlated security document to the SIEM REST API."""
        url = f"{self.siem_url}/api/events"
        data = json.dumps(doc).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                return resp.status in (200, 201)
        except Exception as exc:
            # Print brief warning
            print(f"[Shipper Warning] Failed to deliver event {doc.get('audit_event_id')} to SIEM: {exc}", file=sys.stderr)
            return False

    def flush_stale_events(self, max_age_seconds: float = 1.0):
        """Flush and ship correlated events that have completed collection."""
        now = time.time()
        to_delete = []
        for eid, ts in self.event_timestamps.items():
            if now - ts >= max_age_seconds:
                records = self.event_groups.get(eid, {})
                doc = self.correlate_and_normalize(eid, records)
                if doc:
                    self.ship_to_siem(doc)
                    rule_name = doc.get("rule", {}).get("name")
                    sev = doc.get("rule", {}).get("threat_level")
                    print(f"  [SIEM SHIPPED] [{sev}] Event {eid}: Rule '{rule_name}' -> {doc.get('process', {}).get('command_line')}")
                to_delete.append(eid)

        for eid in to_delete:
            self.event_groups.pop(eid, None)
            self.event_timestamps.pop(eid, None)

    def run(self):
        """Main tailing loop."""
        self._ensure_log_file()
        print(f"🚀 Auditd SIEM Shipper daemon active.")
        print(f"   Watching: {self.log_path}")
        print(f"   Forwarding to: {self.siem_url}/api/events")

        with open(self.log_path, "r", encoding="utf-8", errors="replace") as f:
            # Seek to start or end
            f.seek(0, os.SEEK_SET)

            while True:
                line = f.readline()
                if line:
                    parsed = parse_audit_line(line)
                    if parsed:
                        rec_type, event_id, kv = parsed
                        if event_id not in self.event_groups:
                            self.event_groups[event_id] = {}
                            self.event_timestamps[event_id] = time.time()
                        self.event_groups[event_id][rec_type] = kv

                else:
                    self.flush_stale_events()
                    time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    shipper = AuditLogShipper(AUDIT_LOG_PATH, SIEM_URL)
    try:
        shipper.run()
    except KeyboardInterrupt:
        print("\nStopping audit shipper...")
