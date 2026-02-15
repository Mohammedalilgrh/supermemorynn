#!/bin/sh
set -eu
umask 077

MONITOR_INTERVAL="${MONITOR_INTERVAL:-120}"
FORCE_RESTORE="${FORCE_RESTORE:-false}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

mkdir -p "$N8N_DIR" "$WORK"

echo "=== n8n Startup ==="
echo "Time: $(date -u)"

# ───────────────────────────────────
# STEP 1: Restore (if no local DB)
# ───────────────────────────────────
if [ "$FORCE_RESTORE" = "true" ] || [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "=== Attempting Restore ==="
  if /scripts/restore.sh; then
    echo "=== Restore Successful ==="
  else
    echo "=== No backup found or restore failed - starting fresh ==="
  fi
else
  echo "=== Local database exists - skipping restore ==="
fi

# ───────────────────────────────────
# STEP 2: Backup monitor (background)
# ───────────────────────────────────
(
  # Wait for n8n to fully start
  sleep 60
  echo "[backup-monitor] Started (interval: ${MONITOR_INTERVAL}s)"
  while true; do
    /scripts/multi_repo_backup.sh 2>&1 | while IFS= read -r line; do
      echo "[backup] $line"
    done || true
    sleep "$MONITOR_INTERVAL"
  done
) &

# ───────────────────────────────────
# STEP 3: Start n8n
# ───────────────────────────────────
echo "=== Starting n8n ==="
exec n8n start
