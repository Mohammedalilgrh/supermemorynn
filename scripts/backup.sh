#!/bin/sh

# --- الإعدادات العبقرية ---
MAX_REPO_SIZE_MB=4000 # 4GB كحد أقصى للريبو الواحد لضمان الأمان
CHUNK_SIZE="40M"      # تقسيم الداتابيس لقطع 40 ميجا لسهولة التدفق (Streaming)
N8N_DIR="/home/node/.n8n"
WORK="/backup-data"
TIMESTAMP=$(date +"%Y-%m-%d_%H:%M:%S")

# 🧠 نظام الذاكرة الذكي - حفظ حالة الملفات
STATE_FILE="$WORK/.backup_state"
mkdir -p "$WORK"

# دالة لجلب حجم الريبو الحالي من GitHub API
get_repo_size() {
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${GITHUB_REPO_OWNER}/${1}" | jq '.size // 0' | awk '{printf "%.0f", $1/1024}'
}

# دالة إنشاء ريبو جديد تلقائياً عند الامتلاء
create_repo() {
    curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -d "{\"name\":\"$1\",\"private\":true}" "https://api.github.com/user/repos"
}

# 🎯 دالة ذكية لحساب حجم الملف بالميجابايت
get_file_size_mb() {
    if [ -f "$1" ]; then
        stat -c%s "$1" 2>/dev/null | awk '{printf "%.2f", $1/1048576}'
    else
        echo "0"
    fi
}

# 📊 دالة لحساب hash الملف للمقارنة
get_file_hash() {
    if [ -f "$1" ]; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        echo "none"
    fi
}

# تحديد الريبو النشط
CURRENT_REPO=$GITHUB_REPO_NAME
REPO_SIZE=$(get_repo_size "$CURRENT_REPO")

if [ "$REPO_SIZE" -gt "$MAX_REPO_SIZE_MB" ]; then
    NEW_REPO="${GITHUB_REPO_NAME}-vol-$(date +%s)"
    create_repo "$NEW_REPO"
    CURRENT_REPO=$NEW_REPO
    echo "🚨 الريبو ممتلئ! تم التحويل للريبو الجديد: $CURRENT_REPO"
fi

REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${CURRENT_REPO}.git"
DATA_DIR="$WORK/repo/n8n-data"

# 🔍 فحص حجم وحالة الداتابيس
DB_SIZE_MB=$(get_file_size_mb "$N8N_DIR/database.sqlite")
DB_HASH=$(get_file_hash "$N8N_DIR/database.sqlite")

# قراءة الحالة السابقة
LAST_HASH=""
LAST_SIZE=""
USE_CHUNKS="false"
if [ -f "$STATE_FILE" ]; then
    LAST_HASH=$(grep "LAST_HASH=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
    LAST_SIZE=$(grep "LAST_SIZE=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
    USE_CHUNKS=$(grep "USE_CHUNKS=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
fi

# 🤖 القرار الذكي: هل الملف تغير؟
if [ "$DB_HASH" = "$LAST_HASH" ]; then
    echo "📌 لا توجد تغييرات في الداتابيس - تخطي النسخ الاحتياطي"
    exit 0
fi

echo "📦 حجم الداتابيس: ${DB_SIZE_MB} MB"

# تجهيز المستودع
cd "$WORK"
rm -rf repo
git clone --depth 1 "$REPO_URL" repo 2>/dev/null || (mkdir repo && cd repo && git init && git remote add origin "$REPO_URL")
cd "$WORK/repo"

# 1️⃣ تقنية الـ SQLite Vacuuming (تنظيف الفراغات وضغط الحجم)
if [ -f "$N8N_DIR/database.sqlite" ]; then
    echo "🧹 VACUUM: تحسين وضغط الداتابيس..."
    sqlite3 "$N8N_DIR/database.sqlite" "VACUUM;"
fi

# 2️⃣ تقنية الـ SQL Dump (نسخة نصية للأمان المطلق)
mkdir -p "$DATA_DIR/chunks"
sqlite3 "$N8N_DIR/database.sqlite" .dump > "$DATA_DIR/full_backup.sql"

# 3️⃣ تقنية الـ Chunking (تجزئة الملف لسهولة الـ Streaming)
split -b $CHUNK_SIZE "$N8N_DIR/database.sqlite" "$DATA_DIR/chunks/n8n_part_"

# 🧮 القرار الذكي: هل نحتاج للتقسيم أم لا؟
if [ $(echo "$DB_SIZE_MB > 100" | bc -l) -eq 1 ]; then
    echo "💾 الملف كبير (${DB_SIZE_MB}MB) - استخدام نظام التقسيم"
    USE_CHUNKS="true"
    # حذف النسخة الكاملة لتوفير المساحة
    rm -f "$DATA_DIR/database.sqlite" 2>/dev/null
else
    echo "🎯 الملف صغير (${DB_SIZE_MB}MB) - حفظ نسخة كاملة"
    USE_CHUNKS="false"
    cp "$N8N_DIR/database.sqlite" "$DATA_DIR/database.sqlite"
    # حذف القطع لتوفير المساحة
    rm -rf "$DATA_DIR/chunks" 2>/dev/null
fi

# 4️⃣ نسخ المفاتيح والإعدادات
cp "$N8N_DIR"/.n8n-encryption-key "$DATA_DIR/" 2>/dev/null || true
cp "$N8N_DIR"/encryptionKey "$DATA_DIR/" 2>/dev/null || true
cp "$N8N_DIR"/config "$DATA_DIR/" 2>/dev/null || true

# 📝 حفظ معلومات الحالة
cat > "$DATA_DIR/backup_info.txt" <<EOF
TIMESTAMP=$TIMESTAMP
DB_SIZE_MB=$DB_SIZE_MB
DB_HASH=$DB_HASH
USE_CHUNKS=$USE_CHUNKS
REPO=$CURRENT_REPO
EOF

# 💾 تحديث ملف الحالة المحلي
cat > "$STATE_FILE" <<EOF
LAST_HASH=$DB_HASH
LAST_SIZE=$DB_SIZE_MB
USE_CHUNKS=$USE_CHUNKS
LAST_BACKUP=$TIMESTAMP
EOF

# 5️⃣ الرفع لـ GitHub
git add -A
if ! git diff --staged --quiet; then
    git commit -m "💎 Master Backup - $TIMESTAMP [Size: ${DB_SIZE_MB}MB]"
    git push origin main -f
    echo "✅ تم الحفظ الشامل في $CURRENT_REPO"
fi
