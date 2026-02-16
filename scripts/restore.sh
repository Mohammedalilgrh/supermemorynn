#!/bin/sh
set -eu
umask 077

: "${GITHUB_TOKEN:?}"
: "${GITHUB_REPO_OWNER:?}"
: "${GITHUB_REPO_NAME:?}"

BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

OWNER="$GITHUB_REPO_OWNER"
BASE="$GITHUB_REPO_NAME"
TOKEN="$GITHUB_TOKEN"
VOL_PREFIX="${VOLUME_PREFIX:-${BASE}-vol-}"

TMP="/tmp/restore-$$"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

mkdir -p "$N8N_DIR" "$WORK" "$TMP"

# إذا الداتابيس موجودة لا نسترجع
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "✅ قاعدة البيانات موجودة"
  exit 0
fi

# ── دوال مساعدة ──

gh_exists() {
  _c=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/${OWNER}/${1}")
  [ "$_c" = "200" ]
}

gh_branches() {
  curl -sS -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${OWNER}/${1}/branches?per_page=100" \
    2>/dev/null | jq -r '.[].name // empty' 2>/dev/null || true
}

read_meta() {
  _repo="$1"
  _url="https://${TOKEN}@github.com/${OWNER}/${_repo}.git"
  _d="$TMP/meta_${_repo}"
  rm -rf "$_d"

  git clone --depth 1 --branch "$BRANCH" "$_url" "$_d" 2>/dev/null || return 1

  _mr=""; _mb=""
  [ -f "$_d/n8n-data/_meta/latest_repo" ] && \
    _mr=$(cat "$_d/n8n-data/_meta/latest_repo" 2>/dev/null)
  [ -f "$_d/n8n-data/_meta/latest_branch" ] && \
    _mb=$(cat "$_d/n8n-data/_meta/latest_branch" 2>/dev/null)
  rm -rf "$_d"

  [ -n "$_mr" ] && [ -n "$_mb" ] && echo "${_mr}|${_mb}" && return 0
  return 1
}

do_restore() {
  _repo="$1"; _branch="$2"
  _url="https://${TOKEN}@github.com/${OWNER}/${_repo}.git"
  _d="$TMP/data"
  rm -rf "$_d"

  echo "  📥 تحميل: ${_repo} / ${_branch}"
  git clone --depth 1 --branch "$_branch" "$_url" "$_d" 2>/dev/null || return 1

  # استرجاع الداتابيس
  if ls "$_d"/n8n-data/db.sql.gz.part_* >/dev/null 2>&1; then
    echo "  🗄️  استرجاع قاعدة البيانات..."
    cat "$_d"/n8n-data/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"

    if [ ! -s "$N8N_DIR/database.sqlite" ]; then
      echo "  ❌ الداتابيس فارغة"
      rm -f "$N8N_DIR/database.sqlite"
      rm -rf "$_d"
      return 1
    fi

    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    if [ "$_tc" -lt 1 ]; then
      echo "  ❌ لا توجد جداول"
      rm -f "$N8N_DIR/database.sqlite"
      rm -rf "$_d"
      return 1
    fi
    echo "  ✅ تم استرجاع $_tc جدول"
  else
    echo "  ❌ لا توجد ملفات داتابيس"
    rm -rf "$_d"
    return 1
  fi

  # استرجاع الملفات
  if ls "$_d"/n8n-data/files.tar.gz.part_* >/dev/null 2>&1; then
    echo "  📁 استرجاع الملفات..."
    cat "$_d"/n8n-data/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
    echo "  ✅ تم"
  fi

  # معلومات الباك أب
  [ -f "$_d/n8n-data/backup_info.txt" ] && {
    echo "  📋 معلومات:"
    sed 's/^/     /' "$_d/n8n-data/backup_info.txt"
  }

  rm -rf "$_d"
  return 0
}

echo "=== 🔍 بدء البحث عن آخر نسخة احتياطية ==="
echo ""

# ════════════════════════════════════
# الطريقة 1: Pointer من الريبو الأساسي
# ════════════════════════════════════
echo "🔍 [1/4] فحص الريبو الأساسي: $BASE"
if gh_exists "$BASE"; then
  ptr=$(read_meta "$BASE" 2>/dev/null || true)
  if [ -n "$ptr" ]; then
    vr=$(echo "$ptr" | cut -d'|' -f1)
    vb=$(echo "$ptr" | cut -d'|' -f2)
    echo "  📍 Pointer → $vr / $vb"

    if gh_exists "$vr"; then
      if do_restore "$vr" "$vb"; then
        echo ""
        echo "🎉 استرجاع ناجح من pointer!"
        exit 0
      fi
    fi
  else
    echo "  📭 لا يوجد pointer"
  fi
else
  echo "  📭 الريبو غير موجود بعد"
fi
echo ""

# ════════════════════════════════════
# الطريقة 2: فحص Volume repos
# ════════════════════════════════════
echo "🔍 [2/4] فحص Volume repos..."
i=1
while [ "$i" -le 50 ]; do
  idx=$(printf "%04d" "$i")
  vn="${VOL_PREFIX}${idx}"

  if gh_exists "$vn"; then
    echo "  📦 $vn موجود"

    # أولاً: نقرأ الـ meta
    vptr=$(read_meta "$vn" 2>/dev/null || true)
    if [ -n "$vptr" ]; then
      vvr=$(echo "$vptr" | cut -d'|' -f1)
      vvb=$(echo "$vptr" | cut -d'|' -f2)
      echo "    📍 Meta → $vvr / $vvb"
      if do_restore "$vvr" "$vvb"; then
        echo ""
        echo "🎉 استرجاع ناجح من volume meta!"
        exit 0
      fi
    fi

    # ثانياً: نبحث عن فروع backup/*
    vbranches=$(gh_branches "$vn" | grep '^backup/' | sort -r | head -3)
    if [ -n "$vbranches" ]; then
      for vbb in $vbranches; do
        echo "    🔄 محاولة: $vn / $vbb"
        if do_restore "$vn" "$vbb"; then
          echo ""
          echo "🎉 استرجاع ناجح من volume branch!"
          exit 0
        fi
      done
    fi
  else
    break
  fi
  i=$((i + 1))
done
echo ""

# ════════════════════════════════════
# الطريقة 3: فروع backup/* بالريبو الأساسي
# ════════════════════════════════════
echo "🔍 [3/4] فحص فروع backup/* في $BASE..."
if gh_exists "$BASE"; then
  bbranches=$(gh_branches "$BASE" | grep '^backup/' | sort -r | head -5)
  if [ -n "$bbranches" ]; then
    for bb in $bbranches; do
      echo "  🔄 محاولة: $BASE / $bb"
      if do_restore "$BASE" "$bb"; then
        echo ""
        echo "🎉 استرجاع ناجح من base branch!"
        exit 0
      fi
    done
  else
    echo "  📭 لا توجد فروع backup/*"
  fi
fi
echo ""

# ════════════════════════════════════
# الطريقة 4: main branch مباشرة
# ════════════════════════════════════
echo "🔍 [4/4] محاولة أخيرة من $BASE / $BRANCH..."
if gh_exists "$BASE"; then
  if do_restore "$BASE" "$BRANCH" 2>/dev/null; then
    echo ""
    echo "🎉 استرجاع ناجح!"
    exit 0
  fi
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  📭 لا توجد أي نسخة احتياطية سابقة      ║"
echo "║  🆕 سيبدأ n8n كتشغيل أول                ║"
echo "╚══════════════════════════════════════════╝"
echo ""
exit 1
