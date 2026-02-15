#!/bin/sh
set -eu
umask 077

MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

mkdir -p "$N8N_DIR" "$WORK"

# ───────────────────────────────────
# Git config (دائم)
# ───────────────────────────────────
export HOME="/home/node"
mkdir -p "$HOME"
cat > "$HOME/.gitconfig" <<'GITCONF'
[user]
    email = backup@local
    name = n8n-backup-bot
[safe]
    directory = *
GITCONF

echo "=== n8n Startup ==="
echo "Time: $(date -u)"

# ───────────────────────────────────
# Check Tools
# ───────────────────────────────────
echo "=== Checking Tools ==="
TOOLS_OK=true
for cmd in git curl jq sqlite3 tar gzip split sha256sum stat du sort tail tac awk xargs find cut tr; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  OK: $cmd"
  else
    echo "  MISSING: $cmd"
    TOOLS_OK=false
  fi
done
echo "=== Tools Check Done ==="

# ───────────────────────────────────
# Restore (تلقائي - لو ما فيه داتابيس)
# ───────────────────────────────────
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "=== No local database - attempting restore ==="
  if [ "$TOOLS_OK" = "true" ]; then
    /scripts/restore.sh 2>&1 || echo "=== No backup found - starting fresh ==="
  else
    echo "=== Tools missing - cannot restore ==="
  fi
else
  echo "=== Local database exists - skipping restore ==="
fi

# ───────────────────────────────────
# Backup monitor (دائم)
# ───────────────────────────────────
if [ "$TOOLS_OK" = "true" ]; then
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
else
  echo "=== WARNING: Backup disabled - tools missing ==="
fi

# ───────────────────────────────────
# Start n8n
# ───────────────────────────────────
echo "=== Starting n8n ==="
exec n8n start
