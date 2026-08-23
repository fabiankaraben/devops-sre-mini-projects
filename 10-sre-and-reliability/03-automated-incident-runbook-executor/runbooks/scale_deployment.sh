#!/usr/bin/env bash
# ==============================================================================
# runbooks/scale_deployment.sh - Dynamic Deployment Scaling Runbook
# ==============================================================================
# Scales worker replica pools during queue backlog overflow incidents.
# ==============================================================================

set -euo pipefail

DEPLOYMENT_NAME="${1:-order-queue}"
TARGET_REPLICAS="${2:-6}"
TARGET_URL="${TARGET_HOST:-http://localhost:9000}"

echo "======================================================================"
echo "  🛠️ RUNBOOK: SCALE DEPLOYMENT [$DEPLOYMENT_NAME -> $TARGET_REPLICAS replicas]"
echo "======================================================================"
echo "Target host: $TARGET_URL"
echo "Timestamp:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# 1. Inspect queue backlog before scaling
echo "▶ [Step 1/3] Checking queue backlog before scaling..."
BEFORE_STATE=$(curl -s --fail "$TARGET_URL/queue/status" || echo '{"status":"UNREACHABLE"}')
echo "  Current state: $BEFORE_STATE"

# 2. Trigger scaling command
echo "▶ [Step 2/3] Scaling deployment replicas to $TARGET_REPLICAS..."
SCALE_RESP=$(curl -s --fail -X POST "$TARGET_URL/queue/scale?replicas=$TARGET_REPLICAS")
echo "  Scale response: $SCALE_RESP"

# 3. Verify replica state
echo "▶ [Step 3/3] Verifying scaled worker capacity..."
sleep 1
AFTER_STATE=$(curl -s --fail "$TARGET_URL/queue/status")
echo "  Verified state: $AFTER_STATE"

REPLICAS=$(echo "$AFTER_STATE" | grep -o '"replica_count": *[0-9]*' | grep -o '[0-9]*')
if [ "$REPLICAS" -ge "$TARGET_REPLICAS" ]; then
    echo "  [SUCCESS] $DEPLOYMENT_NAME scaled successfully to $REPLICAS replicas."
    exit 0
else
    echo "  [ERROR] $DEPLOYMENT_NAME scaling failed (Current: $REPLICAS, Target: $TARGET_REPLICAS)."
    exit 1
fi
