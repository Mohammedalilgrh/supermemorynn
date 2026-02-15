#!/bin/sh

# --- الإعدادات العبقرية ---
MAX_REPO_SIZE_MB=4000 # 4GB كحد أقصى للريبو الواحد لضمان الأمان
CHUNK_SIZE="40M"      # تقسيم الداتابيس لقطع 40 ميجا لسهولة التدفق (Streaming)
N8N_DIR="/home/node/.n8n"
WORK="/backup-data"
TIMESTAMP=$(date +"%Y-%m-%d_%H:%M:%S")

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

# 4️⃣ نسخ المفاتيح والإعدادات
cp "$N8N_DIR"/.n8n-encryption-key "$DATA_DIR/" 2>/dev/null || true
cp "$N8N_DIR"/encryptionKey "$DATA_DIR/" 2>/dev/null || true
cp "$N8N_DIR"/config "$DATA_DIR/" 2>/dev/null || true

# 5️⃣ الرفع لـ GitHub
git add -A
if ! git diff --staged --quiet; then
    git commit -m "💎 Master Backup - $TIMESTAMP"
    git push origin main -f
    echo "✅ تم الحفظ الشامل في $CURRENT_REPO"
fi
