"""
Sample Vulnerable Web Application (for SAST demonstration).

WARNING: This file contains intentional security vulnerabilities designed
strictly for testing and educational purposes. Do NOT use in production.
"""

import hashlib
import os
import pickle
import sqlite3
import subprocess
from flask import Flask, request, jsonify

app = Flask(__name__)

# 1. Hardcoded Secrets (Detected by Gitleaks and Semgrep)
DUMMY_SECRET_KEY = "AKIAIOSFODNN7EXAMPLE_SECRET_KEY_12345"
ADMIN_PASSWORD_HASH = "5ebe2294ecd0e0f08eab7690d2a6ee69"  # MD5 weak hash

# 2. Insecure Database Connection & Initialization
def init_db():
    conn = sqlite3.connect(":memory:")
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, role TEXT)")
    cursor.execute("INSERT INTO users (username, role) VALUES ('admin', 'superuser')")
    cursor.execute("INSERT INTO users (username, role) VALUES ('guest', 'user')")
    conn.commit()
    return conn

db_conn = init_db()


@app.route("/")
def index():
    return jsonify({"status": "running", "service": "vulnerable-demo-app"})


# 3. Vulnerability: SQL Injection (Direct string formatting in SQL query)
@app.route("/user")
def get_user():
    username = request.args.get("name", "")
    cursor = db_conn.cursor()
    # INSECURE: Formatted SQL query allows SQL Injection (' OR '1'='1)
    query = f"SELECT id, username, role FROM users WHERE username = '{username}'"
    cursor.execute(query)
    user = cursor.fetchone()
    if user:
        return jsonify({"id": user[0], "username": user[1], "role": user[2]})
    return jsonify({"error": "User not found"}), 404


# 4. Vulnerability: Command Injection (Unsanitized input passed to shell)
@app.route("/ping")
def ping_host():
    target_host = request.args.get("host", "127.0.0.1")
    # INSECURE: shell=True with unvalidated user input enables remote command injection
    cmd = f"ping -c 1 {target_host}"
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout, stderr = proc.communicate()
    return jsonify({"output": stdout.decode("utf-8", errors="ignore")})


# 5. Vulnerability: Weak Cryptographic Hash (MD5)
@app.route("/hash-password", methods=["POST"])
def hash_password():
    data = request.get_json(silent=True) or {}
    raw_password = data.get("password", "")
    # INSECURE: MD5 is cryptographically broken and vulnerable to collision attacks
    hashed = hashlib.md5(raw_password.encode("utf-8")).hexdigest()
    return jsonify({"algo": "md5", "hash": hashed})


# 6. Vulnerability: Insecure Deserialization (pickle)
@app.route("/deserialize", methods=["POST"])
def load_payload():
    payload = request.data
    # INSECURE: pickle.loads on untrusted binary input allows arbitrary code execution
    obj = pickle.loads(payload)
    return jsonify({"status": "loaded", "type": str(type(obj))})


if __name__ == "__main__":
    # 7. Vulnerability: Debug mode enabled in production
    app.run(host="0.0.0.0", port=5000, debug=True)
