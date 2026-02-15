#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"
WORK="/backup-data"
STATE_FILE="$WORK/.backup_state"

# ═══════════════════════════════════════════════════════════
# 🔒 إضافات نظام الذاكرة الكاملة
# ═══════════════════════════════════════════════════════════
VERSIONS_DIR="$WORK/versions"
HISTORY_DIR="$WORK/history"
SAFE_BACKUP="$WORK/safe_backup"
HISTORY_LOG="$HISTORY_DIR/all_changes.log"
RESTORE_LOG="$HISTORY_DIR/restore.log"
mkdir -p "$VERSIONS_DIR" "$HISTORY_DIR" "$SAFE_BACKUP" "$N8N_DIR"

# 🔍 دالة فحص صحة الداتابيس
check_db_integrity() {
    if [ -f "$1" ] && [ -s "$1" ]; then
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

# 🛡️ دالة الاستعادة من النسخ المحلية
restore_from_local() {
    echo "🔍 البحث عن نسخة محلية صالحة..."
    
    # البحث في النسخ المحفوظة
    for backup_file in $(ls -t "$VERSIONS_DIR"/*.sqlite 2>/dev/null); do
        if [ "$(check_db_integrity "$backup_file")" = "valid" ]; then
            cp "$backup_file" "$N8N_DIR/database.sqlite"
            echo "✅ استعادة من نسخة محلية: $(basename "$backup_file")"
            echo "$(date)|LOCAL_RESTORE|$(basename "$backup_file")" >> "$RESTORE_LOG"
            return 0
        fi
    done
    
    # البحث في النسخ الآمنة
    for safe_file in $(ls -t "$SAFE_BACKUP"/db_*.sqlite 2>/dev/null); do
        if [ "$(check_db_integrity "$safe_file")" = "valid" ]; then
            cp "$safe_file" "$N8N_DIR/database.sqlite"
            echo "✅ استعادة من نسخة آمنة: $(basename "$safe_file")"
            echo "$(date)|SAFE_RESTORE|$(basename "$safe_file")" >> "$RESTORE_LOG"
            return 0
        fi
    done
    
    return 1
}

# 🛡️ دالة التحقق قبل حذف الريبو
safe_cleanup() {
    if [ -f "$N8N_DIR/database.sqlite" ]; then
        if [ "$(check_db_integrity "$N8N_DIR/database.sqlite")" = "valid" ]; then
            rm -rf "$WORK/repo"
            echo "🧹 تم تنظيف الملفات المؤقتة"
        else
            echo "⚠️ الداتابيس غير صالح! الاحتفاظ بالريبو"
            # محاولة الاستعادة
            restore_from_local || restore_from_emergency
        fi
    else
        echo "⚠️ لا يوجد داتابيس! الاحتفاظ بالريبو"
    fi
}

# 🚨 دالة الاستعادة من نسخ الطوارئ
restore_from_emergency() {
    echo "🚨 محاولة الاستعادة من نسخ الطوارئ..."
    
    if [ -d "$WORK/repo/n8n-data/emergency" ]; then
        for emergency_file in $(ls -t "$WORK/repo/n8n-data/emergency"/backup_*.sqlite 2>/dev/null); do
            if [ "$(check_db_integrity "$emergency_file")" = "valid" ]; then
                cp "$emergency_file" "$N8N_DIR/database.sqlite"
                echo "✅ استعادة من نسخة طوارئ: $(basename "$emergency_file")"
                echo "$(date)|EMERGENCY_RESTORE|$(basename "$emergency_file")" >> "$RESTORE_LOG"
                return 0
            fi
        done
    fi
    
    return 1
}
# ═══════════════════════════════════════════════════════════

# البحث عن آخر ريبو تم استخدامه (نظام الـ Multi-Repo)
# إذا كان لديك ريبوهات متعددة، نوصي بوضع اسم الريبو الأساسي هنا
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

mkdir -p "$N8N_DIR"
cd "$WORK"

echo "🛰️ بدء سحب البيانات بتقنية الـ Streaming..."

# ═══════════════════════════════════════════════════════════
# 🔄 محاولة الاستنساخ مع إعادة المحاولة
# ═══════════════════════════════════════════════════════════
CLONE_SUCCESS=false
for attempt in 1 2 3; do
    if git clone --depth 1 "$REPO_URL" repo 2>/dev/null; then
        CLONE_SUCCESS=true
        break
    fi
    echo "⏳ محاولة الاتصال $attempt/3..."
    sleep 2
done

if [ "$CLONE_SUCCESS" = false ]; then
    echo "⚠️ فشل الاتصال بـ GitHub!"
    if restore_from_local; then
        echo "✅ تم التشغيل من نسخة محلية"
    else
        echo "🆕 أول تشغيل - سيتم إنشاء داتابيس جديد"
    fi
fi
# ═══════════════════════════════════════════════════════════

if [ -d "repo/n8n-data" ]; then
    # 🧠 قراءة معلومات النسخة الاحتياطية
    if [ -f "repo/n8n-data/backup_info.txt" ]; then
        echo "📋 قراءة معلومات النسخة الاحتياطية..."
        cat "repo/n8n-data/backup_info.txt"
        USE_CHUNKS=$(grep "USE_CHUNKS=" "repo/n8n-data/backup_info.txt" 2>/dev/null | cut -d'=' -f2)
    fi
    
    # ═══════════════════════════════════════════════════════════
    # 🛡️ حفظ نسخ الطوارئ من GitHub محلياً
    # ═══════════════════════════════════════════════════════════
    if [ -d "repo/n8n-data/emergency" ]; then
        for emergency_file in repo/n8n-data/emergency/backup_*.sqlite; do
            if [ -f "$emergency_file" ]; then
                FNAME=$(basename "$emergency_file")
                cp "$emergency_file" "$VERSIONS_DIR/github_$FNAME" 2>/dev/null || true
                echo "📦 حفظ نسخة طوارئ: $FNAME"
            fi
        done
    fi
    
    # استعادة سجل التاريخ
    if [ -f "repo/n8n-data/history.log" ]; then
        cat "repo/n8n-data/history.log" >> "$HISTORY_LOG"
        echo "📜 استعادة سجل التاريخ"
    fi
    # ═══════════════════════════════════════════════════════════
    
    # 🎯 الاستعادة الذكية حسب نوع النسخة
    RESTORE_SUCCESS=false
    
    if [ "$USE_CHUNKS" = "true" ] || [ -d "repo/n8n-data/chunks" ] && [ ! -f "repo/n8n-data/database.sqlite" ]; then
        echo "🧩 تجميع أجزاء الداتابيس (توفير الرام)..."
        # 🔥 تقنية الـ Streaming: تجميع القطع مباشرة إلى الملف دون تحميلها للذاكرة
        if ls repo/n8n-data/chunks/n8n_part_* 1>/dev/null 2>&1; then
            cat repo/n8n-data/chunks/n8n_part_* > "$N8N_DIR/database.sqlite"
            RESTORE_SUCCESS=true
        fi
    elif [ -f "repo/n8n-data/database.sqlite" ]; then
        echo "📦 استعادة النسخة الكاملة..."
        cp "repo/n8n-data/database.sqlite" "$N8N_DIR/database.sqlite"
        RESTORE_SUCCESS=true
    elif [ -f "repo/n8n-data/full_backup.sql" ]; then
        echo "🗄️ استعادة من SQL dump..."
        rm -f "$N8N_DIR/database.sqlite"
        sqlite3 "$N8N_DIR/database.sqlite" < "repo/n8n-data/full_backup.sql"
        RESTORE_SUCCESS=true
    fi
    
    # ═══════════════════════════════════════════════════════════
    # 🔍 التحقق من صحة الاستعادة
    # ═══════════════════════════════════════════════════════════
    if [ "$RESTORE_SUCCESS" = true ]; then
        DB_CHECK=$(check_db_integrity "$N8N_DIR/database.sqlite")
        if [ "$DB_CHECK" != "valid" ]; then
            echo "⚠️ الداتابيس المستعاد غير صالح! محاولة الاستعادة البديلة..."
            
            # محاولة من نسخ الطوارئ
            if ! restore_from_emergency; then
                # محاولة من النسخ المحلية
                if ! restore_from_local; then
                    echo "❌ فشلت جميع محاولات الاستعادة!"
                fi
            fi
        else
            # حفظ نسخة محلية من الاستعادة الناجحة
            RESTORE_HASH=$(sha256sum "$N8N_DIR/database.sqlite" | cut -d' ' -f1)
            cp "$N8N_DIR/database.sqlite" "$VERSIONS_DIR/${RESTORE_HASH}.sqlite"
            echo "$(date)|GITHUB_RESTORE|$RESTORE_HASH" >> "$RESTORE_LOG"
        fi
    fi
    # ═══════════════════════════════════════════════════════════
    
    # استعادة المفاتيح
    cp repo/n8n-data/.n8n-encryption-key "$N8N_DIR/" 2>/dev/null || true
    cp repo/n8n-data/encryptionKey "$N8N_DIR/" 2>/dev/null || true
    cp repo/n8n-data/config "$N8N_DIR/" 2>/dev/null || true
    
    # 💾 حفظ معلومات الحالة المحلية
    if [ -f "repo/n8n-data/backup_info.txt" ]; then
        cp "repo/n8n-data/backup_info.txt" "$STATE_FILE"
        cp "repo/n8n-data/backup_info.txt" "$STATE_FILE.backup"
    fi
    
    echo "✨ تمت الاستعادة الكاملة!"
fi

# ═══════════════════════════════════════════════════════════
# 🛡️ حفظ نسخة قبل الـ migrations
# ═══════════════════════════════════════════════════════════
if [ -f "$N8N_DIR/database.sqlite" ]; then
    PRE_START_HASH=$(sha256sum "$N8N_DIR/database.sqlite" | cut -d' ' -f1)
    cp "$N8N_DIR/database.sqlite" "$VERSIONS_DIR/pre_start_${PRE_START_HASH}.sqlite"
    cp "$N8N_DIR/database.sqlite" "$SAFE_BACKUP/before_migrations_$(date +%Y%m%d_%H%M%S).sqlite"
    echo "🛡️ حفظ نسخة قبل التشغيل"
fi
# ═══════════════════════════════════════════════════════════

# 🔥 توفير الذاكرة: حذف مجلد الـ repo بأمان
safe_cleanup

# 🧠 نظام المراقبة الذكي مع الذاكرة
MONITOR_INTERVAL=15
LAST_CHECK=""
SKIP_FIRST=true
ERROR_COUNT=0

# تهيئة LAST_CHECK من الحالة المحفوظة
if [ -f "$STATE_FILE" ]; then
    LAST_CHECK=$(grep "LAST_HASH=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
elif [ -f "$STATE_FILE.backup" ]; then
    LAST_CHECK=$(grep "LAST_HASH=" "$STATE_FILE.backup" 2>/dev/null | cut -d'=' -f2)
fi

# نظام المراقبة اللحظي (كل 15 ثانية) مع فحص التغييرات
(
    while true; do
        sleep $MONITOR_INTERVAL
        
        # ═══════════════════════════════════════════════════════════
        # ⏭️ تخطي أول فحص بعد الـ migrations
        # ═══════════════════════════════════════════════════════════
        if [ "$SKIP_FIRST" = true ]; then
            SKIP_FIRST=false
            echo "⏭️ تخطي أول فحص (انتظار الـ migrations)"
            continue
        fi
        # ═══════════════════════════════════════════════════════════
        
        if [ -f "$N8N_DIR/database.sqlite" ]; then
        
            # ═══════════════════════════════════════════════════════════
            # 🛡️ فحص حجم الداتابيس
            # ═══════════════════════════════════════════════════════════
            CURRENT_SIZE=$(stat -c%s "$N8N_DIR/database.sqlite" 2>/dev/null || echo 0)
            
            if [ "$CURRENT_SIZE" -lt 1024 ]; then
                echo "⚠️ حجم الداتابيس صغير جداً! محاولة الاستعادة..."
                if restore_from_local; then
                    echo "✅ تم الاستعادة التلقائية"
                fi
                continue
            fi
            # ═══════════════════════════════════════════════════════════
            
            # 🔍 فحص هل الملف تغير قبل عمل backup
            CURRENT_HASH=$(sha256sum "$N8N_DIR/database.sqlite" 2>/dev/null | cut -d' ' -f1)
            if [ "$CURRENT_HASH" != "$LAST_CHECK" ]; then
            
                # ═══════════════════════════════════════════════════════════
                # 💾 حفظ نسخة محلية قبل الرفع
                # ═══════════════════════════════════════════════════════════
                if [ ! -f "$VERSIONS_DIR/${CURRENT_HASH}.sqlite" ]; then
                    cp "$N8N_DIR/database.sqlite" "$VERSIONS_DIR/${CURRENT_HASH}.sqlite"
                fi
                # ═══════════════════════════════════════════════════════════
                
                echo "🔄 تم اكتشاف تغييرات - بدء النسخ الاحتياطي..."
                
                # ═══════════════════════════════════════════════════════════
                # 🔄 النسخ الاحتياطي مع إدارة الأخطاء
                # ═══════════════════════════════════════════════════════════
                if /scripts/backup.sh > /dev/null 2>&1; then
                    LAST_CHECK="$CURRENT_HASH"
                    ERROR_COUNT=0
                    echo "✅ تم النسخ الاحتياطي بنجاح"
                else
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    echo "⚠️ فشل النسخ الاحتياطي ($ERROR_COUNT/5)"
                    
                    if [ $ERROR_COUNT -ge 5 ]; then
                        echo "🔴 أخطاء متكررة - انتظار 5 دقائق"
                        sleep 300
                        ERROR_COUNT=0
                    fi
                fi
                # ═══════════════════════════════════════════════════════════
            fi
        fi
    done
) &

# ═══════════════════════════════════════════════════════════
# 📝 حفظ PID المراقب
# ═══════════════════════════════════════════════════════════
MONITOR_PID=$!
echo "$MONITOR_PID" > "$WORK/.monitor.pid"
# ═══════════════════════════════════════════════════════════

echo "🚀 انطلاق n8n..."
exec n8n start
