#!/usr/bin/env python3
"""
mask_database.py - Automated ETL Data Anonymization & PII Masking Pipeline

Extracts sensitive records from production_db, executes deterministic & format-preserving
PII masking (names, emails, credit cards, SSNs, physical addresses, and free-text notes),
maintains referential integrity across relational tables, and loads the sanitized dataset
into staging_db while exporting a sanitized SQL dump.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# Optional Faker support with built-in deterministic fallback
try:
    from faker import Faker
    fake = Faker()
    Faker.seed(42)
    HAS_FAKER = True
except ImportError:
    HAS_FAKER = False

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_CYAN = "\033[1;36m"
CLR_YELLOW = "\033[1;33m"
CLR_RED = "\033[1;31m"
CLR_GRAY = "\033[0;90m"

# Synthetic name pool fallback
SYNTHETIC_FIRST_NAMES = ["Alex", "Jordan", "Taylor", "Morgan", "Sam", "Chris", "Pat", "Riley", "Casey", "Avery"]
SYNTHETIC_LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Miller", "Davis", "Wilson", "Taylor", "Anderson"]


def generate_synthetic_name(seed_id):
    """Generates deterministic synthetic name based on ID."""
    if HAS_FAKER:
        fake.seed_instance(seed_id * 100 + 7)
        return fake.name()
    f = SYNTHETIC_FIRST_NAMES[seed_id % len(SYNTHETIC_FIRST_NAMES)]
    l = SYNTHETIC_LAST_NAMES[(seed_id * 3) % len(SYNTHETIC_LAST_NAMES)]
    return f"{f} {l}"


def generate_synthetic_email(seed_id):
    """Generates synthetic email under safe RFC example.org domain."""
    return f"user_{seed_id:04d}@example.org"


def generate_synthetic_phone(seed_id):
    """Generates test-safe 555 prefix phone number."""
    return f"+1-555-010-{seed_id:04d}"


def generate_synthetic_ssn(seed_id):
    """Generates format-preserving dummy SSN (using invalid 999 area code)."""
    return f"999-XX-{seed_id:04d}"


def generate_synthetic_address(seed_id):
    """Generates realistic synthetic address."""
    street_num = (seed_id * 100) + 12
    return f"{street_num} Innovation Blvd, Suite {(seed_id * 5) + 1}, Staging City, CA 94016"


def mask_credit_card(raw_card):
    """Applies PCI-DSS format-preserving masking: 4111-XXXX-XXXX-1234."""
    digits = re.sub(r"\D", "", raw_card)
    if len(digits) >= 12:
        last4 = digits[-4:]
        first_prefix = "4111" if digits.startswith("4") else "5424" if digits.startswith("5") else "3782"
        return f"{first_prefix}-XXXX-XXXX-{last4}"
    return "4111-XXXX-XXXX-0000"


def scrub_free_text(text, real_name_map=None):
    """Redacts embedded PII from unstructured text notes using regex."""
    if not text:
        return text

    scrubbed = text
    # 1. Replace emails
    scrubbed = re.sub(r"[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+", "[REDACTED_EMAIL]", scrubbed)

    # 2. Replace phone numbers
    scrubbed = re.sub(r"(\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}", "[REDACTED_PHONE]", scrubbed)

    # 3. Replace credit card numbers
    scrubbed = re.sub(r"\b(?:\d[ -]*?){13,16}\b", "[REDACTED_CARD]", scrubbed)

    # 4. Replace specific known customer names if map provided
    if real_name_map:
        for real_name, fake_name in real_name_map.items():
            if real_name in scrubbed:
                scrubbed = scrubbed.replace(real_name, fake_name)
            # Also check for partial names (first and last name individually)
            parts = real_name.split()
            if len(parts) >= 2:
                for part in parts:
                    if len(part) > 3 and part in scrubbed:
                        scrubbed = scrubbed.replace(part, fake_name.split()[0])

    return scrubbed


def anonymize_ip_address(raw_ip):
    """Masks IP address into RFC 5737 TEST-NET documentation subnet (198.51.100.0/24)."""
    h = int(hashlib.md5(raw_ip.encode()).hexdigest()[:4], 16) % 250 + 1
    return f"198.51.100.{h}"


def execute_psql(container, db, sql):
    cmd = ["docker", "exec", container, "psql", "-U", "postgres", "-d", db, "-c", sql]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"psql execution failed: {res.stderr}")
    return res.stdout


def run_pipeline(host, port, user, password, prod_db, staging_db, container_name="postgres-anonymizer-db"):
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🛡️  Automated ETL Data Anonymization & PII Masking Pipeline{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

    start_time = time.perf_counter()

    # 1. Initialize schema in staging_db
    print(f"{CLR_YELLOW}▶ [1/5] Recreating clean relational schema in target 'staging_db'...{CLR_RESET}")
    init_staging_sql = """
    DROP TABLE IF EXISTS audit_trail CASCADE;
    DROP TABLE IF EXISTS order_items CASCADE;
    DROP TABLE IF EXISTS orders CASCADE;
    DROP TABLE IF EXISTS credit_cards CASCADE;
    DROP TABLE IF EXISTS customers CASCADE;

    CREATE TABLE customers (
        id INT PRIMARY KEY,
        full_name VARCHAR(100) NOT NULL,
        email VARCHAR(150) NOT NULL UNIQUE,
        phone_number VARCHAR(50) NOT NULL,
        ssn VARCHAR(20) NOT NULL,
        billing_address TEXT NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    );

    CREATE TABLE credit_cards (
        id SERIAL PRIMARY KEY,
        customer_id INT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
        card_number VARCHAR(30) NOT NULL,
        card_holder VARCHAR(100) NOT NULL,
        expiration VARCHAR(10) NOT NULL,
        cvv_hash VARCHAR(64) NOT NULL
    );

    CREATE TABLE orders (
        id INT PRIMARY KEY,
        customer_id INT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
        total_amount NUMERIC(10, 2) NOT NULL,
        shipping_address TEXT NOT NULL,
        customer_notes TEXT,
        status VARCHAR(50) NOT NULL DEFAULT 'COMPLETED',
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    );

    CREATE TABLE order_items (
        id INT PRIMARY KEY,
        order_id INT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        product_name VARCHAR(150) NOT NULL,
        quantity INT NOT NULL,
        unit_price NUMERIC(10, 2) NOT NULL
    );

    CREATE TABLE audit_trail (
        id SERIAL PRIMARY KEY,
        customer_email VARCHAR(150) NOT NULL,
        action VARCHAR(100) NOT NULL,
        ip_address VARCHAR(45) NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    );
    """
    execute_psql(container_name, staging_db, init_staging_sql)
    print(f"  [OK] Target schema initialized.")

    # 2. Extract raw records from production_db
    print(f"\n{CLR_YELLOW}▶ [2/5] Extracting raw records from '{prod_db}'...{CLR_RESET}")
    
    # Query customers
    cust_raw = subprocess.check_output([
        "docker", "exec", container_name, "psql", "-U", "postgres", "-d", prod_db, "-t", "-A", "-F", "||",
        "-c", "SELECT id, full_name, email, phone_number, ssn, billing_address, created_at FROM customers ORDER BY id;"
    ], text=True).strip().splitlines()

    # Query credit cards
    cards_raw = subprocess.check_output([
        "docker", "exec", container_name, "psql", "-U", "postgres", "-d", prod_db, "-t", "-A", "-F", "||",
        "-c", "SELECT id, customer_id, card_number, card_holder, expiration, cvv_hash FROM credit_cards ORDER BY id;"
    ], text=True).strip().splitlines()

    # Query orders
    orders_raw = subprocess.check_output([
        "docker", "exec", container_name, "psql", "-U", "postgres", "-d", prod_db, "-t", "-A", "-F", "||",
        "-c", "SELECT id, customer_id, total_amount, shipping_address, customer_notes, status, created_at FROM orders ORDER BY id;"
    ], text=True).strip().splitlines()

    # Query order items
    items_raw = subprocess.check_output([
        "docker", "exec", container_name, "psql", "-U", "postgres", "-d", prod_db, "-t", "-A", "-F", "||",
        "-c", "SELECT id, order_id, product_name, quantity, unit_price FROM order_items ORDER BY id;"
    ], text=True).strip().splitlines()

    # Query audit trail
    audit_raw = subprocess.check_output([
        "docker", "exec", container_name, "psql", "-U", "postgres", "-d", prod_db, "-t", "-A", "-F", "||",
        "-c", "SELECT id, customer_email, action, ip_address, created_at FROM audit_trail ORDER BY id;"
    ], text=True).strip().splitlines()

    print(f"  • Raw Customers   : {len(cust_raw)}")
    print(f"  • Raw Cards       : {len(cards_raw)}")
    print(f"  • Raw Orders      : {len(orders_raw)}")
    print(f"  • Raw Order Items : {len(items_raw)}")
    print(f"  • Raw Audit Events: {len(audit_raw)}")

    # 3. Transform & Anonymize Data with Referential Consistency
    print(f"\n{CLR_YELLOW}▶ [3/5] Executing PII Masking & Referential Mapping Transformations...{CLR_RESET}")
    
    customer_id_to_masked_name = {}
    customer_id_to_masked_email = {}
    customer_email_to_masked_email = {}
    real_name_to_masked_name = {}

    sanitized_customers = []
    for line in cust_raw:
        cid, name, email, phone, ssn, addr, created = line.split("||")
        cid_int = int(cid)
        masked_name = generate_synthetic_name(cid_int)
        masked_email = generate_synthetic_email(cid_int)
        masked_phone = generate_synthetic_phone(cid_int)
        masked_ssn = generate_synthetic_ssn(cid_int)
        masked_addr = generate_synthetic_address(cid_int)

        customer_id_to_masked_name[cid_int] = masked_name
        customer_id_to_masked_email[cid_int] = masked_email
        customer_email_to_masked_email[email] = masked_email
        real_name_to_masked_name[name] = masked_name

        sanitized_customers.append((cid_int, masked_name, masked_email, masked_phone, masked_ssn, masked_addr, created))

    sanitized_cards = []
    for line in cards_raw:
        card_id, cust_id, card_num, card_holder, exp, cvv = line.split("||")
        cust_id_int = int(cust_id)
        masked_card_num = mask_credit_card(card_num)
        masked_holder = customer_id_to_masked_name.get(cust_id_int, generate_synthetic_name(cust_id_int))
        salted_cvv = hashlib.sha256(f"SALT_{cust_id_int}".encode()).hexdigest()
        sanitized_cards.append((int(card_id), cust_id_int, masked_card_num, masked_holder, exp, salted_cvv))

    sanitized_orders = []
    for line in orders_raw:
        oid, cust_id, total, ship_addr, notes, status, created = line.split("||")
        cust_id_int = int(cust_id)
        masked_ship_addr = generate_synthetic_address(cust_id_int)
        scrubbed_notes = scrub_free_text(notes, real_name_map=real_name_to_masked_name)
        sanitized_orders.append((int(oid), cust_id_int, total, masked_ship_addr, scrubbed_notes, status, created))

    sanitized_audit = []
    for line in audit_raw:
        aid, email, action, ip, created = line.split("||")
        masked_email = customer_email_to_masked_email.get(email, generate_synthetic_email(999))
        masked_ip = anonymize_ip_address(ip)
        sanitized_audit.append((int(aid), masked_email, action, masked_ip, created))

    print(f"  [OK] PII masking complete. Referential mappings preserved for all {len(sanitized_customers)} customer identities.")

    # 4. Load Sanitized Data into staging_db
    print(f"\n{CLR_YELLOW}▶ [4/5] Loading sanitized dataset into '{staging_db}'...{CLR_RESET}")
    
    # Batch insert into staging_db
    insert_sql = []
    for c in sanitized_customers:
        insert_sql.append(f"INSERT INTO customers (id, full_name, email, phone_number, ssn, billing_address, created_at) VALUES ({c[0]}, '{c[1]}', '{c[2]}', '{c[3]}', '{c[4]}', '{c[5]}', '{c[6]}');")
    
    for cr in sanitized_cards:
        insert_sql.append(f"INSERT INTO credit_cards (id, customer_id, card_number, card_holder, expiration, cvv_hash) VALUES ({cr[0]}, {cr[1]}, '{cr[2]}', '{cr[3]}', '{cr[4]}', '{cr[5]}');")
    
    for o in sanitized_orders:
        clean_notes = o[4].replace("'", "''")
        insert_sql.append(f"INSERT INTO orders (id, customer_id, total_amount, shipping_address, customer_notes, status, created_at) VALUES ({o[0]}, {o[1]}, {o[2]}, '{o[3]}', '{clean_notes}', '{o[5]}', '{o[6]}');")

    for line in items_raw:
        iid, oid, pname, qty, price = line.split("||")
        insert_sql.append(f"INSERT INTO order_items (id, order_id, product_name, quantity, unit_price) VALUES ({iid}, {oid}, '{pname}', {qty}, {price});")

    for a in sanitized_audit:
        insert_sql.append(f"INSERT INTO audit_trail (id, customer_email, action, ip_address, created_at) VALUES ({a[0]}, '{a[1]}', '{a[2]}', '{a[3]}', '{a[4]}');")

    insert_script = "\n".join(insert_sql)
    execute_psql(container_name, staging_db, insert_script)

    # 5. Export Sanitized SQL Dump & Report
    print(f"\n{CLR_YELLOW}▶ [5/5] Exporting sanitized SQL dump & verification metadata...{CLR_RESET}")
    os.makedirs("dumps", exist_ok=True)
    os.makedirs("reports", exist_ok=True)

    dump_path = "dumps/sanitized_staging_dump.sql"
    dump_cmd = ["docker", "exec", container_name, "pg_dump", "-U", "postgres", "-d", staging_db, "--clean", "--if-exists", "--no-owner", "--no-privileges"]
    with open(dump_path, "w") as f:
        subprocess.run(dump_cmd, stdout=f, check=True)

    report_path = "reports/anonymization_report.json"
    report_data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "source_db": prod_db,
        "target_db": staging_db,
        "anonymized_tables": {
            "customers": len(sanitized_customers),
            "credit_cards": len(sanitized_cards),
            "orders": len(sanitized_orders),
            "order_items": len(items_raw),
            "audit_trail": len(sanitized_audit)
        },
        "masking_rules_applied": [
            "Deterministic Full Name Pseudonymization",
            "Example.org Email Redaction",
            "Safe 555-Area Phone Number Masking",
            "PCI-DSS Format Preserving Credit Card Masking (4111-XXXX-XXXX-1234)",
            "Unstructured Text Notes Regex Scrubbing",
            "RFC 5737 IP Address Anonymization",
            "Foreign Key Referential Integrity Preservation"
        ],
        "execution_duration_sec": round(time.perf_counter() - start_time, 3)
    }
    with open(report_path, "w") as f:
        json.dump(report_data, f, indent=2)

    print(f"  • Sanitized SQL Dump : {dump_path} ({os.path.getsize(dump_path)} bytes)")
    print(f"  • Audit Metadata     : {report_path}")

    print(f"\n{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_GREEN}{CLR_BOLD}🎉 SUCCESS: Data Anonymization ETL pipeline completed in {report_data['execution_duration_sec']}s!{CLR_RESET}")
    print(f"{CLR_BOLD}======================================================================{CLR_RESET}\n")


def main():
    parser = argparse.ArgumentParser(description="Automated Data Anonymization & PII Masking Pipeline.")
    parser.add_argument("--host", default=os.getenv("POSTGRES_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.getenv("POSTGRES_PORT", "5432")))
    parser.add_argument("--user", default=os.getenv("POSTGRES_USER", "postgres"))
    parser.add_argument("--password", default=os.getenv("POSTGRES_PASSWORD", "postgres"))
    parser.add_argument("--prod-db", default=os.getenv("PROD_DB", "production_db"))
    parser.add_argument("--staging-db", default=os.getenv("STAGING_DB", "staging_db"))

    args = parser.parse_args()
    run_pipeline(args.host, args.port, args.user, args.password, args.prod_db, args.staging_db)


if __name__ == "__main__":
    main()
