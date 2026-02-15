#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"
WORK="/backup-data"
STATE_FILE="$WORK/.backup_state"

# البحث عن آخر ريبو تم استخدامه (نظام الـ Multi-Repo)
# إذا كان لديك ريبوهات متعددة، نوصي بوضع اسم الريبو الأساسي هنا
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

mkdir -p "$N8N_DIR"
cd "$WORK"

echo "🛰️ بدء سحب البيانات بتقنية الـ Streaming..."
git clone --depth 1 "$REPO_URL" repo 2>/dev/null || echo "أول تشغيل"

if [ -d "repo/n8n-data" ]; then
    # 🧠 قراءة معلومات النسخة الاحتياطية
    if [ -f "repo/n8n-data/backup_info.txt" ]; then
        echo "📋 قراءة معلومات النسخة الاحتياطية..."
        cat "repo/n8n-data/backup_info.txt"
        USE_CHUNKS=$(grep "USE_CHUNKS=" "repo/n8n-data/backup_info.txt" 2>/dev/null | cut -d'=' -f2)
    fi
    
    # 🎯 الاستعادة الذكية حسب نوع النسخة
    if [ "$USE_CHUNKS" = "true" ] || [ -d "repo/n8n-data/chunks" ] && [ ! -f "repo/n8n-data/database.sqlite" ]; then
        echo "🧩 تجميع أجزاء الداتابيس (توفير الرام)..."
        # 🔥 تقنية الـ Streaming: تجميع القطع مباشرة إلى الملف دون تحميلها للذاكرة
        cat repo/n8n-data/chunks/n8n_part_* > "$N8N_DIR/database.sqlite"
    elif [ -f "repo/n8n-data/database.sqlite" ]; then
        echo "📦 استعادة النسخة الكاملة..."
        cp "repo/n8n-data/database.sqlite" "$N8N_DIR/database.sqlite"
    elif [ -f "repo/n8n-data/full_backup.sql" ]; then
        echo "🗄️ استعادة من SQL dump..."
        rm -f "$N8N_DIR/database.sqlite"
        sqlite3 "$N8N_DIR/database.sqlite" < "repo/n8n-data/full_backup.sql"
    fi
    
    # استعادة المفاتيح
    cp repo/n8n-data/.n8n-encryption-key "$N8N_DIR/" 2>/dev/null || true
    cp repo/n8n-data/encryptionKey "$N8N_DIR/" 2>/dev/null || true
    cp repo/n8n-data/config "$N8N_DIR/" 2>/dev/null || true
    
    # 💾 حفظ معلومات الحالة المحلية
    if [ -f "repo/n8n-data/backup_info.txt" ]; then
        cp "repo/n8n-data/backup_info.txt" "$STATE_FILE"
    fi
    
    echo "✨ تمت الاستعادة الكاملة!"
fi

# 🔥 توفير الذاكرة: حذف مجلد الـ repo فوراً
rm -rf "$WORK/repo"

# 🧠 نظام المراقبة الذكي مع الذاكرة
MONITOR_INTERVAL=15
LAST_CHECK=""

# تهيئة LAST_CHECK من الحالة المحفوظة
if [ -f "$STATE_FILE" ]; then
    LAST_CHECK=$(grep "LAST_HASH=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
fi

# نظام المراقبة اللحظي (كل 15 ثانية) مع فحص التغييرات
(
    while true; do
        sleep $MONITOR_INTERVAL
        if [ -f "$N8N_DIR/database.sqlite" ]; then
            # 🔍 فحص هل الملف تغير قبل عمل backup
            CURRENT_HASH=$(sha256sum "$N8N_DIR/database.sqlite" 2>/dev/null | cut -d' ' -f1)
            if [ "$CURRENT_HASH" != "$LAST_CHECK" ]; then
                echo "🔄 تم اكتشاف تغييرات - بدء النسخ الاحتياطي..."
                /scripts/backup.sh > /dev/null 2>&1 && LAST_CHECK="$CURRENT_HASH"
            else
                echo "✓ لا توجد تغييرات - تخطي النسخ الاحتياطي"
            fi
        fi
    done
) &

echo "🚀 انطلاق n8n..."
exec n8n start
