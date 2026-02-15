#!/bin/sh
set -eu
umask 077

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

BASE_REPO="${GITHUB_REPO_NAME:?missing GITHUB_REPO_NAME}"
OWNER="${GITHUB_REPO_OWNER:?missing GITHUB_REPO_OWNER}"
TOKEN="${GITHUB_TOKEN:?missing GITHUB_TOKEN}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
STATE_FILE="$WORK/.backup_state"

FORCE_RESTORE="${FORCE_RESTORE:-false}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"
MAX_RESTORE_TRIES="${MAX_RESTORE_TRIES:-5}"   # لو فشلت آخر نسخة جرّب قبلها

META_DIR="n8n-data/_meta"
META_LATEST_REPO="$META_DIR/latest_repo"
META_LATEST_BRANCH="$META_DIR/latest_branch"
META_HISTORY="$META_DIR/history.log"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need_cmd git
need_cmd tar
need_cmd gzip
need_cmd sqlite3
need_cmd sort
need_cmd tail
need_cmd awk

mkdir -p "$N8N_DIR" "$WORK"

BASE_URL="https://${TOKEN}@github.com/${OWNER}/${BASE_REPO}.git"

cleanup_tmp() {
  rm -rf "$WORK/_tmp_base_meta" "$WORK/_tmp_backup" 2>/dev/null || true
}

restore_one() {
  repo="$1"
  branch="$2"

  VOLUME_URL="https://${TOKEN}@github.com/${OWNER}/${repo}.git"
  tmp_bkp="$WORK/_tmp_backup"
  rm -rf "$tmp_bkp" 2>/dev/null || true

  # clone backup branch فقط
  git clone -q --depth 1 --single-branch --branch "$branch" "$VOLUME_URL" "$tmp_bkp" 2>/dev/null || return 1

  # Restore files archive
  if ls "$tmp_bkp"/n8n-data/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$tmp_bkp"/n8n-data/files.tar.gz.part_* \
      | gzip -dc \
      | tar -C "$N8N_DIR" -xf -
  fi

  # Restore DB from SQL parts (streaming)
  if ls "$tmp_bkp"/n8n-data/db.sql.part_* >/dev/null 2>&1; then
    rm -f "$N8N_DIR/database.sqlite" "$N8N_DIR/database.sqlite-wal" "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true
    # ترتيب ثابت
    ls -1 "$tmp_bkp"/n8n-data/db.sql.part_* 2>/dev/null | sort | xargs cat \
      | sqlite3 "$N8N_DIR/database.sqlite"
  fi

  # فحص سلامة سريع
  if [ -f "$N8N_DIR/database.sqlite" ]; then
    sqlite3 "$N8N_DIR/database.sqlite" "PRAGMA integrity_check;" | grep -q "ok" || return 1
  fi

  chmod 700 "$N8N_DIR" 2>/dev/null || true
  chmod 600 "$N8N_DIR/database.sqlite" 2>/dev/null || true

  return 0
}

# لا تستبدل محلياً إذا DB موجودة إلا إذا FORCE_RESTORE=true
if [ "$FORCE_RESTORE" != "true" ] && [ -s "$N8N_DIR/database.sqlite" ]; then
  :
else
  tmp_base="$WORK/_tmp_base_meta"
  rm -rf "$tmp_base" 2>/dev/null || true

  if git clone -q --depth 1 --single-branch --branch "$GITHUB_BRANCH" "$BASE_URL" "$tmp_base" 2>/dev/null; then
    # نجمع قائمة محاولات من history آخر سطور
    tries=0

    if [ -f "$tmp_base/$META_HISTORY" ]; then
      # آخر N أسطر: "ts repo branch id"
      tail -n "$MAX_RESTORE_TRIES" "$tmp_base/$META_HISTORY" > "$WORK/_restore_candidates" 2>/dev/null || true
    else
      : > "$WORK/_restore_candidates"
    fi

    # إذا ماكو history، جرّب latest_repo/latest_branch
    if [ ! -s "$WORK/_restore_candidates" ]; then
      latest_repo=""
      latest_branch=""
      [ -f "$tmp_base/$META_LATEST_REPO" ] && latest_repo=$(cat "$tmp_base/$META_LATEST_REPO" 2>/dev/null || true)
      [ -f "$tmp_base/$META_LATEST_BRANCH" ] && latest_branch=$(cat "$tmp_base/$META_LATEST_BRANCH" 2>/dev/null || true)
      if [ -n "$latest_repo" ] && [ -n "$latest_branch" ]; then
        echo "manual $latest_repo $latest_branch x" > "$WORK/_restore_candidates"
      fi
    fi

    # جرّب من الأحدث للأقدم
    tac "$WORK/_restore_candidates" 2>/dev/null | while read -r ts repo branch id; do
      tries=$((tries + 1))
      [ "$tries" -le "$MAX_RESTORE_TRIES" ] || break

      if restore_one "$repo" "$branch"; then
        cat > "$STATE_FILE" <<EOF
LAST_REPO=$repo
LAST_BRANCH=$branch
LAST_RESTORE_TS=$ts
EOF
        exit 0
      fi
    done || true
  fi

  cleanup_tmp
fi

cleanup_tmp
rm -f "$WORK/_restore_candidates" 2>/dev/null || true

# Monitor: backup.sh داخله قرار ذكي + cooldown
(
  while true; do
    sleep "$MONITOR_INTERVAL"
    /scripts/backup.sh >/dev/null 2>&1 || true
  done
) &

exec n8n start
