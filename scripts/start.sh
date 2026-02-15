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

    # ✅ إضافة التحسين الجديد هنا (دون حذف أي شيء)
    # 🧩 تقنية الاستعادة التكيفية للملفات
    restore_with_smart_detection() {
        local source_dir="$WORK/repo/n8n-data"
        
        # استعادة الملفات الكاملة أولاً
        for file in "$source_dir"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                case "$filename" in
                    *.gz)
                        echo "📦 استعادة ملف مضغوط: $filename"
                        gunzip -c "$file" > "$N8N_DIR/${filename%.gz}"
                        ;;
                    *.sql)
                        echo "📦 استعادة نسخة SQL: $filename"
                        cp "$file" "$N8N_DIR/database.sqlite.restore"
                        sqlite3 "$N8N_DIR/database.sqlite" < "$file"
                        ;;
                    *)
                        echo "📦 استعادة ملف كامل: $filename"
                        cp "$file" "$N8N_DIR/$filename"
                        ;;
                esac
            fi
        done
        
        # تجميع الأجزاء إذا كانت موجودة
        if [ -d "$source_dir/chunks" ]; then
            for basefile in database.sqlite .n8n-encryption-key encryptionKey config; do
                if ls "$source_dir/chunks/${basefile}_part_"* 1> /dev/null 2>&1; then
                    echo "🧩 تجميع أجزاء $basefile..."
                    cat "$source_dir/chunks/${basefile}_part_"* > "$N8N_DIR/$basefile"
                fi
            done
        fi
    }

    # استخدم الدالة الجديدة
    restore_with_smart_detection

    # 🔥 الكود الأصلي كامل كما هو (لم أحذف أي شيء)
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
