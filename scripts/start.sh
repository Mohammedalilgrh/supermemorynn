#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"
WORK="/backup-data"
# البحث عن آخر ريبو تم استخدامه (نظام الـ Multi-Repo)
# إذا كان لديك ريبوهات متعددة، نوصي بوضع اسم الريبو الأساسي هنا
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

mkdir -p "$N8N_DIR"
cd "$WORK"

echo "🛰️ بدء سحب البيانات بتقنية الـ Streaming..."
git clone --depth 1 "$REPO_URL" repo 2>/dev/null || echo "أول تشغيل"

if [ -d "repo/n8n-data" ]; then
    echo "🧩 تجميع أجزاء الداتابيس (توفير الرام)..."
    
    # 🔥 تقنية الـ Streaming: تجميع القطع مباشرة إلى الملف دون تحميلها للذاكرة
    cat repo/n8n-data/chunks/n8n_part_* > "$N8N_DIR/database.sqlite"
    
    # استعادة المفاتيح
    cp repo/n8n-data/.n8n-encryption-key "$N8N_DIR/" 2>/dev/null || true
    cp repo/n8n-data/encryptionKey "$N8N_DIR/" 2>/dev/null || true
    cp repo/n8n-data/config "$N8N_DIR/" 2>/dev/null || true
    
    echo "✨ تمت الاستعادة الكاملة!"
fi

# 🔥 توفير الذاكرة: حذف مجلد الـ repo فوراً
rm -rf "$WORK/repo"

# نظام المراقبة اللحظي (كل 15 ثانية)
(
    while true; do
        sleep 15
        if [ -f "$N8N_DIR/database.sqlite" ]; then
            /scripts/backup.sh > /dev/null 2>&1
        fi
    done
) &

echo "🚀 انطلاق n8n..."
exec n8n start
