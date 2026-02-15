#!/bin/sh
set -eu
umask 077

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN}"
: "${GITHUB_REPO_OWNER:?Set GITHUB_REPO_OWNER}"
: "${GITHUB_REPO_NAME:?Set GITHUB_REPO_NAME}"

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

FORCE_RESTORE="${FORCE_RESTORE:-false}"
PRESERVE_LOCAL="${PRESERVE_LOCAL:-true}"
MAX_RESTORE_TRIES="${MAX_RESTORE_TRIES:-10}"

RESTORE_REPO="${RESTORE_REPO:-}"
RESTORE_BRANCH="${RESTORE_BRANCH:-}"

GIT_CLONE_RETRIES="${GIT_CLONE_RETRIES:-3}"
GIT_CLONE_SLEEP_SEC="${GIT_CLONE_SLEEP_SEC:-2}"

VERIFY_SHA256="${VERIFY_SHA256:-true}"

OWNER="$GITHUB_REPO_OWNER"
BASE_REPO="$GITHUB_REPO_NAME"
TOKEN="$GITHUB_TOKEN"

BASE_URL="https://${TOKEN}@github.com/${OWNER}/${BASE_REPO}.git"

META_DIR="n8n-data/_meta"
META_LATEST_REPO="$META_DIR/latest_repo"
META_LATEST_BRANCH="$META_DIR/latest_branch"
META_HISTORY="$META_DIR/history.log"

TMP_BASE="/tmp/n8n-restore-meta-$$"
TMP_BKP="/tmp/n8n-restore-bkp-$$"
CANDIDATES="/tmp/n8n-restore-candidates-$$"

cleanup() {
  rm -rf "$TMP_BASE" "$TMP_BKP" 2>/dev/null || true
  rm -f "$CANDIDATES" 2>/dev/null || true
}
trap cleanup EXIT

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need_cmd git
need_cmd tar
need_cmd gzip
need_cmd sqlite3
need_cmd awk
need_cmd sort
need_cmd xargs
need_cmd stat
need_cmd tail
need_cmd sha256sum
need_cmd find

mkdir -p "$WORK" "$N8N_DIR"

git_clone_retry() {
  url="$1"; branch="$2"; dest="$3"; depth="${4:-1}"
  rm -rf "$dest" 2>/dev/null || true
  i=1
  while [ "$i" -le "$GIT_CLONE_RETRIES" ]; do
    if git clone --depth "$depth" --single-branch --branch "$branch" "$url" "$dest" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep "$GIT_CLONE_SLEEP_SEC"
  done
  return 1
}

preserve_local_dir_if_needed() {
  if [ "$PRESERVE_LOCAL" = "true" ] && [ -d "$N8N_DIR" ] && \
     [ "$(ls -A "$N8N_DIR" 2>/dev/null || true)" != "" ]; then
    ts="$(date +"%Y-%m-%d_%H-%M-%S")"
    mv "$N8N_DIR" "${N8N_DIR}.pre_restore_${ts}" 2>/dev/null || true
    mkdir -p "$N8N_DIR"
  fi
}

sqlite_integrity_ok() {
  db="$1"
  [ -f "$db" ] || return 1
  sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null \
    | awk 'NR==1{print}' | grep -q "^ok$"
}

verify_sha256_if_present() {
  dir="$1"
  [ "$VERIFY_SHA256" = "true" ] || return 0
  if [ -f "$dir/n8n-data/SHA256SUMS.txt" ]; then
    ( cd "$dir/n8n-data" && sha256sum -c "SHA256SUMS.txt" ) >/dev/null 2>&1 || return 1
  fi
  return 0
}

restore_from_backup_tree() {
  bdir="$1"

  # ─── New format: db.sql.gz.part_* ───
  if ls "$bdir"/n8n-data/db.sql.gz.part_* >/dev/null 2>&1; then
    echo "Restoring: new format (sql.gz parts)"

    if ls "$bdir"/n8n-data/files.tar.gz.part_* >/dev/null 2>&1; then
      cat "$bdir"/n8n-data/files.tar.gz.part_* \
        | gzip -dc \
        | tar -C "$N8N_DIR" -xf -
    fi

    rm -f "$N8N_DIR/database.sqlite" \
          "$N8N_DIR/database.sqlite-wal" \
          "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

    ls -1 "$bdir"/n8n-data/db.sql.gz.part_* 2>/dev/null \
      | sort | xargs cat \
      | gzip -dc \
      | sqlite3 "$N8N_DIR/database.sqlite"

  # ─── Legacy format: uncompressed sql parts ───
  elif ls "$bdir"/n8n-data/db.sql.part_* >/dev/null 2>&1; then
    echo "Restoring: legacy format (sql parts)"

    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    ls -1 "$bdir"/n8n-data/db.sql.part_* 2>/dev/null \
      | sort | xargs cat \
      | sqlite3 "$N8N_DIR/database.sqlite"

  # ─── Old format: direct database.sqlite ───
  elif [ -f "$bdir/database.sqlite" ]; then
    echo "Restoring: old format (direct sqlite)"

    cp "$bdir/database.sqlite" "$N8N_DIR/database.sqlite"
    [ -f "$bdir/database.sqlite-wal" ] && cp "$bdir/database.sqlite-wal" "$N8N_DIR/" 2>/dev/null || true
    [ -f "$bdir/database.sqlite-shm" ] && cp "$bdir/database.sqlite-shm" "$N8N_DIR/" 2>/dev/null || true

    # Copy config/nodes if present
    for d in config nodes custom-nodes; do
      [ -d "$bdir/$d" ] && cp -r "$bdir/$d" "$N8N_DIR/" 2>/dev/null || true
    done

    # Copy other important files
    for f in stats.json crash.journal; do
      [ -f "$bdir/$f" ] && cp "$bdir/$f" "$N8N_DIR/" 2>/dev/null || true
    done

  else
    echo "ERROR: No supported DB format found" >&2
    return 1
  fi

  # Integrity check
  sqlite_integrity_ok "$N8N_DIR/database.sqlite" || {
    echo "ERROR: SQLite integrity check failed" >&2
    return 1
  }

  chmod 700 "$N8N_DIR" 2>/dev/null || true
  chmod 600 "$N8N_DIR/database.sqlite" 2>/dev/null || true

  return 0
}

restore_one() {
  repo="$1"; branch="$2"
  VOL_URL="https://${TOKEN}@github.com/${OWNER}/${repo}.git"

  echo "Trying restore: ${repo}/${branch}"

  rm -rf "$TMP_BKP" 2>/dev/null || true

  ok=1
  i=1
  while [ "$i" -le "$GIT_CLONE_RETRIES" ]; do
    if git clone --depth 1 --single-branch --branch "$branch" \
         "$VOL_URL" "$TMP_BKP" 2>/dev/null; then
      ok=0
      break
    fi
    i=$((i + 1))
    sleep "$GIT_CLONE_SLEEP_SEC"
  done
  [ "$ok" -eq 0 ] || return 1

  verify_sha256_if_present "$TMP_BKP" || return 1

  preserve_local_dir_if_needed
  restore_from_backup_tree "$TMP_BKP"
}

# ── MAIN ──

if [ "$FORCE_RESTORE" != "true" ] && [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "Local database exists - skipping restore"
  exit 0
fi

# Explicit restore (old repo)
if [ -n "$RESTORE_REPO" ] && [ -n "$RESTORE_BRANCH" ]; then
  if restore_one "$RESTORE_REPO" "$RESTORE_BRANCH"; then
    echo "Restore successful from $RESTORE_REPO/$RESTORE_BRANCH"
    exit 0
  fi
  echo "Explicit restore failed"
  exit 1
fi

# Auto restore from meta
echo "Fetching restore info from: ${OWNER}/${BASE_REPO}"

git_clone_retry "$BASE_URL" "$GITHUB_BRANCH" "$TMP_BASE" 1 || {
  echo "Cannot clone base repo - no backup to restore"
  exit 1
}

rm -f "$CANDIDATES" 2>/dev/null || true

if [ -f "$TMP_BASE/$META_HISTORY" ] && [ -s "$TMP_BASE/$META_HISTORY" ]; then
  tail -n $((MAX_RESTORE_TRIES * 3)) "$TMP_BASE/$META_HISTORY" \
    | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' \
    | awk '{repo=$2; br=$3; key=repo"|"br; if(!seen[key]++) print}' \
    | awk -v max="$MAX_RESTORE_TRIES" 'NR<=max{print}' \
    > "$CANDIDATES"
else
  lr=""; lb=""
  [ -f "$TMP_BASE/$META_LATEST_REPO" ] && lr=$(cat "$TMP_BASE/$META_LATEST_REPO" 2>/dev/null || true)
  [ -f "$TMP_BASE/$META_LATEST_BRANCH" ] && lb=$(cat "$TMP_BASE/$META_LATEST_BRANCH" 2>/dev/null || true)
  if [ -n "$lr" ] && [ -n "$lb" ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $lr $lb fallback" > "$CANDIDATES"
  fi
fi

if [ ! -s "$CANDIDATES" ]; then
  echo "No restore candidates found"
  exit 1
fi

RESTORED="false"
while read -r ts repo branch id; do
  if restore_one "$repo" "$branch"; then
    RESTORED="true"
    echo "Restored from: $repo/$branch"
    break
  fi
done < "$CANDIDATES"

[ "$RESTORED" = "true" ] || { echo "All restore attempts failed"; exit 1; }

echo "=== Restore Complete ==="
exit 0
