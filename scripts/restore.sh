#!/bin/sh

# ============================================
# سكربت الاستعادة اليدوية
# ============================================

echo "📥 بدء الاستعادة اليدوية..."

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="/home/node/.n8n"
BACKUP_DIR="/backup-data"
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

cd "$BACKUP_DIR"
rm -rf repo

echo "📥 تحميل البيانات من GitHub..."
git clone --branch "$GITHUB_BRANCH" --single-branch "$REPO_URL" repo

if [ ! -d "repo/n8n-data" ]; then
    echo "❌ لا توجد بيانات محفوظة!"
    exit 1
fi

DATA_DIR="repo/n8n-data"

# استعادة الداتابيس
if [ -f "$DATA_DIR/database.sqlite" ]; then
    cp "$DATA_DIR/database.sqlite" "$N8N_DIR/"
    echo "✅ قاعدة البيانات"
elif [ -f "$DATA_DIR/database.sqlite.gz" ]; then
    echo "📦 فك ضغط قاعدة البيانات..."
    gunzip -c "$DATA_DIR/database.sqlite.gz" > "$N8N_DIR/database.sqlite"
    echo "✅ قاعدة البيانات (مضغوطة)"
elif [ -d "$DATA_DIR/db-chunks" ]; then
    echo "🔗 تجميع أجزاء قاعدة البيانات..."
    cat "$DATA_DIR/db-chunks/chunk_"* > "$N8N_DIR/database.sqlite.gz"
    gunzip "$N8N_DIR/database.sqlite.gz"
    echo "✅ قاعدة البيانات (مقسمة)"
fi

# استعادة المفاتيح
for keyfile in ".n8n-encryption-key" "encryptionKey"; do
    if [ -f "$DATA_DIR/$keyfile" ]; then
        cp "$DATA_DIR/$keyfile" "$N8N_DIR/"
        echo "✅ $keyfile"
    fi
done

# استعادة الإعدادات
if [ -f "$DATA_DIR/config" ]; then
    cp "$DATA_DIR/config" "$N8N_DIR/"
    echo "✅ الإعدادات"
fi

# استعادة الملفات المخصصة
for dir in "custom" "custom-nodes" "credentials" "workflows"; do
    if [ -d "$DATA_DIR/$dir" ]; then
        cp -r "$DATA_DIR/$dir" "$N8N_DIR/"
        echo "✅ $dir"
    fi
done

echo ""
echo "✅ تمت الاستعادة بالكامل!"

# عرض الإحصائيات
if [ -f "$DATA_DIR/stats.json" ]; then
    echo ""
    echo "📊 معلومات النسخة:"
    cat "$DATA_DIR/stats.json" | jq . 2>/dev/null || cat "$DATA_DIR/stats.json"
fi
