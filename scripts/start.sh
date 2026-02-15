#!/bin/sh
set -eu
umask 077

MONITOR_INTERVAL="${MONITOR_INTERVAL:-${BACKUP_INTERVAL:-60}}"
FORCE_RESTORE="${FORCE_RESTORE:-false}"
MAX_RESTORE_TRIES="${MAX_RESTORE_TRIES:-10}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need_cmd git
need_cmd tar
need_cmd gzip
need_cmd sqlite3

# Restore once at startup (safe)
FORCE_RESTORE="$FORCE_RESTORE" MAX_RESTORE_TRIES="$MAX_RESTORE_TRIES" /scripts/restore.sh || true

# Periodic backup loop
(
  while true; do
    sleep "$MONITOR_INTERVAL"
    /scripts/backup.sh >/dev/null 2>&1 || true
  done
) &

exec n8n start
