#!/bin/sh
set -eu
umask 077

MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

mkdir -p "$N8N_DIR" "$WORK"

export HOME="/home/node"
mkdir -p "$HOME"
cat > "$HOME/.gitconfig" <<'GITCONF'
[user]
    email = backup@local
    name = n8n-backup-bot
[safe]
    directory = *
GITCONF

echo "=== 🚀 بدء خدمة n8n ==="
echo "الوقت: $(date -u)"

# ✅ التأكد من الأدوات
echo "🧪 التحقق من الأدوات:"
TOOLS_OK=true
for cmd in git curl jq sqlite3 tar gzip split sha256sum stat du sort tail tac awk xargs find cut tr; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
  else
    echo "  ❌ مفقود: $cmd"
    TOOLS_OK=false
  fi
done
echo "=== ✅ التحقق من الأدوات – تمت ==="

# 📦 استرجاع باك أب
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "🔄 لا يوجد قاعدة بيانات – محاولة استرجاع"
  if [ "$TOOLS_OK" = "true" ]; then
    if /scripts/restore.sh 2>&1; then
      echo "✅ تم الاسترجاع – الانطلاق!"
      
      # ✳️ تحقق إضافي أن قاعدة البيانات صارت موجودة فعلاً بعد الاسترجاع
      if [ -s "$N8N_DIR/database.sqlite" ]; then
        echo "🟩 التحقق من ملف قاعدة البيانات: موجود ✔️"
      else
        echo "🛑 ERROR: لم يتم إنشاء database.sqlite بعد الاسترجاع – سيتم إيقاف النظام"
        exit 1
      fi
      
    else
      echo "❌ فشل استرجاع البيانات – إيقاف النظام"
      exit 1
    fi
  else
    echo "❌ الأدوات مفقودة – لا يمكن الاسترجاع"
    exit 1
  fi
else
  echo "🟢 قاعدة بيانات موجودة – الاسترجاع غير مطلوب"
fi

# 🛡️ بدء عملية الباك أب التلقائي
if [ "$TOOLS_OK" = "true" ]; then
  (
    sleep 30
    echo "[backup-monitor] بدء المراقبة كل ${MONITOR_INTERVAL}s"
    while true; do
      /scripts/multi_repo_backup.sh 2>&1 | while IFS= read -r line; do
        echo "[backup] $line"
      done || true
      sleep "$MONITOR_INTERVAL"
    done
  ) &
else
  echo "⚠️ تنبيه: النسخ الاحتياطي غير مفعل – أدوات ناقصة"
fi

echo "🚀 تشغيل n8n..."
exec n8n start
