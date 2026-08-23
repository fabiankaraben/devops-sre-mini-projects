#!/usr/bin/env bash
# ==============================================================================
# runbooks/drain_queue.sh - Dead-Letter Queue (DLQ) Reprocessing Runbook
# ==============================================================================
# Triggers automated replay and draining of dead-letter queues.
# ==============================================================================

set -euo pipefail

QUEUE_NAME="${1:-order-queue}"
TARGET_URL="${TARGET_HOST:-http://localhost:9000}"

echo "======================================================================"
echo "  🛠️ RUNBOOK: DRAIN DEAD-LETTER QUEUE [$QUEUE_NAME]"
echo "======================================================================"
echo "Target host: $TARGET_URL"
echo "Timestamp:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# 1. Inspect DLQ message count
echo "▶ [Step 1/3] Checking dead-letter count before draining..."
BEFORE_STATE=$(curl -s --fail "$TARGET_URL/queue/status" || echo '{"status":"UNREACHABLE"}')
echo "  Current state: $BEFORE_STATE"

# 2. Trigger DLQ drain command
echo "▶ [Step 2/3] Draining and replaying dead-letter messages..."
DRAIN_RESP=$(curl -s --fail -X POST "$TARGET_URL/queue/drain")
echo "  Drain response: $DRAIN_RESP"

# 3. Verify DLQ is empty
echo "▶ [Step 3/3] Verifying dead-letter count is zero..."
sleep 1
AFTER_STATE=$(curl -s --fail "$TARGET_URL/queue/status")
echo "  Verified state: $AFTER_STATE"

DLQ_COUNT=$(echo "$AFTER_STATE" | grep -o '"dead_letter_count": *[0-9]*' | grep -o '[0-9]*')
if [ "$DLQ_COUNT" -eq 0 ]; then
    echo "  [SUCCESS] $QUEUE_NAME dead-letter queue drained completely."
    exit 0
else
    echo "  [ERROR] $QUEUE_NAME still has $DLQ_COUNT dead-letter messages remaining."
    exit 1
fi
