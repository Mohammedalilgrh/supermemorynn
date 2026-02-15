#!/bin/sh
set -eu
umask 077

# ============================================================
# scripts/restore.sh  (Ultra-robust restore)
# Compatible with the "append-only multi-repo" backup system:
# - Base repo (GITHUB_REPO_NAME) main contains pointers + history.log
# - Actual backups are stored in volume repos, each backup in its own branch:
#     backup/<timestamp>
# - Backup branch contains (most common):
#     n8n-data/db.sql.gz.part_*
#     n8n-data/files.tar.gz.part_*
#   plus optional SHA256SUMS.txt, backup_info.txt
#
# Features:
# - Restores from latest pointer, with automatic fallback to older backups
# - Streaming restore (no huge temp files)
# - Optional SHA256 verification (if present)
# - Preserves existing local ~/.n8n by renaming it (optional)
# - Supports legacy formats as fallback:
#     database.sqlite, chunks/n8n_part_*, full_backup.sql(.gz), n8n_files.tar.gz
# ============================================================

# ---------- Required ENV ----------
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN}"
: "${GITHUB_REPO_OWNER:?Set GITHUB_REPO_OWNER}"
: "${GITHUB_REPO_NAME:?Set GITHUB_REPO_NAME}"

# ---------- Optional ENV ----------
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

# Safety controls
FORCE_RESTORE="${FORCE_RESTORE:-false}"        # true => restore even if local DB exists
PRESERVE_LOCAL="${PRESERVE_LOCAL:-true}"      # true => rename existing N8N_DIR before restore
MAX_RESTORE_TRIES="${MAX_RESTORE_TRIES:-10}"  # try latest then older backups

# If you want to restore a specific backup explicitly:
# RESTORE_REPO="your-vol-repo"
# RESTORE_BRANCH="backup/2026-01-01_00-00-00"
RESTORE_REPO="${RESTORE_REPO:-}"
RESTORE_BRANCH="${RESTORE_BRANCH:-}"

# Network robustness
GIT_CLONE_RETRIES="${GIT_CLONE_RETRIES:-3}"
GIT_CLONE_SLEEP_SEC="${GIT_CLONE_SLEEP_SEC:-2}"

# Verification
VERIFY_SHA256="${VERIFY_SHA256:-true}"        # verify if SHA256SUMS.txt exists

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

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need_cmd git
need_cmd tar
need_cmd gzip
need_cmd sqlite3
need_cmd awk
need_cmd sort
need_cmd xargs
need_cmd ls
need_cmd stat
need_cmd tail

mkdir -p "$WORK"
mkdir -p "$N8N_DIR"

git_clone_retry() {
  # usage: git_clone_retry <url> <branch> <dest> <depth>
  url="$1"
  branch="$2"
  dest="$3"
  depth="${4:-1}"

  rm -rf "$dest" 2>/dev/null || true

  i=1
  while [ "$i" -le "$GIT_CLONE_RETRIES" ]; do
    # Try partial clone for meta repo (smaller). If unsupported, fallback.
    if git clone --depth "$depth" --single-branch --branch "$branch" --filter=blob:none "$url" "$dest" 2>/dev/null; then
      return 0
    fi
    if git clone --depth "$depth" --single-branch --branch "$branch" "$url" "$dest" 2>/dev/null; then
      return 0
    fi

    i=$((i + 1))
    sleep "$GIT_CLONE_SLEEP_SEC"
  done

  return 1
}

preserve_local_dir_if_needed() {
  if [ "$PRESERVE_LOCAL" = "true" ] && [ -d "$N8N_DIR" ] && [ "$(ls -A "$N8N_DIR" 2>/dev/null || true)" != "" ]; then
    ts="$(date +"%Y-%m-%d_%H-%M-%S")"
    mv "$N8N_DIR" "${N8N_DIR}.pre_restore_${ts}" 2>/dev/null || true
    mkdir -p "$N8N_DIR"
  fi
}

sqlite_integrity_ok() {
  db="$1"
  [ -f "$db" ] || return 1
  sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | awk 'NR==1{print}' | grep -q "^ok$"
}

verify_sha256_if_present() {
  dir="$1"
  [ "$VERIFY_SHA256" = "true" ] || return 0
  [ -f "$dir/n8n-data/SHA256SUMS.txt" ] || [ -f "$dir/n8n-data/SHA256SUMS.txt" ] || true

  if [ -f "$dir/n8n-data/SHA256SUMS.txt" ]; then
    # Some systems store sums relative; run inside n8n-data
    ( cd "$dir/n8n-data" && sha256sum -c "SHA256SUMS.txt" ) >/dev/null 2>&1 || return 1
  fi
  return 0
}

restore_from_backup_tree() {
  # usage: restore_from_backup_tree <backup_clone_dir>
  bdir="$1"

  # 1) Restore files archive (if present)
  if ls "$bdir"/n8n-data/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$bdir"/n8n-data/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf -
  elif [ -f "$bdir/n8n-data/n8n_files.tar.gz" ]; then
    tar -C "$N8N_DIR" -xzf "$bdir/n8n-data/n8n_files.tar.gz"
  else
    # Minimal legacy fallback: copy key/config if present
    for f in ".n8n-encryption-key" "encryptionKey" "config"; do
      [ -f "$bdir/n8n-data/$f" ] && cp "$bdir/n8n-data/$f" "$N8N_DIR/" 2>/dev/null || true
    done
  fi

  # Never let extracted archive override DB (we rebuild DB below)
  rm -f "$N8N_DIR/database.sqlite-wal" "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  # 2) Restore DB (preferred: db.sql.gz.part_*)
  if ls "$bdir"/n8n-data/db.sql.gz.part_* >/dev/null 2>&1; then
    rm -f "$N8N_DIR/database.sqlite" "$N8N_DIR/database.sqlite-wal" "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true
    ls -1 "$bdir"/n8n-data/db.sql.gz.part_* 2>/dev/null | sort | xargs cat \
      | gzip -dc \
      | sqlite3 "$N8N_DIR/database.sqlite"
  elif ls "$bdir"/n8n-data/db.sql.part_* >/dev/null 2>&1; then
    rm -f "$N8N_DIR/database.sqlite" "$N8N_DIR/database.sqlite-wal" "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true
    ls -1 "$bdir"/n8n-data/db.sql.part_* 2>/dev/null | sort | xargs cat \
      | sqlite3 "$N8N_DIR/database.sqlite"
  elif [ -d "$bdir/n8n-data/chunks" ] && ls "$bdir"/n8n-data/chunks/n8n_part_* >/dev/null 2>&1; then
    cat "$bdir"/n8n-data/chunks/n8n_part_* > "$N8N_DIR/database.sqlite"
  elif [ -f "$bdir/n8n-data/database.sqlite" ]; then
    cp "$bdir/n8n-data/database.sqlite" "$N8N_DIR/database.sqlite"
  elif [ -f "$bdir/n8n-data/full_backup.sql.gz" ]; then
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    gzip -dc "$bdir/n8n-data/full_backup.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"
  elif [ -f "$bdir/n8n-data/full_backup.sql" ]; then
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    sqlite3 "$N8N_DIR/database.sqlite" < "$bdir/n8n-data/full_backup.sql"
  else
    echo "ERROR: No supported DB format found in backup tree." >&2
    return 1
  fi

  # 3) Integrity check
  if ! sqlite_integrity_ok "$N8N_DIR/database.sqlite"; then
    echo "ERROR: SQLite integrity_check failed." >&2
    return 1
  fi

  chmod 700 "$N8N_DIR" 2>/dev/null || true
  chmod 600 "$N8N_DIR/database.sqlite" 2>/dev/null || true
  chmod 600 "$N8N_DIR/.n8n-encryption-key" 2>/dev/null || true
  chmod 600 "$N8N_DIR/encryptionKey" 2>/dev/null || true

  return 0
}

restore_one() {
  # usage: restore_one <repo> <branch>
  repo="$1"
  branch="$2"

  VOL_URL="https://${TOKEN}@github.com/${OWNER}/${repo}.git"

  echo "Attempt restore: repo=${repo} branch=${branch}"

  rm -rf "$TMP_BKP" 2>/dev/null || true

  # Backup branch clone must include blobs => no filter=blob:none here
  ok=1
  i=1
  while [ "$i" -le "$GIT_CLONE_RETRIES" ]; do
    if git clone --depth 1 --single-branch --branch "$branch" "$VOL_URL" "$TMP_BKP" 2>/dev/null; then
      ok=0
      break
    fi
    i=$((i + 1))
    sleep "$GIT_CLONE_SLEEP_SEC"
  done
  [ "$ok" -eq 0 ] || return 1

  # Optional sha verification if present (best effort)
  if ! verify_sha256_if_present "$TMP_BKP"; then
    echo "WARNING: SHA256 verification failed for ${repo}/${branch}" >&2
    return 1
  fi

  preserve_local_dir_if_needed
  restore_from_backup_tree "$TMP_BKP"
}

# -------------------------
# Safety: skip restore if local DB exists (unless FORCE_RESTORE=true)
# -------------------------
if [ "$FORCE_RESTORE" != "true" ] && [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "Local database exists. Skipping restore (set FORCE_RESTORE=true to override)."
  exit 0
fi

# -------------------------
# Explicit restore (if provided)
# -------------------------
if [ -n "$RESTORE_REPO" ] && [ -n "$RESTORE_BRANCH" ]; then
  if restore_one "$RESTORE_REPO" "$RESTORE_BRANCH"; then
    echo "Restore complete."
    exit 0
  fi
  echo "Explicit restore failed."
  exit 1
fi

# -------------------------
# Auto restore from base repo meta pointers + history
# -------------------------
echo "Fetching restore pointers from base repo: ${OWNER}/${BASE_REPO} (${GITHUB_BRANCH})"

if ! git_clone_retry "$BASE_URL" "$GITHUB_BRANCH" "$TMP_BASE" 1; then
  echo "ERROR: Cannot clone base repo meta. Nothing to restore." >&2
  exit 1
fi

# Build candidates list (newest -> older) from history.log, fallback to latest pointer
rm -f "$CANDIDATES" 2>/dev/null || true

if [ -f "$TMP_BASE/$META_HISTORY" ] && [ -s "$TMP_BASE/$META_HISTORY" ]; then
  # Take last MAX_RESTORE_TRIES*3 to allow dedup, then reverse order with awk
  tail -n $((MAX_RESTORE_TRIES * 3)) "$TMP_BASE/$META_HISTORY" \
    | awk '
        { a[NR]=$0 }
        END { for (i=NR; i>=1; i--) print a[i] }
      ' \
    | awk '
        # Deduplicate by "repo branch" keep first (newest)
        {
          repo=$2; br=$3
          key=repo "|" br
          if (!seen[key]++) print
        }
      ' \
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
  echo "ERROR: No restore candidates found." >&2
  exit 1
fi

echo "Trying restore candidates (up to $MAX_RESTORE_TRIES)..."

RESTORED="false"
while read -r ts repo branch id; do
  if restore_one "$repo" "$branch"; then
    RESTORED="true"
    cat > "$WORK/.restore_state" <<EOF
RESTORED_TS=$ts
RESTORED_REPO=$repo
RESTORED_BRANCH=$branch
EOF
    echo "Restored from: $repo / $branch"
    break
  fi
done < "$CANDIDATES"

if [ "$RESTORED" != "true" ]; then
  echo "ERROR: All restore attempts failed." >&2
  exit 1
fi

echo "=== Restore Complete ==="
exit 0
