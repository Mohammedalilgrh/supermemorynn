#!/bin/bash

# ============================================
# نظام التخزين المتعدد - مساحة لا محدودة!
# ============================================

MAX_REPO_SIZE_MB=4500  # 4.5GB حد أقصى لكل ريبو (نخلي 500MB احتياط)
N8N_DIR="/home/node/.n8n"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
TIMESTAMP=$(date +"%Y-%m-%d_%H:%M:%S")

# ============================================
# الدالة: حساب حجم المجلد
# ============================================
get_dir_size_mb() {
    du -sm "$1" 2>/dev/null | cut -f1
}

# ============================================
# الدالة: حساب حجم الريبو على GitHub
# ============================================
get_repo_size_mb() {
    local repo_name="$1"
    local response=$(curl -s \
        -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/${GITHUB_REPO_OWNER}/${repo_name}")
    
    echo "$response" | jq '.size // 0' 2>/dev/null | awk '{printf "%.0f", $1/1024}'
}

# ============================================
# الدالة: إنشاء ريبو جديد تلقائياً
# ============================================
create_new_repo() {
    local repo_name="$1"
    
    echo "🆕 إنشاء ريبو جديد: $repo_name"
    
    curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/user/repos" \
        -d "{
            \"name\": \"$repo_name\",
            \"private\": true,
            \"description\": \"n8n Auto Backup Storage - $(date)\",
            \"auto_init\": true
        }"
    
    echo "✅ تم إنشاء $repo_name"
    sleep 2
}

# ============================================
# الدالة: إيجاد الريبو المناسب
# ============================================
find_available_repo() {
    local base_name="${GITHUB_REPO_NAME:-n8n-storage}"
    local needed_mb="$1"
    
    # جرّب الريبو الأساسي أولاً
    local current_size=$(get_repo_size_mb "$base_name")
    
    if [ "$current_size" -lt "$MAX_REPO_SIZE_MB" ]; then
        local remaining=$((MAX_REPO_SIZE_MB - current_size))
        if [ "$remaining" -gt "$needed_mb" ]; then
            echo "$base_name"
            return
        fi
    fi
    
    # جرّب ريبوهات إضافية
    for i in $(seq 2 100); do
        local repo_name="${base_name}-${i}"
        
        # تحقق إذا الريبو موجود
        local response=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/${GITHUB_REPO_OWNER}/${repo_name}")
        
        if [ "$response" == "404" ]; then
            # ريبو مو موجود، نسويه
            create_new_repo "$repo_name"
            echo "$repo_name"
            return
        fi
        
        # تحقق من الحجم
        local repo_size=$(get_repo_size_mb "$repo_name")
        if [ "$repo_size" -lt "$MAX_REPO_SIZE_MB" ]; then
            local remaining=$((MAX_REPO_SIZE_MB - repo_size))
            if [ "$remaining" -gt "$needed_mb" ]; then
                echo "$repo_name"
                return
            fi
        fi
    done
    
    echo "ERROR"
}

# ============================================
# الدالة: النسخ الاحتياطي الذكي
# ============================================
smart_backup() {
    echo "🧠 بدء النسخ الاحتياطي الذكي..."
    
    # حساب حجم البيانات
    local data_size_mb=$(get_dir_size_mb "$N8N_DIR")
    echo "📊 حجم البيانات: ${data_size_mb}MB"
    
    # إيجاد ريبو مناسب
    local target_repo=$(find_available_repo "$data_size_mb")
    
    if [ "$target_repo" == "ERROR" ]; then
        echo "❌ ما لگينا ريبو مناسب!"
        return 1
    fi
    
    echo "📦 الريبو المستهدف: $target_repo"
    
    local REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${target_repo}.git"
    local WORK_DIR="/tmp/backup_${target_repo}"
    
    # استنساخ أو تحديث
    rm -rf "$WORK_DIR"
    if ! git clone --branch "$GITHUB_BRANCH" --depth 1 "$REPO_URL" "$WORK_DIR" 2>/dev/null; then
        mkdir -p "$WORK_DIR"
        cd "$WORK_DIR"
        git init
        git checkout -b "$GITHUB_BRANCH"
        git remote add origin "$REPO_URL"
    fi
    
    cd "$WORK_DIR"
    mkdir -p n8n-data
    
    # نسخ البيانات
    if [ -f "$N8N_DIR/database.sqlite" ]; then
        cp "$N8N_DIR/database.sqlite" n8n-data/
    fi
    
    for f in ".n8n-encryption-key" "encryptionKey" "config"; do
        [ -f "$N8N_DIR/$f" ] && cp "$N8N_DIR/$f" n8n-data/
    done
    
    for d in "custom" "nodes"; do
        [ -d "$N8N_DIR/$d" ] && cp -r "$N8N_DIR/$d" n8n-data/
    done
    
    # إحصائيات
    cat > n8n-data/stats.json << EOF
{
    "timestamp": "$TIMESTAMP",
    "repo": "$target_repo",
    "size_mb": $data_size_mb,
    "repo_size_mb": $(get_repo_size_mb "$target_repo")
}
EOF
    
    # حفظ خريطة الريبوهات
    cat > n8n-data/repo_map.json << EOF
{
    "primary_repo": "${GITHUB_REPO_NAME:-n8n-storage}",
    "current_repo": "$target_repo",
    "last_backup": "$TIMESTAMP",
    "max_repo_size_mb": $MAX_REPO_SIZE_MB
}
EOF
    
    # رفع
    git add -A
    if ! git diff --staged --quiet; then
        git commit -m "💾 نسخة احتياطية - $TIMESTAMP"
        git push origin "$GITHUB_BRANCH" 2>/dev/null || \
        git push -f origin "$GITHUB_BRANCH" 2>/dev/null
        echo "✅ تم الحفظ في $target_repo"
    else
        echo "ℹ️ لا تغييرات"
    fi
    
    # تنظيف
    rm -rf "$WORK_DIR"
}

# تشغيل
smart_backup
