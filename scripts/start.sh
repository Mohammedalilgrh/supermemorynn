#!/bin/sh
set -eu
umask 077

# ── المتغيرات ──
MONITOR_INTERVAL="${MONITOR_INTERVAL:-45}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
INIT_FLAG="$WORK/.initialized"

mkdir -p "$N8N_DIR" "$WORK"

export HOME="/home/node"
mkdir -p "$HOME"

cat > "$HOME/.gitconfig" <<'GC'
[user]
    email = backup@local
    name = n8n-backup-bot
[safe]
    directory = *
GC

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   n8n + Bulletproof Backup System v2.0       ║"
echo "║   $(date -u)                  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── فحص الأدوات ──
echo "🔎 فحص الأدوات:"
TOOLS_OK=true
for cmd in git curl jq sqlite3 tar gzip split sha256sum \
           stat du sort awk xargs find cut tr cat grep sed; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ✅ %s\n" "$cmd"
  else
    printf "  ❌ %s\n" "$cmd"
    TOOLS_OK=false
  fi
done

if [ "$TOOLS_OK" = "false" ]; then
  echo "❌ أدوات مهمة مفقودة"
  exit 1
fi
echo ""

# ── الاسترجاع ──
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 لا توجد قاعدة بيانات محلية"
  echo "🔄 جاري البحث عن آخر نسخة احتياطية..."
  echo ""

  restore_ok=false
  if sh /scripts/restore.sh 2>&1; then
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      restore_ok=true
    fi
  fi

  if [ "$restore_ok" = "true" ]; then
    echo ""
    echo "✅ تم استرجاع البيانات بنجاح!"
  else
    echo ""
    echo "📭 لا توجد نسخة احتياطية سابقة"
    echo "🆕 سيبدأ n8n كأول تشغيل"
  fi

  echo "init:$(date -u)" > "$INIT_FLAG"
else
  echo "✅ قاعدة البيانات موجودة محلياً"
  [ -f "$INIT_FLAG" ] || echo "init:$(date -u)" > "$INIT_FLAG"
fi

# ── Keep-Alive (يمنع Render من إيقاف الخدمة) ──
(
  sleep 60
  echo "[keepalive] 🟢 بدء Keep-Alive"
  while true; do
    if [ -n "${WEBHOOK_URL:-}" ]; then
      curl -sS -o /dev/null "${WEBHOOK_URL}/healthz" 2>/dev/null || true
    elif [ -n "${N8N_HOST:-}" ]; then
      curl -sS -o /dev/null "https://${N8N_HOST}/healthz" 2>/dev/null || true
    else
      curl -sS -o /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null || true
    fi
    sleep 300
  done
) &

# ── مراقب الباك أب ──
(
  # ننتظر n8n يجهز
  echo "[backup] ⏳ انتظار 60 ثانية لبدء n8n..."
  sleep 60

  # باك أب فوري أول شي
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    echo "[backup] 🔥 باك أب فوري بعد الإقلاع"
    rm -f "$WORK/.backup_state" 2>/dev/null || true
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi

  echo "[backup] 🔄 بدء المراقبة كل ${MONITOR_INTERVAL}s"
  while true; do
    sleep "$MONITOR_INTERVAL"
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
    fi
  done
) &

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   🚀 تشغيل n8n الآن...                      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

exec n8n start
