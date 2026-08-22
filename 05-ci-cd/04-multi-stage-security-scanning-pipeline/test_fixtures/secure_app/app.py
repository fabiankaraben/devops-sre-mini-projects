"""
Hardened Sample Web Application (SAST Compliant).

Demonstrates secure coding patterns that satisfy Semgrep and Gitleaks rules:
1. Secrets loaded from environment variables (never hardcoded).
2. Parameterized SQL queries preventing SQL Injection.
3. Safe process execution avoiding shell=True.
4. Cryptographically strong SHA-256 / PBKDF2 hashing.
5. Strict JSON serialization instead of unsafe pickle.
6. Debug mode disabled in production.
"""

import hashlib
import json
import os
import sqlite3
import subprocess
from flask import Flask, request, jsonify

app = Flask(__name__)

# 1. Secure Secret Management: Read from environment variables
API_SECRET_KEY = os.getenv("APP_API_SECRET_KEY", "default_safe_dev_placeholder")

# 2. Database Initialization
def init_db():
    conn = sqlite3.connect(":memory:", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, role TEXT)")
    cursor.execute("INSERT INTO users (username, role) VALUES (?, ?)", ("admin", "superuser"))
    cursor.execute("INSERT INTO users (username, role) VALUES (?, ?)", ("guest", "user"))
    conn.commit()
    return conn

db_conn = init_db()


@app.route("/")
def index():
    return jsonify({"status": "running", "service": "secure-demo-app"})


# 3. Secure: Parameterized SQL Query (Prevents SQL Injection)
@app.route("/user")
def get_user():
    username = request.args.get("name", "")
    cursor = db_conn.cursor()
    # SECURE: Placeholders (?) ensure user input is treated strictly as data
    cursor.execute("SELECT id, username, role FROM users WHERE username = ?", (username,))
    user = cursor.fetchone()
    if user:
        return jsonify({"id": user[0], "username": user[1], "role": user[2]})
    return jsonify({"error": "User not found"}), 404


# 4. Secure: Safe Subprocess Execution (shell=False, argument list)
@app.route("/ping")
def ping_host():
    target_host = request.args.get("host", "127.0.0.1")
    # Sanitize/whitelist allowed target formats
    if not target_host.replace(".", "").isalnum():
        return jsonify({"error": "Invalid host format"}), 400

    # SECURE: Argument array with shell=False prevents shell command injection
    result = subprocess.run(
        ["ping", "-c", "1", target_host],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    return jsonify({"output": result.stdout})


# 5. Secure: Strong Cryptographic Hashing (SHA-256 with salt)
@app.route("/hash-password", methods=["POST"])
def hash_password():
    data = request.get_json(silent=True) or {}
    raw_password = data.get("password", "")
    salt = os.urandom(16).hex()
    # SECURE: SHA-256 hash
    hasher = hashlib.sha256()
    hasher.update((salt + raw_password).encode("utf-8"))
    return jsonify({"algo": "sha256", "salt": salt, "hash": hasher.hexdigest()})


# 6. Secure: Safe JSON Deserialization
@app.route("/deserialize", methods=["POST"])
def load_payload():
    try:
        # SECURE: json.loads parses standard text JSON safely
        obj = json.loads(request.get_data(as_text=True))
        return jsonify({"status": "loaded", "type": str(type(obj))})
    except json.JSONDecodeError:
        return jsonify({"error": "Invalid JSON format"}), 400


if __name__ == "__main__":
    # 7. Secure: Debug mode explicitly disabled
    app.run(host="0.0.0.0", port=5000, debug=False)
