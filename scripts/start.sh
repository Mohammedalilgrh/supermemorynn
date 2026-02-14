#!/bin/bash
set -e

echo "============================================"
echo "🚀 بدء تشغيل n8n مع التخزين الدائم"
echo "============================================"

# ============================================
# التحقق من المتغيرات المطلوبة
# ============================================
if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ خطأ: GITHUB_TOKEN غير موجود!"
    exit 1
fi

if [ -z "$GITHUB_REPO_OWNER" ]; then
    echo "❌ خطأ: GITHUB_REPO_OWNER غير موجود!"
    exit 1
fi

if [ -z "$GITHUB_REPO_NAME" ]; then
    echo "❌ خطأ: GITHUB_REPO_NAME غير موجود!"
    exit 1
fi

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-120}"
N8N_DIR="/home/node/.n8n"
BACKUP_DIR="/backup-data"
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

echo "📋 الإعدادات:"
echo "   المالك: $GITHUB_REPO_OWNER"
echo "   الريبو: $GITHUB_REPO_NAME"
echo "   الفرع: $GITHUB_BRANCH"
echo "   فترة النسخ: كل ${BACKUP_INTERVAL} ثانية"

# ============================================
# إعداد Git
# ============================================
echo ""
echo "⚙️ إعداد Git..."
git config --global user.email "n8n-bot@automated.com"
git config --global user.name "n8n Auto Backup"
git config --global init.defaultBranch "$GITHUB_BRANCH"

# ============================================
# استعادة البيانات من GitHub
# ============================================
echo ""
echo "📥 جاري استعادة البيانات من GitHub..."

cd /backup-data

# محاولة استنساخ الريبو
if git clone --branch "$GITHUB_BRANCH" --single-branch "$REPO_URL" repo 2>/dev/null; then
    echo "✅ تم استنساخ الريبو بنجاح"
    
    # التحقق من وجود بيانات محفوظة
    if [ -d "repo/n8n-data" ]; then
        echo "📦 وُجدت بيانات محفوظة! جاري الاستعادة..."
        
        # استعادة قاعدة البيانات
        if [ -f "repo/n8n-data/database.sqlite" ]; then
            cp repo/n8n-data/database.sqlite "$N8N_DIR/database.sqlite"
            echo "   ✅ قاعدة البيانات"
        fi
        
        # استعادة ملف الإعدادات
        if [ -f "repo/n8n-data/config" ]; then
            cp repo/n8n-data/config "$N8N_DIR/config"
            echo "   ✅ الإعدادات"
        fi
        
        # استعادة المفاتيح
        if [ -f "repo/n8n-data/.n8n-encryption-key" ]; then
            cp "repo/n8n-data/.n8n-encryption-key" "$N8N_DIR/"
            echo "   ✅ مفتاح التشفير"
        fi

        if [ -f "repo/n8n-data/encryptionKey" ]; then
            cp "repo/n8n-data/encryptionKey" "$N8N_DIR/"
            echo "   ✅ مفتاح التشفير (2)"
        fi
        
        # استعادة الـ credentials
        if [ -d "repo/n8n-data/credentials" ]; then
            cp -r repo/n8n-data/credentials "$N8N_DIR/"
            echo "   ✅ بيانات الاعتماد"
        fi
        
        # استعادة workflows مصدّرة
        if [ -d "repo/n8n-data/workflows" ]; then
            cp -r repo/n8n-data/workflows "$N8N_DIR/"
            echo "   ✅ الـ Workflows"
        fi
        
        # استعادة أي ملفات إضافية
        if [ -d "repo/n8n-data/custom" ]; then
            cp -r repo/n8n-data/custom "$N8N_DIR/"
            echo "   ✅ ملفات مخصصة"
        fi

        # استعادة nodes مخصصة
        if [ -d "repo/n8n-data/custom-nodes" ]; then
            cp -r repo/n8n-data/custom-nodes "$N8N_DIR/"
            echo "   ✅ Nodes مخصصة"
        fi
        
        echo ""
        echo "✅ تمت الاستعادة بالكامل!"
        echo ""
        
        # عرض الإحصائيات
        if [ -f "repo/n8n-data/stats.json" ]; then
            echo "📊 آخر نسخة احتياطية:"
            cat repo/n8n-data/stats.json | jq . 2>/dev/null || cat repo/n8n-data/stats.json
            echo ""
        fi
    else
        echo "ℹ️ لا توجد بيانات محفوظة بعد (أول تشغيل)"
    fi
else
    echo "ℹ️ الريبو فارغ أو غير موجود، جاري التهيئة..."
    mkdir -p repo
    cd repo
    git init
    git checkout -b "$GITHUB_BRANCH"
    mkdir -p n8n-data
    echo '{"initialized": true, "date": "'$(date -Iseconds)'"}' > n8n-data/init.json
    git add .
    git commit -m "🆕 تهيئة ريبو التخزين"
    git remote add origin "$REPO_URL"
    git push -u origin "$GITHUB_BRANCH" 2>/dev/null || true
    cd /backup-data
fi

# ============================================
# تشغيل النسخ الاحتياطي التلقائي
# ============================================
echo ""
echo "⏰ بدء النسخ الاحتياطي التلقائي (كل ${BACKUP_INTERVAL} ثانية)..."

# تشغيل سكربت النسخ في الخلفية
(
    # انتظار حتى يبدأ n8n
    sleep 30
    echo "🔄 النسخ الاحتياطي التلقائي نشط الآن"
    
    while true; do
        sleep "$BACKUP_INTERVAL"
        /scripts/backup.sh 2>&1 | while read line; do
            echo "[BACKUP] $line"
        done
    done
) &

# ============================================
# حفظ عند الإغلاق
# ============================================
cleanup() {
    echo ""
    echo "🛑 جاري الإغلاق..."
    echo "💾 حفظ أخير للبيانات..."
    /scripts/backup.sh
    echo "✅ تم الحفظ. وداعاً!"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ============================================
# تشغيل n8n
# ============================================
echo ""
echo "============================================"
echo "🟢 تشغيل n8n..."
echo "============================================"
echo ""

# تشغيل n8n
exec n8n start
