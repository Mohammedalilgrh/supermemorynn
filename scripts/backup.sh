#!/bin/bash

# ============================================
# سكربت النسخ الاحتياطي التلقائي
# ============================================

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="/home/node/.n8n"
BACKUP_DIR="/n8n-backup"
REPO_DIR="$BACKUP_DIR/repo"
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
DATA_DIR="$REPO_DIR/n8n-data"

echo "🔄 بدء النسخ الاحتياطي - $TIMESTAMP"

# التحقق من وجود الريبو
if [ ! -d "$REPO_DIR/.git" ]; then
    echo "📥 استنساخ الريبو..."
    cd "$BACKUP_DIR"
    rm -rf repo
    if ! git clone --branch "$GITHUB_BRANCH" --single-branch "$REPO_URL" repo 2>/dev/null; then
        mkdir -p repo
        cd repo
        git init
        git checkout -b "$GITHUB_BRANCH"
        git remote add origin "$REPO_URL"
        cd "$BACKUP_DIR"
    fi
fi

cd "$REPO_DIR"

# تحديث الريبو
git pull origin "$GITHUB_BRANCH" 2>/dev/null || true

# إنشاء مجلد البيانات
mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/workflows"
mkdir -p "$DATA_DIR/credentials"
mkdir -p "$DATA_DIR/custom"

# ============================================
# نسخ قاعدة البيانات (الأهم!)
# ============================================
if [ -f "$N8N_DIR/database.sqlite" ]; then
    # نسخ آمن للداتابيس وهي شغالة
    cp "$N8N_DIR/database.sqlite" "$DATA_DIR/database.sqlite"
    
    # حساب حجم الداتابيس
    DB_SIZE=$(du -sh "$DATA_DIR/database.sqlite" 2>/dev/null | cut -f1)
    echo "   ✅ قاعدة البيانات ($DB_SIZE)"
    
    # إذا الداتابيس كبيرة (أكثر من 50MB)، نقسمها
    DB_SIZE_BYTES=$(stat -f%z "$DATA_DIR/database.sqlite" 2>/dev/null || stat -c%s "$DATA_DIR/database.sqlite" 2>/dev/null || echo "0")
    
    if [ "$DB_SIZE_BYTES" -gt 52428800 ]; then
        echo "   📦 الداتابيس كبيرة، جاري التقسيم..."
        
        # ضغط أولاً
        gzip -c "$DATA_DIR/database.sqlite" > "$DATA_DIR/database.sqlite.gz"
        
        GZ_SIZE=$(du -sh "$DATA_DIR/database.sqlite.gz" 2>/dev/null | cut -f1)
        echo "   📦 حجم مضغوط: $GZ_SIZE"
        
        # إذا لسه كبيرة بعد الضغط، نقسمها
        GZ_SIZE_BYTES=$(stat -f%z "$DATA_DIR/database.sqlite.gz" 2>/dev/null || stat -c%s "$DATA_DIR/database.sqlite.gz" 2>/dev/null || echo "0")
        
        if [ "$GZ_SIZE_BYTES" -gt 52428800 ]; then
            echo "   ✂️ تقسيم الملف..."
            mkdir -p "$DATA_DIR/db-chunks"
            split -b 45M "$DATA_DIR/database.sqlite.gz" "$DATA_DIR/db-chunks/chunk_"
            CHUNKS=$(ls "$DATA_DIR/db-chunks/" | wc -l)
            echo "   ✅ تم التقسيم إلى $CHUNKS أجزاء"
            
            # حفظ معلومات التقسيم
            echo "{\"chunks\": $CHUNKS, \"timestamp\": \"$TIMESTAMP\", \"original_size\": $DB_SIZE_BYTES}" > "$DATA_DIR/db-chunks/meta.json"
        fi
        
        # حذف النسخة غير المضغوطة الكبيرة
        rm -f "$DATA_DIR/database.sqlite"
    fi
else
    echo "   ℹ️ لا توجد قاعدة بيانات بعد"
fi

# ============================================
# نسخ مفاتيح التشفير (مهم جداً!)
# ============================================
for keyfile in ".n8n-encryption-key" "encryptionKey"; do
    if [ -f "$N8N_DIR/$keyfile" ]; then
        cp "$N8N_DIR/$keyfile" "$DATA_DIR/"
        echo "   ✅ مفتاح التشفير: $keyfile"
    fi
done

# ============================================
# نسخ ملف الإعدادات
# ============================================
if [ -f "$N8N_DIR/config" ]; then
    cp "$N8N_DIR/config" "$DATA_DIR/"
    echo "   ✅ ملف الإعدادات"
fi

# ============================================
# تصدير Workflows عبر API (أفضل طريقة)
# ============================================
N8N_PORT="${N8N_PORT:-5678}"
N8N_URL="http://localhost:$N8N_PORT"

# محاولة تصدير عبر API
if curl -s "$N8N_URL/healthz" > /dev/null 2>&1; then
    echo "   📡 n8n شغال، جاري تصدير Workflows عبر API..."
    
    # تصدير كل الـ workflows
    WORKFLOWS=$(curl -s "$N8N_URL/api/v1/workflows" \
        -H "Accept: application/json" 2>/dev/null)
    
    if [ ! -z "$WORKFLOWS" ] && [ "$WORKFLOWS" != "null" ]; then
        echo "$WORKFLOWS" > "$DATA_DIR/workflows/all_workflows.json"
        
        # عدد الـ workflows
        WF_COUNT=$(echo "$WORKFLOWS" | jq '.data | length' 2>/dev/null || echo "?")
        echo "   ✅ تم تصدير $WF_COUNT workflow"
        
        # تصدير كل workflow على حدة
        echo "$WORKFLOWS" | jq -r '.data[]?.id' 2>/dev/null | while read wf_id; do
            if [ ! -z "$wf_id" ] && [ "$wf_id" != "null" ]; then
                WF_DATA=$(curl -s "$N8N_URL/api/v1/workflows/$wf_id" 2>/dev/null)
                if [ ! -z "$WF_DATA" ]; then
                    WF_NAME=$(echo "$WF_DATA" | jq -r '.data.name // .name // "unnamed"' 2>/dev/null | tr ' /' '_-')
                    echo "$WF_DATA" > "$DATA_DIR/workflows/${wf_id}_${WF_NAME}.json"
                fi
            fi
        done
    fi
    
    # تصدير Credentials (بدون القيم السرية)
    CREDS=$(curl -s "$N8N_URL/api/v1/credentials" \
        -H "Accept: application/json" 2>/dev/null)
    
    if [ ! -z "$CREDS" ] && [ "$CREDS" != "null" ]; then
        echo "$CREDS" > "$DATA_DIR/credentials/all_credentials.json"
        CRED_COUNT=$(echo "$CREDS" | jq '.data | length' 2>/dev/null || echo "?")
        echo "   ✅ تم تصدير $CRED_COUNT credential"
    fi
else
    echo "   ⚠️ n8n مو شغال بعد، نسخ الملفات مباشرة..."
fi

# ============================================
# نسخ أي ملفات إضافية
# ============================================

# ملفات nodes مخصصة
if [ -d "$N8N_DIR/custom" ]; then
    cp -r "$N8N_DIR/custom" "$DATA_DIR/"
    echo "   ✅ ملفات مخصصة"
fi

if [ -d "$N8N_DIR/nodes" ]; then
    cp -r "$N8N_DIR/nodes" "$DATA_DIR/custom-nodes"
    echo "   ✅ Nodes مخصصة"
fi

#######################################################################
# أضف هذا في backup.sh
# ============================================
# تنظيف السجل القديم لتوفير المساحة
# ============================================
clean_git_history() {
    echo "🧹 تنظيف سجل Git القديم..."
    
    cd "$REPO_DIR"
    
    # حجم الريبو الحالي
    REPO_SIZE=$(du -sm .git | cut -f1)
    echo "   حجم .git: ${REPO_SIZE}MB"
    
    # إذا أكثر من 3GB، ننظف
    if [ "$REPO_SIZE" -gt 3000 ]; then
        echo "   ⚠️ الريبو كبير، جاري التنظيف..."
        
        # نخلي commit واحد بس (آخر نسخة)
        git checkout --orphan temp_branch
        git add -A
        git commit -m "🧹 تنظيف - $(date)"
        git branch -D "$GITHUB_BRANCH"
        git branch -m "$GITHUB_BRANCH"
        git gc --aggressive --prune=all
        git push -f origin "$GITHUB_BRANCH"
        
        NEW_SIZE=$(du -sm .git | cut -f1)
        echo "   ✅ تم التنظيف: ${REPO_SIZE}MB → ${NEW_SIZE}MB"
    fi
}
# ============================================
# إحصائيات
# ============================================
TOTAL_SIZE=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
FILE_COUNT=$(find "$DATA_DIR" -type f | wc -l)

# حفظ الإحصائيات
cat > "$DATA_DIR/stats.json" << EOF
{
    "last_backup": "$TIMESTAMP",
    "total_size": "$TOTAL_SIZE",
    "total_files": $FILE_COUNT,
    "workflows_exported": true,
    "database_backed_up": true,
    "encryption_keys_saved": true,
    "backup_number": $(cat "$DATA_DIR/backup_count.txt" 2>/dev/null || echo "0")
}
EOF

# عداد النسخ الاحتياطية
COUNT=$(cat "$DATA_DIR/backup_count.txt" 2>/dev/null || echo "0")
echo $((COUNT + 1)) > "$DATA_DIR/backup_count.txt"

# ============================================
# رفع على GitHub
# ============================================
echo "   📤 جاري الرفع على GitHub..."

cd "$REPO_DIR"

# إضافة كل التغييرات
git add -A

# التحقق من وجود تغييرات
if git diff --staged --quiet 2>/dev/null; then
    echo "   ℹ️ لا توجد تغييرات جديدة"
else
    # Commit
    COMMIT_MSG="💾 نسخة احتياطية - $TIMESTAMP | $TOTAL_SIZE | $FILE_COUNT ملف"
    git commit -m "$COMMIT_MSG" 2>/dev/null
    
    # Push
    if git push origin "$GITHUB_BRANCH" 2>/dev/null; then
        echo "   ✅ تم الرفع على GitHub بنجاح!"
    else
        echo "   ⚠️ فشل الرفع، محاولة force push..."
        git push -f origin "$GITHUB_BRANCH" 2>/dev/null || echo "   ❌ فشل الرفع"
    fi
fi

echo "🔄 اكتمل النسخ الاحتياطي - $TOTAL_SIZE في $FILE_COUNT ملف"
echo "---"
