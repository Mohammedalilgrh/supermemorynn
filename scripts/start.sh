#!/bin/sh
set -eu
umask 077

MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
INIT_FLAG="$WORK/.initialized"

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

echo "🚀 بدء خدمة n8n"
echo "🕒 الوقت: $(date -u)"

echo "🔎 التحقق من الأدوات:"
TOOLS_OK=true
for cmd in git curl jq sqlite3 tar gzip split sha256sum stat du sort tail tac awk xargs find cut tr; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
  else
    echo "  ❌ مفقود: $cmd"
    TOOLS_OK=false
  fi
done
echo "✅ التحقق من الأدوات – اكتمل"

# 📦 استرجاع أو بدء ذكي
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 لا توجد قاعدة بيانات – محاولة الاسترجاع"

  if [ "$TOOLS_OK" = "true" ]; then
    if /scripts/restore.sh 2>&1; then

      echo "✅ الاسترجاع تم بنجاح"

      if [ -s "$N8N_DIR/database.sqlite" ]; then
        echo "🟢 قاعدة البيانات موجودة ✔️"
      else
        echo "⚠️ لم يتم إنشاء قاعدة البيانات بعد الاسترجاع"
        if [ -f "$INIT_FLAG" ]; then
          echo "🛑 تم تهيئة النظام سابقًا – لكن لا يوجد باك أب ولا داتابيس – سيتم إيقاف التشغيل"
          exit 1
        else
          echo "🆕 أول تشغيل – السماح بالتشغيل وبدء الباك أب الأول"
          echo "initialized: $(date -u)" > "$INIT_FLAG"
        fi
      fi

    else
      echo "⚠️ لم يتم استرجاع أي نسخة احتياطية"

      if [ -f "$INIT_FLAG" ]; then
        echo "🛑 تم تفعيل النظام سابقًا، ولا يوجد باك أب حالي – إيقاف لمنع فقدان البيانات"
        exit 1
      else
        echo "🆕 أول تشغيل – لا توجد نسخة احتياطية – بدء التشغيل"
        echo "initialized: $(date -u)" > "$INIT_FLAG"
      fi
    fi
  else
    echo "❌ أدوات الاسترجاع غير متوفرة"
    exit 1
  fi
else
  echo "✅ قاعدة البيانات موجودة – لا حاجة للاسترجاع"
  if [ ! -f "$INIT_FLAG" ]; then
    echo "⌛ تسجيل التهيئة الأولى"
    echo "initialized: $(date -u)" > "$INIT_FLAG"
  fi
fi

# 🛡️ بدء مراقبة الباك أب القديم
if [ "$TOOLS_OK" = "true" ]; then
  (
    sleep 30
    echo "[backup-monitor] قيد التشغيل – كل ${MONITOR_INTERVAL}s"
    while true; do
      /scripts/multi_repo_backup.sh 2>&1 | while IFS= read -r line; do
        echo "[backup] $line"
      done || true
      sleep "$MONITOR_INTERVAL"
    done
  ) &
else
  echo "⚠️ أدوات النسخ الاحتياطي غير مكتملة – لن يتم تشغيل الباك أب"
fi

echo "🚀 تشغيل n8n الآن..."
exec n8n start
