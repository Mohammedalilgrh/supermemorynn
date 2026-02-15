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

# ═══════════════════════════════════════════════════════════
# 🔒 إضافات الحماية الكاملة - لا شيء يضيع أبداً
# ═══════════════════════════════════════════════════════════
VERSIONS_DIR="$WORK/versions"
HISTORY_DIR="$WORK/history"
SAFE_BACKUP="$WORK/safe_backup"
HISTORY_LOG="$HISTORY_DIR/all_changes.log"
mkdir -p "$VERSIONS_DIR" "$HISTORY_DIR" "$SAFE_BACKUP"

# 🛡️ دالة حفظ نسخة آمنة قبل أي عملية
save_safe_copy() {
    if [ -f "$N8N_DIR/database.sqlite" ]; then
        SAFE_HASH=$(sha256sum "$N8N_DIR/database.sqlite" | cut -d' ' -f1)
        SAFE_SIZE=$(stat -c%s "$N8N_DIR/database.sqlite" 2>/dev/null)
        SAFE_TIME=$(date +%s)
        
        # حفظ نسخة بالـ hash
        if [ ! -f "$VERSIONS_DIR/${SAFE_HASH}.sqlite" ]; then
            cp "$N8N_DIR/database.sqlite" "$VERSIONS_DIR/${SAFE_HASH}.sqlite"
            echo "${SAFE_TIME}|${SAFE_HASH}|${SAFE_SIZE}|$(date)" >> "$HISTORY_LOG"
            echo "💾 حفظ نسخة: ${SAFE_HASH:0:12}..."
        fi
        
        # حفظ نسخة بالتاريخ للسهولة
        cp "$N8N_DIR/database.sqlite" "$SAFE_BACKUP/db_$(date +%Y%m%d_%H%M%S).sqlite"
    fi
}

# 🔍 دالة فحص صحة الداتابيس
check_db_integrity() {
    if [ -f "$1" ]; then
        RESULT=$(sqlite3 "$1" "PRAGMA integrity_check;" 2>/dev/null)
        if echo "$RESULT" | grep -q "ok"; then
            echo "valid"
        else
            echo "corrupt"
        fi
    else
        echo "missing"
    fi
}

# 📊 حفظ نسخة آمنة قبل البدء
save_safe_copy

# 🧹 تنظيف النسخ القديمة (الاحتفاظ بآخر 20 نسخة)
cleanup_old_versions() {
    ls -t "$SAFE_BACKUP"/db_*.sqlite 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
    ls -t "$VERSIONS_DIR"/*.sqlite 2>/dev/null | tail -n +50 | xargs rm -f 2>/dev/null || true
}
cleanup_old_versions
# ═══════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════
# 🛡️ فحص صحة الداتابيس قبل المتابعة
# ═══════════════════════════════════════════════════════════
DB_STATUS=$(check_db_integrity "$N8N_DIR/database.sqlite")
if [ "$DB_STATUS" = "corrupt" ]; then
    echo "⚠️ تحذير: الداتابيس قد يكون تالف!"
    echo "$(date)|CORRUPT|$DB_HASH" >> "$HISTORY_LOG"
fi
# ═══════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════
# 🔒 حفظ نسخ الطوارئ على GitHub
# ═══════════════════════════════════════════════════════════
mkdir -p "$DATA_DIR/emergency"

# حفظ آخر 3 نسخ صالحة
EMERGENCY_COUNT=0
for version_file in $(ls -t "$VERSIONS_DIR"/*.sqlite 2>/dev/null | head -3); do
    if [ -f "$version_file" ] && [ "$(check_db_integrity "$version_file")" = "valid" ]; then
        EMERGENCY_COUNT=$((EMERGENCY_COUNT + 1))
        cp "$version_file" "$DATA_DIR/emergency/backup_${EMERGENCY_COUNT}.sqlite"
    fi
done

# حفظ سجل التاريخ
cp "$HISTORY_LOG" "$DATA_DIR/history.log" 2>/dev/null || true

# حفظ قائمة بجميع النسخ المتاحة
ls -la "$VERSIONS_DIR"/*.sqlite 2>/dev/null > "$DATA_DIR/available_versions.txt" || true
# ═══════════════════════════════════════════════════════════

# 📝 حفظ معلومات الحالة
cat > "$DATA_DIR/backup_info.txt" <<EOF
TIMESTAMP=$TIMESTAMP
DB_SIZE_MB=$DB_SIZE_MB
DB_HASH=$DB_HASH
USE_CHUNKS=$USE_CHUNKS
REPO=$CURRENT_REPO
DB_STATUS=$DB_STATUS
EMERGENCY_COPIES=$EMERGENCY_COUNT
EOF

# 💾 تحديث ملف الحالة المحلي
cat > "$STATE_FILE" <<EOF
LAST_HASH=$DB_HASH
LAST_SIZE=$DB_SIZE_MB
USE_CHUNKS=$USE_CHUNKS
LAST_BACKUP=$TIMESTAMP
DB_STATUS=$DB_STATUS
EOF

# ═══════════════════════════════════════════════════════════
# 🛡️ حفظ نسخة احتياطية من الحالة
# ═══════════════════════════════════════════════════════════
cp "$STATE_FILE" "$STATE_FILE.backup"
cp "$STATE_FILE" "$HISTORY_DIR/state_$(date +%Y%m%d_%H%M%S).state"
# ═══════════════════════════════════════════════════════════

# 5️⃣ الرفع لـ GitHub
git add -A
if ! git diff --staged --quiet; then
    git commit -m "💎 Master Backup - $TIMESTAMP [Size: ${DB_SIZE_MB}MB]"
    
    # ═══════════════════════════════════════════════════════════
    # 🔄 محاولة الرفع مع إعادة المحاولة
    # ═══════════════════════════════════════════════════════════
    PUSH_SUCCESS=false
    for attempt in 1 2 3; do
        if git push origin main -f 2>/dev/null; then
            PUSH_SUCCESS=true
            break
        fi
        echo "⏳ محاولة الرفع $attempt/3..."
        sleep 2
    done
    
    if [ "$PUSH_SUCCESS" = true ]; then
        echo "✅ تم الحفظ الشامل في $CURRENT_REPO"
        echo "$(date)|PUSH_SUCCESS|$DB_HASH" >> "$HISTORY_LOG"
    else
        echo "⚠️ فشل الرفع! النسخة محفوظة محلياً"
        echo "$(date)|PUSH_FAILED|$DB_HASH" >> "$HISTORY_LOG"
    fi
    # ═══════════════════════════════════════════════════════════
fi

echo "🏁 اكتمل النسخ الاحتياطي"
