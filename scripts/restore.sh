#!/bin/sh
set -eu
umask 077

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN}"
: "${GITHUB_REPO_OWNER:?Set GITHUB_REPO_OWNER}"
: "${GITHUB_REPO_NAME:?Set GITHUB_REPO_NAME}"

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

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

# ⛔ إذا الداتابيس موجودة مسبقاً – ما نرجّع شي
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "✅ قاعدة البيانات موجودة – لا حاجة للاسترجاع"
  exit 0
fi

echo "=== 🚀 بدء استرجاع البيانات ==="

try_restore() {
  repo="$1"
  branch="$2"
  remote_url="https://${TOKEN}@github.com/${OWNER}/${repo}.git"

  echo "🔄 محاولة استرجاع من: $repo/$branch"
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

  # ✅ تأكد أن قاعدة البيانات تحتوي شغلات حقيقية
  tables=$(sqlite3 "$N8N_DIR/database.sqlite" ".tables" | wc -l)
  if [ "$tables" -gt 0 ]; then
    echo "✅ تم الاسترجاع بنجاح من $repo/$branch"
    return 0
  else
    echo "❌ قاعدة البيانات المسترجعة فارغة – نعتبرها فشل"
    return 1
  fi
}

# ⚙️ نبدأ نحاول من الريبو الأساسي
if try_restore "$BASE_REPO" "$GITHUB_BRANCH"; then
  echo "✅ استرجاع ناجح – جاهزين للعمل"
  exit 0
fi

# 🤖 لم يتم العثور على أي باك أب؟ نطبع ونسمح بالتشغيل
echo "⚠️ لم يتم استرجاع أي باك أب – جاري بدء n8n كأول تشغيل (first-time setup)"
echo "📌 سيتم إنشاء أول نسخة احتياطية تلقائيًا بعد بدء التشغيل"
exit 0
