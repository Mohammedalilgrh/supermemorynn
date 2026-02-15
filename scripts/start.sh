#!/bin/sh
set -eu
umask 077

MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
FORCE_RESTORE="${FORCE_RESTORE:-false}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

mkdir -p "$N8N_DIR" "$WORK"

# ───────────────────────────────────
# STEP 0: Git global config (مهم!)
# ───────────────────────────────────
git config --global user.email "backup@local" 2>/dev/null || true
git config --global user.name "n8n-backup-bot" 2>/dev/null || true

echo "=== n8n Startup ==="
echo "Time: $(date -u)"

# ───────────────────────────────────
# STEP 1: Check Tools
# ───────────────────────────────────
echo "=== Checking Tools ==="
for cmd in git curl jq sqlite3 tar gzip split sha256sum stat du sort tail tac awk xargs find cut tr; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  OK: $cmd"
  else
    echo "  MISSING: $cmd"
  fi
done
echo "=== Tools Check Done ==="

# ───────────────────────────────────
# STEP 2: Restore (if no local DB)
# ───────────────────────────────────
if [ "$FORCE_RESTORE" = "true" ] || [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "=== Attempting Restore ==="
  if /scripts/restore.sh; then
    echo "=== Restore Successful ==="
  else
    echo "=== No backup found - starting fresh ==="
  fi
else
  echo "=== Local database exists - skipping restore ==="
fi

# ───────────────────────────────────
# STEP 3: Backup monitor (background)
# ───────────────────────────────────
(
  sleep 30
  echo "[backup-monitor] Started (interval: ${MONITOR_INTERVAL}s)"
  while true; do
    /scripts/multi_repo_backup.sh 2>&1 | while IFS= read -r line; do
      echo "[backup] $line"
    done || true
    sleep "$MONITOR_INTERVAL"
  done
) &

# ───────────────────────────────────
# STEP 4: Start n8n
# ───────────────────────────────────
echo "=== Starting n8n ==="
exec n8n start
