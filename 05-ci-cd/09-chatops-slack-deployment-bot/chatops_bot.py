#!/usr/bin/env python3
"""
ChatOps Slack Deployment Bot Server
===================================
A lightweight, secure, and production-patterned webhook server for Slack Slash Commands:
  - Cryptographic HMAC-SHA256 signature verification (X-Slack-Signature, X-Slack-Request-Timestamp)
  - Anti-replay timestamp skew validation (300s window)
  - Granular Role-Based Access Control (RBAC)
  - Commands: /deploy, /rollback, /status, /history, /help
  - Rich Slack Block Kit UI formatting
  - State tracking and audit logging
"""

import os
import sys
import json
import time
import hmac
import hashlib
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs

# Configuration
PORT = int(os.environ.get("PORT", "8088"))
HOST = os.environ.get("HOST", "0.0.0.0")
SLACK_SIGNING_SECRET = os.environ.get("SLACK_SIGNING_SECRET", "supersecret_slack_signing_token_123")
RBAC_FILE = os.environ.get("RBAC_FILE", os.path.join(os.path.dirname(__file__), "rbac_policy.json"))
STATE_FILE = os.environ.get("STATE_FILE", os.path.join(os.path.dirname(__file__), ".tmp_sandbox", "bot_state.json"))

# In-Memory State & Default Database
DEFAULT_SERVICES = ["order-service", "payment-service", "auth-service", "api-gateway"]
DEFAULT_ENVS = ["development", "staging", "production"]

ENV_ALIASES = {
    "dev": "development",
    "development": "development",
    "stage": "staging",
    "staging": "staging",
    "prod": "production",
    "production": "production"
}

def load_rbac():
    """Load RBAC policies from file or defaults."""
    if os.path.exists(RBAC_FILE):
        try:
            with open(RBAC_FILE, "r") as f:
                return json.load(f)
        except Exception as e:
            print(f"[WARN] Failed to load {RBAC_FILE}: {e}")
    return {
        "roles": {
            "admin": {
                "allowed_commands": ["deploy", "rollback", "status", "history", "help"],
                "allowed_environments": ["development", "dev", "staging", "stage", "production", "prod"]
            },
            "developer": {
                "allowed_commands": ["deploy", "status", "history", "help"],
                "allowed_environments": ["development", "dev", "staging", "stage"]
            },
            "viewer": {
                "allowed_commands": ["status", "history", "help"],
                "allowed_environments": []
            }
        },
        "user_role_mappings": {
            "bob_sre": "admin",
            "carol_lead": "admin",
            "alice_dev": "developer",
            "dave_qa": "developer",
            "viewer_dan": "viewer"
        },
        "supported_applications": DEFAULT_SERVICES,
        "supported_environments": DEFAULT_ENVS
    }

def init_state():
    """Initialize system state."""
    state = {
        "services": {},
        "history": []
    }
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    for svc in DEFAULT_SERVICES:
        state["services"][svc] = {}
        for env in DEFAULT_ENVS:
            state["services"][svc][env] = {
                "version": "v1.0.0",
                "previous_version": None,
                "status": "HEALTHY",
                "last_deployer": "system",
                "updated_at": now_iso
            }
    return state

# Global State Container
STATE = init_state()
RBAC = load_rbac()

def save_state():
    """Persist state to STATE_FILE if path directory exists."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(STATE, f, indent=2)
    except Exception as e:
        print(f"[WARN] Failed to save state to {STATE_FILE}: {e}")

def verify_slack_signature(raw_body: bytes, headers: dict) -> tuple[bool, str]:
    """
    Validates Slack request HMAC-SHA256 signature and timestamp freshness.
    Returns (is_valid, reason).
    """
    timestamp = headers.get("X-Slack-Request-Timestamp") or headers.get("x-slack-request-timestamp")
    signature = headers.get("X-Slack-Signature") or headers.get("x-slack-signature")

    if not timestamp or not signature:
        return False, "Missing X-Slack-Request-Timestamp or X-Slack-Signature header"

    # Anti-replay attack check: reject requests older than 300 seconds
    try:
        req_time = float(timestamp)
        now = time.time()
        if abs(now - req_time) > 300:
            return False, f"Request timestamp expired (Skew: {int(abs(now - req_time))}s > 300s max)"
    except ValueError:
        return False, "Invalid timestamp format"

    # Compute expected signature
    sig_basestring = f"v0:{timestamp}:".encode("utf-8") + raw_body
    computed_hash = hmac.new(
        SLACK_SIGNING_SECRET.encode("utf-8"),
        sig_basestring,
        hashlib.sha256
    ).hexdigest()
    expected_sig = f"v0={computed_hash}"

    if not hmac.compare_digest(expected_sig, signature):
        return False, "Signature verification failed (HMAC mismatch)"

    return True, "Valid"

def check_rbac_permission(user_name: str, command: str, target_env: str = None) -> tuple[bool, str, str]:
    """
    Validates if user_name is authorized to execute command on target_env.
    Returns (is_authorized, role_name, denial_reason).
    """
    user_mappings = RBAC.get("user_role_mappings", {})
    roles = RBAC.get("roles", {})

    role_name = user_mappings.get(user_name)
    if not role_name:
        return False, "anonymous", f"User '@{user_name}' is not registered in the ChatOps authorization catalog."

    role_config = roles.get(role_name)
    if not role_config:
        return False, role_name, f"Role '{role_name}' has no defined permission schema."

    # Check allowed commands
    allowed_cmds = role_config.get("allowed_commands", [])
    cmd_clean = command.lstrip("/")
    if cmd_clean not in allowed_cmds:
        return False, role_name, f"Role '{role_name}' is not permitted to execute command '/{cmd_clean}'."

    # Check environment permission for deploy/rollback
    if cmd_clean in ["deploy", "rollback"] and target_env:
        allowed_envs = role_config.get("allowed_environments", [])
        if target_env not in allowed_envs and ENV_ALIASES.get(target_env) not in allowed_envs:
            return False, role_name, (
                f"Role '{role_name}' is not allowed to {cmd_clean} to environment '{target_env}'. "
                f"Allowed environments: {', '.join(allowed_envs) if allowed_envs else 'None (Read-Only)'}."
            )

    return True, role_name, "Authorized"

# ==============================================================================
# Block Kit Formatting Helpers
# ==============================================================================

def make_error_block(title: str, message: str, user: str = None) -> dict:
    """Format an error message with Slack Block Kit."""
    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"⛔ {title}", "emoji": True}
        },
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": message}
        }
    ]
    if user:
        blocks.append({
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": f"Requested by: *@{{{user}}}* | *DevOps ChatOps Gateway*"}]
        })
    return {
        "response_type": "ephemeral",
        "blocks": blocks,
        "text": f"⛔ {title}: {message}"
    }

def make_help_block(user_name: str, role_name: str) -> dict:
    """Format help documentation with Slack Block Kit."""
    role_info = RBAC.get("roles", {}).get(role_name, {})
    allowed_cmds = ", ".join(f"`/{c}`" for c in role_info.get("allowed_commands", []))
    allowed_envs = ", ".join(f"`{e}`" for e in role_info.get("allowed_environments", []))

    return {
        "response_type": "ephemeral",
        "text": "ChatOps Deployment Bot Help & Command Catalog",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": "🤖 ChatOps Deployment Bot Help", "emoji": True}
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"Hello *@{{{user_name}}}*! You are authenticated with role: *`{role_name.upper()}`*.\n\n"
                        f"• *Permitted Commands*: {allowed_cmds}\n"
                        f"• *Deployable Environments*: {allowed_envs or '_None (Read-Only)_'}"
                    )
                }
            },
            {"type": "divider"},
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        "*Available Slash Commands:*\n"
                        "• `/deploy <app> <env> [version]` - Trigger automated deployment (e.g. `/deploy order-service staging v1.2.0`)\n"
                        "• `/rollback <app> [env]` - Instant rollback to previous release (e.g. `/rollback order-service production`)\n"
                        "• `/status [app] [env]` - Query real-time health and active versions (e.g. `/status` or `/status payment-service prod`)\n"
                        "• `/history <app>` - View chronological deployment audit log (e.g. `/history order-service`)\n"
                        "• `/help` - Show this interactive command guide"
                    )
                }
            },
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": "🔒 *RBAC Policy Active* | Target clusters: `staging`, `production`"}]
            }
        ]
    }

def make_deploy_block(app: str, env: str, version: str, prev_version: str, user: str, status: str = "SUCCESS") -> dict:
    """Format deployment result with Slack Block Kit."""
    now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    badge = "🚀" if status == "SUCCESS" else "⚠️"

    return {
        "response_type": "in_channel",
        "text": f"{badge} Deployment {status}: {app} -> {env} ({version})",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": f"{badge} Deployment Triggered: {app}", "emoji": True}
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*Application:*\n`{app}`"},
                    {"type": "mrkdwn", "text": f"*Environment:*\n`{env.upper()}`"},
                    {"type": "mrkdwn", "text": f"*Target Version:*\n`{version}`"},
                    {"type": "mrkdwn", "text": f"*Previous Version:*\n`{prev_version or 'Initial'}`"},
                    {"type": "mrkdwn", "text": f"*Triggered By:*\n`@{user}`"},
                    {"type": "mrkdwn", "text": f"*Pipeline Status:*\n*✅ {status}*"}
                ]
            },
            {
                "type": "context",
                "elements": [
                    {"type": "mrkdwn", "text": f"🕒 *Dispatched at*: {now_str} | 📦 *Artifact*: `docker.io/enterprise/{app}:{version}`"}
                ]
            }
        ]
    }

def make_rollback_block(app: str, env: str, from_version: str, to_version: str, user: str) -> dict:
    """Format rollback result with Slack Block Kit."""
    now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    return {
        "response_type": "in_channel",
        "text": f"⏪ Rollback Completed: {app} in {env} reverted from {from_version} to {to_version}",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": f"⏪ Rollback Executed: {app}", "emoji": True}
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*Application:*\n`{app}`"},
                    {"type": "mrkdwn", "text": f"*Environment:*\n`{env.upper()}`"},
                    {"type": "mrkdwn", "text": f"*Reverted From:*\n`{from_version}`"},
                    {"type": "mrkdwn", "text": f"*Reverted To:*\n`{to_version}`"},
                    {"type": "mrkdwn", "text": f"*Authorized SRE:*\n`@{user}`"},
                    {"type": "mrkdwn", "text": "*Rollback Status:*\n*✅ RESTORED*"}
                ]
            },
            {
                "type": "context",
                "elements": [
                    {"type": "mrkdwn", "text": f"🕒 *Action Completed*: {now_str} | 🛡️ *Zero-Downtime Safe Reversion*"}
                ]
            }
        ]
    }

def make_status_block(services_to_show: dict, filter_app: str = None, filter_env: str = None) -> dict:
    """Format system status table with Slack Block Kit."""
    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "📊 Microservices Fleet Health & Deployment Status", "emoji": True}
        }
    ]

    for svc_name, envs in services_to_show.items():
        if filter_app and svc_name != filter_app:
            continue
        fields = []
        for env_name, info in envs.items():
            if filter_env and env_name != filter_env:
                continue
            status_icon = "🟢" if info.get("status") == "HEALTHY" else "🟡"
            fields.append({
                "type": "mrkdwn",
                "text": (
                    f"*{env_name.upper()}* {status_icon}\n"
                    f"• Version: `{info.get('version', 'unknown')}`\n"
                    f"• Deployer: `@{info.get('last_deployer', 'system')}`\n"
                    f"• Updated: _{info.get('updated_at', 'N/A')}_"
                )
            })
        if fields:
            blocks.append({"type": "divider"})
            blocks.append({
                "type": "section",
                "text": {"type": "mrkdwn", "text": f"*Service: `{svc_name}`*"},
                "fields": fields
            })

    blocks.append({
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": "💡 Tip: Use `/deploy <app> <env>` to update or `/rollback <app>` to revert."}]
    })

    return {
        "response_type": "ephemeral",
        "text": "Microservices Fleet Status",
        "blocks": blocks
    }

def make_history_block(app: str, history_list: list) -> dict:
    """Format audit history with Slack Block Kit."""
    filtered = [h for h in history_list if h.get("app") == app]
    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"📜 Deployment History: {app}", "emoji": True}
        }
    ]

    if not filtered:
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"No deployment history found for application `{app}`."}
        })
    else:
        # Show top 5 latest
        recent = list(reversed(filtered))[:5]
        for idx, item in enumerate(recent, 1):
            action_type = item.get("action", "DEPLOY")
            icon = "🚀" if action_type == "DEPLOY" else "⏪"
            blocks.append({
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"*{idx}. {icon} {action_type} -> `{item.get('env', '').upper()}`* | Status: *{item.get('status', 'SUCCESS')}*\n"
                        f"• Version: `{item.get('version')}` (From: `{item.get('previous_version') or 'Initial'}`)\n"
                        f"• Author: `@{item.get('user')}` | Timestamp: _{item.get('timestamp')}_"
                    )
                }
            })

    return {
        "response_type": "ephemeral",
        "text": f"Deployment History: {app}",
        "blocks": blocks
    }

# ==============================================================================
# Slash Command Router
# ==============================================================================

def handle_slash_command(params: dict) -> tuple[int, dict]:
    """
    Parses and executes Slack slash commands with RBAC verification.
    Returns (status_code, response_json).
    """
    raw_cmd = params.get("command", [""])[0].strip()
    text = params.get("text", [""])[0].strip()
    user_name = params.get("user_name", [""])[0].strip()
    tokens = text.split() if text else []

    cmd = raw_cmd.lstrip("/")
    if not cmd and tokens:
        cmd = tokens[0].lstrip("/")
        tokens = tokens[1:]

    # 1. Handle /help
    if cmd in ["help", ""]:
        _, role, _ = check_rbac_permission(user_name, "help")
        return 200, make_help_block(user_name, role)

    # 2. Handle /status [app] [env]
    if cmd == "status":
        is_auth, role, reason = check_rbac_permission(user_name, "status")
        if not is_auth:
            return 200, make_error_block("Access Denied", reason, user_name)

        target_app = tokens[0] if len(tokens) >= 1 else None
        target_env_raw = tokens[1] if len(tokens) >= 2 else None
        target_env = ENV_ALIASES.get(target_env_raw, target_env_raw) if target_env_raw else None

        if target_app and target_app not in STATE["services"]:
            return 200, make_error_block(
                "Invalid Application",
                f"Unknown application `{target_app}`. Supported: {', '.join(STATE['services'].keys())}.",
                user_name
            )

        return 200, make_status_block(STATE["services"], target_app, target_env)

    # 3. Handle /history <app>
    if cmd == "history":
        is_auth, role, reason = check_rbac_permission(user_name, "history")
        if not is_auth:
            return 200, make_error_block("Access Denied", reason, user_name)

        if not tokens:
            return 200, make_error_block(
                "Missing Argument",
                "Usage: `/history <app>` (e.g. `/history order-service`).",
                user_name
            )
        target_app = tokens[0]
        if target_app not in STATE["services"]:
            return 200, make_error_block(
                "Invalid Application",
                f"Unknown application `{target_app}`. Supported: {', '.join(STATE['services'].keys())}.",
                user_name
            )
        return 200, make_history_block(target_app, STATE["history"])

    # 4. Handle /deploy <app> <env> [version]
    if cmd == "deploy":
        if len(tokens) < 2:
            return 200, make_error_block(
                "Invalid Syntax",
                "Usage: `/deploy <app> <env> [version]`\nExample: `/deploy order-service staging v1.2.0`",
                user_name
            )

        app = tokens[0]
        env_raw = tokens[1].lower()
        env = ENV_ALIASES.get(env_raw, env_raw)
        version = tokens[2] if len(tokens) >= 3 else f"v1.{len(STATE['history']) + 1}.0"

        # Check valid application
        if app not in STATE["services"]:
            return 200, make_error_block(
                "Unknown Application",
                f"Application `{app}` does not exist. Available: {', '.join(STATE['services'].keys())}.",
                user_name
            )

        # Check valid environment
        if env not in DEFAULT_ENVS:
            return 200, make_error_block(
                "Unknown Environment",
                f"Environment `{env_raw}` is invalid. Supported: `development`, `staging`, `production`.",
                user_name
            )

        # Check RBAC permissions
        is_auth, role, reason = check_rbac_permission(user_name, "deploy", env)
        if not is_auth:
            return 200, make_error_block("Deployment Authorization Denied", reason, user_name)

        # Execute deployment state transition
        prev_version = STATE["services"][app][env]["version"]
        now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

        STATE["services"][app][env].update({
            "version": version,
            "previous_version": prev_version,
            "status": "HEALTHY",
            "last_deployer": user_name,
            "updated_at": now_str
        })

        STATE["history"].append({
            "id": len(STATE["history"]) + 1,
            "action": "DEPLOY",
            "app": app,
            "env": env,
            "version": version,
            "previous_version": prev_version,
            "user": user_name,
            "status": "SUCCESS",
            "timestamp": now_str
        })
        save_state()

        return 200, make_deploy_block(app, env, version, prev_version, user_name, "SUCCESS")

    # 5. Handle /rollback <app> [env]
    if cmd == "rollback":
        if not tokens:
            return 200, make_error_block(
                "Invalid Syntax",
                "Usage: `/rollback <app> [env]`\nExample: `/rollback order-service production`",
                user_name
            )

        app = tokens[0]
        env_raw = tokens[1].lower() if len(tokens) >= 2 else "production"
        env = ENV_ALIASES.get(env_raw, env_raw)

        if app not in STATE["services"]:
            return 200, make_error_block("Unknown Application", f"Application `{app}` not found.", user_name)
        if env not in DEFAULT_ENVS:
            return 200, make_error_block("Unknown Environment", f"Environment `{env_raw}` is invalid.", user_name)

        is_auth, role, reason = check_rbac_permission(user_name, "rollback", env)
        if not is_auth:
            return 200, make_error_block("Rollback Authorization Denied", reason, user_name)

        current_info = STATE["services"][app][env]
        current_ver = current_info.get("version")
        prev_ver = current_info.get("previous_version")

        if not prev_ver:
            return 200, make_error_block(
                "Rollback Target Unavailable",
                f"No previous release recorded for `{app}` in `{env}`. Current version `{current_ver}` is initial baseline.",
                user_name
            )

        now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

        # Swap versions
        STATE["services"][app][env].update({
            "version": prev_ver,
            "previous_version": current_ver,
            "status": "HEALTHY",
            "last_deployer": user_name,
            "updated_at": now_str
        })

        STATE["history"].append({
            "id": len(STATE["history"]) + 1,
            "action": "ROLLBACK",
            "app": app,
            "env": env,
            "version": prev_ver,
            "previous_version": current_ver,
            "user": user_name,
            "status": "SUCCESS",
            "timestamp": now_str
        })
        save_state()

        return 200, make_rollback_block(app, env, current_ver, prev_ver, user_name)

    # Unknown command
    return 200, make_error_block(
        "Unknown Command",
        f"Command `/{cmd}` is unrecognized. Type `/help` for available commands.",
        user_name
    )

# ==============================================================================
# HTTP Request Handler
# ==============================================================================

class ChatOpsRequestHandler(BaseHTTPRequestHandler):
    """HTTP Server handling Slack Webhook requests."""

    def log_message(self, format, *args):
        # Override to format cleanly
        print(f"[HTTP] {self.address_string()} - {args[0]} {args[1]}")

    def send_json_response(self, status_code: int, data: dict):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ["/health", "/livez"]:
            self.send_json_response(200, {
                "status": "UP",
                "service": "chatops-slack-bot",
                "version": "1.0.0",
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "registered_services": list(STATE["services"].keys()),
                "supported_roles": list(RBAC.get("roles", {}).keys())
            })
        elif self.path == "/api/state":
            self.send_json_response(200, STATE)
        else:
            self.send_json_response(404, {"error": "Not Found"})

    def do_POST(self):
        if self.path not in ["/slack/commands", "/webhook"]:
            return self.send_json_response(404, {"error": "Endpoint Not Found"})

        # Read raw request body
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(content_length)
        except Exception as e:
            return self.send_json_response(400, {"error": f"Failed to read body: {e}"})

        # 1. Cryptographic HMAC Signature Verification
        is_valid, reason = verify_slack_signature(raw_body, dict(self.headers))
        if not is_valid:
            print(f"[SECURITY ALERT] Rejected request: {reason}")
            return self.send_json_response(401, {
                "error": "Unauthorized",
                "message": reason
            })

        # 2. Parse URL-Encoded Form Data
        try:
            body_str = raw_body.decode("utf-8")
            params = parse_qs(body_str)
        except Exception as e:
            return self.send_json_response(400, {"error": f"Invalid form payload: {e}"})

        # 3. Route Slash Command
        status_code, response_data = handle_slash_command(params)
        self.send_json_response(status_code, response_data)

def run_server():
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, ChatOpsRequestHandler)
    print(f"======================================================================")
    print(f"  🤖 ChatOps Slack Deployment Bot Online at http://{HOST}:{PORT}")
    print(f"  • Health Endpoint:   http://{HOST}:{PORT}/health")
    print(f"  • Webhook Endpoint:  http://{HOST}:{PORT}/slack/commands")
    print(f"  • Signing Secret:    [CONFIGURED - Length: {len(SLACK_SIGNING_SECRET)} chars]")
    print(f"======================================================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[INFO] Shutting down ChatOps bot server...")
        httpd.server_close()
        sys.exit(0)

if __name__ == "__main__":
    run_server()
