#!/bin/bash
set -euo pipefail

LOG_FILE="/srv/containers/vikunja/cleanup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

DELETED_FILE=$(mktemp)
trap 'rm -f "$DELETED_FILE"' EXIT

if ! command -v jq &>/dev/null; then
    echo "[$(date)] jq not found. Installing..."
    apt-get update -qq && apt-get install -y -qq jq
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date)] ERROR: $ENV_FILE not found" >&2
    exit 1
fi
source "$ENV_FILE"

if [ -z "${API_TOKEN:-}" ]; then
    echo "[$(date)] ERROR: API_TOKEN not set in $ENV_FILE" >&2
    exit 1
fi

BASE="http://10.0.10.10:3456/api/v1"
AUTH_HDR="Authorization: Bearer $API_TOKEN"

echo "[$(date)] Fetching all done tasks..."
all_tasks=$(curl -sf -H "$AUTH_HDR" "${BASE}/tasks?filter=done%3Dtrue") || {
    echo "[$(date)] ERROR: Failed to fetch tasks" >&2
    exit 1
}

now_epoch=$(date +%s)
cutoff_epoch=$((now_epoch - 10 * 24 * 60 * 60))

echo "$all_tasks" | jq -c '.[] | select(.done_at != null)' | while read -r task; do
    tid=$(echo "$task" | jq -r '.id')
    done_at=$(echo "$task" | jq -r '.done_at')

    done_epoch=$(date -d "$done_at" +%s 2>/dev/null) || {
        echo "[$(date)] WARNING: Could not parse done_at for task $tid: $done_at" >&2
        continue
    }

    if [ "$done_epoch" -le "$cutoff_epoch" ]; then
        echo "[$(date)] Deleting task $tid (done: $done_at)"
        if curl -sf -X DELETE -H "$AUTH_HDR" "$BASE/tasks/$tid" > /dev/null; then
            echo "$tid" >> "$DELETED_FILE"
        else
            echo "[$(date)] WARNING: Failed to delete task $tid" >&2
        fi
    fi
done

deleted=$(wc -l < "$DELETED_FILE" 2>/dev/null || echo 0)
echo "[$(date)] Cleanup complete. Deleted $deleted task(s)."
