#!/usr/bin/env bash
# ==============================================================================
# runbooks/flush_cache.sh - In-Memory Cache Flush & Eviction Runbook
# ==============================================================================
# Remediates critical memory pressure / Out-Of-Memory (OOM) conditions.
# ==============================================================================

set -euo pipefail

CACHE_NAME="${1:-redis-cache}"
TARGET_URL="${TARGET_HOST:-http://localhost:9000}"

echo "======================================================================"
echo "  🛠️ RUNBOOK: FLUSH CACHE & EVICT KEYS [$CACHE_NAME]"
echo "======================================================================"
echo "Target host: $TARGET_URL"
echo "Timestamp:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# 1. Inspect memory usage before flush
echo "▶ [Step 1/3] Checking memory usage before eviction..."
BEFORE_STATE=$(curl -s --fail "$TARGET_URL/cache/status" || echo '{"status":"UNREACHABLE"}')
echo "  Current state: $BEFORE_STATE"

# 2. Trigger cache eviction
echo "▶ [Step 2/3] Sending cache eviction command..."
FLUSH_RESP=$(curl -s --fail -X POST "$TARGET_URL/cache/flush")
echo "  Flush response: $FLUSH_RESP"

# 3. Post-flush verification
echo "▶ [Step 3/3] Verifying memory reduction and cache health..."
sleep 1
AFTER_STATE=$(curl -s --fail "$TARGET_URL/cache/status")
echo "  Verified state: $AFTER_STATE"

STATUS=$(echo "$AFTER_STATE" | grep -o '"status": *"[^"]*"' | cut -d'"' -f4)
if [ "$STATUS" = "HEALTHY" ]; then
    echo "  [SUCCESS] $CACHE_NAME memory pressure successfully alleviated."
    exit 0
else
    echo "  [ERROR] $CACHE_NAME remains in degraded state (Status: $STATUS)."
    exit 1
fi
