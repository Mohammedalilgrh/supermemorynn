#!/bin/sh
set -eu
umask 077

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN}"
: "${GITHUB_REPO_OWNER:?Set GITHUB_REPO_OWNER}"
: "${GITHUB_REPO_NAME:?Set GITHUB_REPO_NAME}"

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

MAX_RESTORE_TRIES="${MAX_RESTORE_TRIES:-10}"

# اسم الريبو القديم (للنسخ القديمة)
LEGACY_REPO="${LEGACY_REPO:-n8n-storage}"

OWNER="$GITHUB_REPO_OWNER"
BASE_REPO="$GITHUB_REPO_NAME"
TOKEN="$GITHUB_TOKEN"

BASE_URL="https://${TOKEN}@github.com/${OWNER}/${BASE_REPO}.git"

TMP_BASE="/tmp/n8n-restore-base-$$"
TMP_BKP="/tmp/n8n-restore-bkp-$$"

cleanup() {
  rm -rf "$TMP_BASE" "$TMP_BKP" 2>/dev/null || true
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }
}
need_cmd git
need_cmd tar
need_cmd gzip
need_cmd sqlite3
need_cmd sha256sum
need_cmd awk
need_cmd find

mkdir -p "$N8N_DIR" "$WORK"

# اذا عندنا قاعدة بيانات محلية – ما نرجع
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "=== داتابيس موجودة – تخطّي الاسترجاع ==="
  exit 0
fi

# نحاول تجيب الباك أب من الريبو
echo "=== بدينا عملية الاسترجاع ==="

try_restore() {
  repo="$1"
  branch="$2"
  remote_url="https://${TOKEN}@github.com/${OWNER}/${repo}.git"

  echo "--- محاولة استرجاع من: ${repo}/${branch} ---"

  git clone --depth 1 --branch "$branch" "$remote_url" "$TMP_BKP" || return 1

  if ls "$TMP_BKP"/n8n-data/db.sql.gz.part_* >/dev/null 2>&1; then
    cat "$TMP_BKP"/n8n-data/db.sql.gz.part_* \
      | gzip -dc \
      | sqlite3 "$N8N_DIR/database.sqlite"
  fi

  if ls "$TMP_BKP"/n8n-data/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$TMP_BKP"/n8n-data/files.tar.gz.part_* \
      | gzip -dc \
      | tar -C "$N8N_DIR" -xf -
  fi

  # check
  tables="$(sqlite3 "$N8N_DIR/database.sqlite" ".tables" | wc -l)"
  if [ "$tables" -gt 0 ]; then
    echo "✅ استرجاع ناجح من $repo/$branch"
    return 0
  else
    echo "❌ قاعدة بيانات تالفة – نفشل"
    return 1
  fi
}

# تجيب اخر ريباز من URL
get_latest_pointer() {
  rm -rf "$TMP_BASE"
  git clone --depth 1 --branch "$GITHUB_BRANCH" "$BASE_URL" "$TMP_BASE" || return 1
  pointer_file="$TMP_BASE/n8n-data/_meta/latest_repo"
  branch_file="$TMP_BASE/n8n-data/_meta/latest_branch"
  [ -f "$pointer_file" ] || return 1
  [ -f "$branch_file" ] || return 1
  latest_repo=$(cat "$pointer_file")
  latest_branch=$(cat "$branch_file")
  try_restore "$latest_repo" "$latest_branch"
}

# نجرب الاسترجاع الحديث
if get_latest_pointer; then
  echo "=== ✔️ استرجاع كامل ==="
  exit 0
fi

# ولو فشل، نجرب الريبو القديم
if try_restore "$LEGACY_REPO" "main"; then
  echo "=== ✔️ استرجاع من ريبو قديم ==="
  exit 0
fi

echo "❌ ماكو باك أب صالح – نوقف"
exit 1
