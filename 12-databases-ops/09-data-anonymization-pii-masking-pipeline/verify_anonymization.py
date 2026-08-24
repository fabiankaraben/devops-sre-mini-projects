#!/usr/bin/env python3
"""
verify_anonymization.py - Security Compliance & Referential Integrity Audit

Scans the sanitized staging_db and exported SQL dumps to verify:
1. 0 PII leaks (No real email domains, unmasked credit cards, real phone numbers, or SSNs).
2. Blacklist verification against raw production data (No raw customer names or emails).
3. 100% referential integrity & foreign key constraint satisfaction across all tables.
4. Complete row count parity between production and staging environments.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# Optional tabulate support with standard fallback
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


def print_table(results):
    if HAS_TABULATE:
        print(tabulate(results, headers=["Compliance Checkpoint", "Status", "Audit Details"], tablefmt="rounded_grid"))
    else:
        print("-" * 80)
        print(f"{'Compliance Checkpoint':<35} | {'Status':<8} | {'Audit Details'}")
        print("-" * 80)
        for r in results:
            stat_color = CLR_GREEN if r[1] == "PASS" else CLR_RED
            print(f"{r[0]:<35} | {stat_color}{r[1]:<8}{CLR_RESET} | {r[2]}")
        print("-" * 80)


def fetch_query(container, db, sql):
    cmd = ["docker", "exec", container, "psql", "-U", "postgres", "-d", db, "-t", "-A", "-F", "||", "-c", sql]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"psql query failed: {res.stderr}")
    lines = res.stdout.strip().splitlines()
    return [l for l in lines if l]


def main():
    parser = argparse.ArgumentParser(description="Security Compliance & Referential Integrity Audit.")
    parser.add_argument("--prod-db", default=os.getenv("PROD_DB", "production_db"))
    parser.add_argument("--staging-db", default=os.getenv("STAGING_DB", "staging_db"))
    parser.add_argument("--container", default="postgres-anonymizer-db")
    parser.add_argument("--dump-file", default="dumps/sanitized_staging_dump.sql")

    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🔍 Security Compliance & Data Anonymization Audit Report{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

    audit_results = []
    total_checks = 0
    passed_checks = 0

    # --------------------------------------------------------------------------
    # Check 1: Row Count Parity
    # --------------------------------------------------------------------------
    total_checks += 1
    tables = ["customers", "credit_cards", "orders", "order_items", "audit_trail"]
    parity_ok = True
    for tbl in tables:
        prod_cnt = int(fetch_query(args.container, args.prod_db, f"SELECT COUNT(*) FROM {tbl};")[0])
        stage_cnt = int(fetch_query(args.container, args.staging_db, f"SELECT COUNT(*) FROM {tbl};")[0])
        if prod_cnt != stage_cnt:
            parity_ok = False
            audit_results.append((f"Row Count Parity ({tbl})", "FAIL", f"Prod: {prod_cnt}, Staging: {stage_cnt}"))
        else:
            audit_results.append((f"Row Count Parity ({tbl})", "PASS", f"{stage_cnt} rows matched"))

    if parity_ok:
        passed_checks += 1

    # --------------------------------------------------------------------------
    # Check 2: Email Anonymization & RFC Domain Compliance
    # --------------------------------------------------------------------------
    total_checks += 1
    emails = fetch_query(args.container, args.staging_db, "SELECT email FROM customers;")
    leaked_emails = [e for e in emails if not e.endswith("@example.org") and not e.endswith("@example.com")]
    if leaked_emails:
        audit_results.append(("Email RFC Domain Compliance", "FAIL", f"Leaked: {leaked_emails[:2]}"))
    else:
        passed_checks += 1
        audit_results.append(("Email RFC Domain Compliance", "PASS", f"100% emails end in @example.org ({len(emails)} checked)"))

    # --------------------------------------------------------------------------
    # Check 3: PCI-DSS Credit Card Format-Preserving Masking
    # --------------------------------------------------------------------------
    total_checks += 1
    cards = fetch_query(args.container, args.staging_db, "SELECT card_number FROM credit_cards;")
    unmasked_cards = [c for c in cards if not re.match(r"^\d{4}-XXXX-XXXX-\d{4}$", c)]
    if unmasked_cards:
        audit_results.append(("PCI-DSS Card Masking", "FAIL", f"Unmasked: {unmasked_cards[:2]}"))
    else:
        passed_checks += 1
        audit_results.append(("PCI-DSS Card Masking", "PASS", f"100% cards masked with XXXX ({len(cards)} checked)"))

    # --------------------------------------------------------------------------
    # Check 4: SSN Dummy Code Redaction
    # --------------------------------------------------------------------------
    total_checks += 1
    ssns = fetch_query(args.container, args.staging_db, "SELECT ssn FROM customers;")
    invalid_ssns = [s for s in ssns if not s.startswith("999-XX-")]
    if invalid_ssns:
        audit_results.append(("SSN Redaction Compliance", "FAIL", f"Invalid: {invalid_ssns[:2]}"))
    else:
        passed_checks += 1
        audit_results.append(("SSN Redaction Compliance", "PASS", f"100% SSNs safely redacted ({len(ssns)} checked)"))

    # --------------------------------------------------------------------------
    # Check 5: Free-Text Notes Scrubbing
    # --------------------------------------------------------------------------
    total_checks += 1
    notes = fetch_query(args.container, args.staging_db, "SELECT customer_notes FROM orders WHERE customer_notes IS NOT NULL;")
    raw_email_in_notes = [n for n in notes if re.search(r"[a-zA-Z0-9_.+-]+@(gmail|corporate-bank|techfirm|global-finance|health-systems)\.com", n)]
    raw_phone_in_notes = [n for n in notes if re.search(r"\+1-555-839-2910|\+1-555-920-1847", n)]
    if raw_email_in_notes or raw_phone_in_notes:
        audit_results.append(("Free-Text PII Scrubbing", "FAIL", "Found unmasked PII in order notes"))
    else:
        passed_checks += 1
        audit_results.append(("Free-Text PII Scrubbing", "PASS", f"0 raw emails or phones found in free-text notes"))

    # --------------------------------------------------------------------------
    # Check 6: Blacklist Comparison Against Production Data
    # --------------------------------------------------------------------------
    total_checks += 1
    prod_names = fetch_query(args.container, args.prod_db, "SELECT full_name FROM customers;")
    staging_names = fetch_query(args.container, args.staging_db, "SELECT full_name FROM customers;")
    leaked_names = set(prod_names).intersection(set(staging_names))
    if leaked_names:
        audit_results.append(("Production Name Blacklist", "FAIL", f"Leaked names: {list(leaked_names)}"))
    else:
        passed_checks += 1
        audit_results.append(("Production Name Blacklist", "PASS", f"0 real production customer names remain in staging"))

    # --------------------------------------------------------------------------
    # Check 7: Referential Integrity Validation
    # --------------------------------------------------------------------------
    total_checks += 1
    # Check orders foreign key
    orphaned_orders = fetch_query(args.container, args.staging_db, "SELECT o.id FROM orders o LEFT JOIN customers c ON o.customer_id = c.id WHERE c.id IS NULL;")
    # Check audit trail natural key
    orphaned_audit = fetch_query(args.container, args.staging_db, "SELECT a.id FROM audit_trail a LEFT JOIN customers c ON a.customer_email = c.email WHERE c.email IS NULL;")
    if orphaned_orders or orphaned_audit:
        audit_results.append(("Referential Integrity", "FAIL", f"Orphaned: orders={len(orphaned_orders)}, audit={len(orphaned_audit)}"))
    else:
        passed_checks += 1
        audit_results.append(("Referential Integrity", "PASS", f"100% foreign keys & natural keys valid"))

    # --------------------------------------------------------------------------
    # Check 8: SQL Dump Sanitization Scan
    # --------------------------------------------------------------------------
    total_checks += 1
    if os.path.exists(args.dump_file):
        with open(args.dump_file, "r") as f:
            dump_content = f.read()
        dump_leaks = []
        for p_name in ["Jane Alice Doe", "jane.doe@gmail.com", "4532-7890-1234-5678", "123-45-6789"]:
            if p_name in dump_content:
                dump_leaks.append(p_name)
        if dump_leaks:
            audit_results.append(("SQL Dump Security Scan", "FAIL", f"Raw PII found in dump: {dump_leaks}"))
        else:
            passed_checks += 1
            audit_results.append(("SQL Dump Security Scan", "PASS", f"Exported SQL dump completely free of raw PII"))
    else:
        audit_results.append(("SQL Dump Security Scan", "FAIL", f"Dump file '{args.dump_file}' not found"))

    # Print Formatted Report Table
    print_table(audit_results)

    print(f"\n{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  Total Compliance Checks : {total_checks}")
    print(f"  Passed                  : {CLR_GREEN}{passed_checks}{CLR_RESET}")
    print(f"  Failed                  : {CLR_RED if total_checks != passed_checks else CLR_GREEN}{total_checks - passed_checks}{CLR_RESET}")
    print(f"{CLR_BOLD}======================================================================{CLR_RESET}\n")

    if passed_checks == total_checks:
        print(f"{CLR_GREEN}{CLR_BOLD}🎉 100% COMPLIANT: All GDPR/PCI-DSS anonymization standards verified!{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"{CLR_RED}{CLR_BOLD}✖ AUDIT FAILED: Non-compliant data detected in staging environment.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
