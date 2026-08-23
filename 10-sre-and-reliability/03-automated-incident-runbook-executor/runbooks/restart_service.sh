#!/usr/bin/env bash
# ==============================================================================
# runbooks/restart_service.sh - Automated Service Restart Runbook
# ==============================================================================
# Remediates hung worker pools, deadlocked processes, or failed healthchecks.
# ==============================================================================

set -euo pipefail

SERVICE_NAME="${1:-worker-service}"
TARGET_URL="${TARGET_HOST:-http://localhost:9000}"

echo "======================================================================"
echo "  🛠️ RUNBOOK: RESTART SERVICE [$SERVICE_NAME]"
echo "======================================================================"
echo "Target host: $TARGET_URL"
echo "Timestamp:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# 1. Inspect initial state
echo "▶ [Step 1/3] Probing service state before restart..."
BEFORE_STATE=$(curl -s --fail "$TARGET_URL/worker/status" || echo '{"status":"UNREACHABLE"}')
echo "  Current state: $BEFORE_STATE"

# 2. Trigger Graceful Restart Command
echo "▶ [Step 2/3] Executing service restart signal..."
RESTART_RESP=$(curl -s --fail -X POST "$TARGET_URL/worker/restart")
echo "  Restart response: $RESTART_RESP"

# 3. Post-Remediation Verification Healthcheck
echo "▶ [Step 3/3] Verifying service health post-restart..."
sleep 1
AFTER_STATE=$(curl -s --fail "$TARGET_URL/worker/status")
echo "  Verified state: $AFTER_STATE"

STATUS=$(echo "$AFTER_STATE" | grep -o '"status": *"[^"]*"' | cut -d'"' -f4)
if [ "$STATUS" = "HEALTHY" ]; then
    echo "  [SUCCESS] $SERVICE_NAME successfully restarted and operating in HEALTHY state."
    exit 0
else
    echo "  [ERROR] $SERVICE_NAME failed to recover (Status: $STATUS)."
    exit 1
fi
