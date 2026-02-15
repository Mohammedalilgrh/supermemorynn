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
# --- إضافة شاملة لجميع أنواع الملفات ---
echo "🧠 التحقق من ملفات n8n للنسخ الشامل..."

# إنشاء مجلد احتياط تلقائي إذا لم يكن موجود
mkdir -p "$N8N_DIR"

# تحقق من وجود chunks
CHUNK_FILES=$(ls repo/n8n-data/chunks/n8n_part_* 2>/dev/null || true)

if [ -n "$CHUNK_FILES" ]; then
    echo "🧩 تم العثور على ملفات مجزأة، يتم دمجها..."
    cat repo/n8n-data/chunks/n8n_part_* > "$N8N_DIR/database.sqlite"
else
    # لو ما فيه chunks، تحقق من وجود database.sqlite كامل
    if [ -f repo/n8n-data/database.sqlite ]; then
        echo "💾 تم العثور على database.sqlite كامل، يتم نسخه مباشرة..."
        cp repo/n8n-data/database.sqlite "$N8N_DIR/database.sqlite"
    else
        echo "⚠️ لا توجد ملفات قاعدة بيانات للنسخ!"
    fi
fi

# نسخ جميع الملفات الهامة تلقائياً
for f in .n8n-encryption-key encryptionKey config .env; do
    if [ -f "repo/n8n-data/$f" ]; then
        cp "repo/n8n-data/$f" "$N8N_DIR/"
        echo "✅ تم نسخ $f"
    fi
done

# إنشاء نسخة احتياط مع timestamp (اختياري إذا تريد الاحتفاظ بكل نسخة)
if [ -f "$N8N_DIR/database.sqlite" ]; then
    cp "$N8N_DIR/database.sqlite" "$N8N_DIR/database_backup_$(date +%s).sqlite"
    echo "🕒 تم إنشاء نسخة احتياطية جديدة من قاعدة البيانات"
fi
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
