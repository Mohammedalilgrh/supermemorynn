#!/bin/sh
set -eu
umask 077

BASE="${GITHUB_REPO_NAME:?}"
OWNER="${GITHUB_REPO_OWNER:?}"
TOKEN="${GITHUB_TOKEN:?}"

BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

MAX_SIZE_MB="${MAX_REPO_SIZE_MB:-4800}"
MARGIN_MB="${REPO_SIZE_MARGIN_MB:-300}"
CHUNK="${CHUNK_SIZE:-40M}"
GZIP_LVL="${GZIP_LEVEL:-1}"
MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-60}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-900}"
BKP_BIN="${BACKUP_BINARYDATA:-true}"
VOL_PRE="${VOLUME_PREFIX:-${BASE}-vol-}"
VOL_PAD="${VOLUME_PAD:-4}"

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
META="n8n-data/_meta"

mkdir -p "$WORK"

# ── القفل ──
if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# ── دوال أساسية ──
now_e() { date +%s; }
utc_t() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
bkp_id() { date +"%Y-%m-%d_%H-%M-%S"; }

gh_api() {
  curl -sS -H "Authorization: token $TOKEN" \
       -H "Accept: application/vnd.github+json" "$1"
}

gh_exists() {
  _c=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/${OWNER}/${1}")
  [ "$_c" = "200" ]
}

gh_create() {
  echo "📦 إنشاء ريبو: $1"
  curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"$1\",\"private\":true}" \
    "https://api.github.com/user/repos" >/dev/null
  sleep 3
}

gh_ensure() { gh_exists "$1" || gh_create "$1"; }

gh_size_mb() {
  _kb=$(gh_api "https://api.github.com/repos/${OWNER}/${1}" | jq '.size // 0')
  awk "BEGIN{printf \"%d\", ($_kb/1024)}"
}

g_setup() {
  git config user.email "backup@local"
  git config user.name "n8n-backup-bot"
}

g_prep_main() {
  _dir="$1"; _url="$2"
  rm -rf "$_dir"; mkdir -p "$_dir"
  cd "$_dir"
  git init -q; g_setup
  git remote add origin "$_url"
  if git fetch -q --depth 1 origin "$BRANCH" 2>/dev/null; then
    git checkout -q -B "$BRANCH" FETCH_HEAD
  else
    git checkout -q --orphan "$BRANCH"
    mkdir -p "$META"
    echo "init $(date -u)" > "$META/init.txt"
    git add -A; git commit -q -m "init"
    git push -q -u origin "$BRANCH" || true
  fi
  cd - >/dev/null
}

write_meta() {
  _dir="$1"; _vr="$2"; _vb="$3"; _id="$4"; _ts="$5"
  (
    cd "$_dir"; mkdir -p "$META"
    printf "%s" "$_vr" > "$META/latest_repo"
    printf "%s" "$_vb" > "$META/latest_branch"
    printf "%s" "$_id" > "$META/latest_id"
    printf "%s" "$_ts" > "$META/latest_timestamp"
    echo "$_ts $_vr $_vb $_id" >> "$META/history.log"
    # أبقي آخر 200 سطر فقط
    _lines=$(wc -l < "$META/history.log")
    if [ "$_lines" -gt 200 ]; then
      tail -200 "$META/history.log" > "$META/history.tmp"
      mv "$META/history.tmp" "$META/history.log"
    fi
  )
}

read_ptr() {
  _url="$1"; _tmp="$2"
  g_prep_main "$_tmp" "$_url"
  (
    cd "$_tmp"
    _r=""; [ -f "$META/latest_repo" ] && _r=$(cat "$META/latest_repo" 2>/dev/null || true)
    printf "%s" "$_r"
  )
}

# ── كشف التغييرات ──
db_sig() {
  _s=""
  for _f in database.sqlite database.sqlite-wal database.sqlite-shm; do
    [ -f "$N8N_DIR/$_f" ] && \
      _s="${_s}${_f}:$(stat -c '%Y:%s' "$N8N_DIR/$_f" 2>/dev/null || echo 0:0);"
  done
  printf "%s" "$_s"
}

bin_sig() {
  [ "$BKP_BIN" = "true" ] || { printf "skip"; return; }
  [ -d "$N8N_DIR/binaryData" ] || { printf "none"; return; }
  du -sk "$N8N_DIR/binaryData" 2>/dev/null | awk '{print $1}' || echo "0"
}

should_bkp() {
  [ -f "$N8N_DIR/database.sqlite" ] || { echo "NODB"; return; }

  _now=$(now_e)
  _le=0; _lf=0; _ld=""; _lb=""

  if [ -f "$STATE" ]; then
    _le=$(grep '^LE=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _lf=$(grep '^LF=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _ld=$(grep '^LD=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
    _lb=$(grep '^LB=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
  fi

  _cd=$(db_sig); _cb=$(bin_sig)

  [ $((_now - _lf)) -ge "$FORCE_INT" ] && { echo "FORCE"; return; }
  [ "$_cd" = "$_ld" ] && [ "$_cb" = "$_lb" ] && { echo "NOCHANGE"; return; }
  [ $((_now - _le)) -lt "$MIN_INT" ] && { echo "COOLDOWN"; return; }
  echo "CHANGED"
}

save_state() {
  _n=$(now_e)
  cat > "$STATE" <<EOF
ID=$1
TS=$2
LE=$_n
LF=$_n
VR=$3
VB=$4
LD=$(db_sig)
LB=$(bin_sig)
EOF
}

pad_i() { printf "%0${VOL_PAD}d" "$1"; }
def_vol() { printf "%s%s" "$VOL_PRE" "$(pad_i 1)"; }

find_vol() {
  _i=1
  while :; do
    _idx=$(pad_i "$_i")
    _c="${VOL_PRE}${_idx}"

    if ! gh_exists "$_c"; then
      gh_create "$_c"
      echo "$_c"; return
    fi

    _sm=$(gh_size_mb "$_c" || echo 0)
    _th=$((MAX_SIZE_MB - MARGIN_MB))
    [ "$_sm" -lt "$_th" ] && { echo "$_c"; return; }

    echo "  ⚠️ $_c ممتلئ (${_sm}MB)" >&2
    _i=$((_i + 1))
    [ "$_i" -le 9999 ] || { echo "ERROR"; return 1; }
  done
}

# ══════════════════════════════════
# البداية
# ══════════════════════════════════

DEC=$(should_bkp)
case "$DEC" in
  NODB|NOCHANGE|COOLDOWN) exit 0 ;;
esac

ID=$(bkp_id)
TS=$(utc_t)
BB="backup/$ID"

echo ""
echo "┌─────────────────────────────────────┐"
echo "│ 📦 باك أب: $ID"
echo "│ 📝 السبب: $DEC"
echo "└─────────────────────────────────────┘"

gh_ensure "$BASE"
BASE_URL="https://${TOKEN}@github.com/${OWNER}/${BASE}.git"

# قراءة pointer
_tp="$WORK/_tp"
_pr=$(read_ptr "$BASE_URL" "$_tp" 2>/dev/null || true)
rm -rf "$_tp" 2>/dev/null || true

# تحديد الـ volume
CV="$_pr"
[ -n "$CV" ] || CV=$(def_vol)
gh_ensure "$CV"

_sm=$(gh_size_mb "$CV" || echo 0)
_th=$((MAX_SIZE_MB - MARGIN_MB))
if [ "$_sm" -ge "$_th" ]; then
  echo "📦 $CV ممتلئ (${_sm}MB) → تدوير"
  CV=$(find_vol) || exit 1
  [ "$CV" != "ERROR" ] || exit 1
  echo "📦 الجديد: $CV"
fi

VU="https://${TOKEN}@github.com/${OWNER}/${CV}.git"
echo "📍 الهدف: $CV / $BB"

# ── إنشاء الباك أب ──
_tb="$WORK/_tb"
rm -rf "$_tb"; mkdir -p "$_tb"
(
  cd "$_tb"
  git init -q; g_setup
  git remote add origin "$VU"
  git checkout -q --orphan "$BB"
  rm -rf ./* ./.??* 2>/dev/null || true
  mkdir -p n8n-data

  # checkpoint
  sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" \
    "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

  # تصدير DB
  echo "  🗄️  تصدير الداتابيس..."
  sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" ".dump" \
    2>/dev/null \
    | gzip -n -"$GZIP_LVL" -c \
    | split -b "$CHUNK" -d -a 4 - "n8n-data/db.sql.gz.part_"

  if ! ls n8n-data/db.sql.gz.part_* >/dev/null 2>&1; then
    echo "  ❌ فشل تصدير الداتابيس"
    exit 1
  fi
  _dp=$(ls n8n-data/db.sql.gz.part_* | wc -l)
  echo "  ✅ DB: $_dp أجزاء"

  # أرشيف الملفات
  echo "  📁 أرشفة الملفات..."
  _exc="--exclude=database.sqlite --exclude=database.sqlite-wal --exclude=database.sqlite-shm"
  [ "$BKP_BIN" != "true" ] && _exc="$_exc --exclude=binaryData"

  tar -C "$N8N_DIR" -cf - $_exc . 2>/dev/null \
    | gzip -n -"$GZIP_LVL" -c \
    | split -b "$CHUNK" -d -a 4 - "n8n-data/files.tar.gz.part_"

  if ls n8n-data/files.tar.gz.part_* >/dev/null 2>&1; then
    _fp=$(ls n8n-data/files.tar.gz.part_* | wc -l)
    echo "  ✅ Files: $_fp أجزاء"
  fi

  # معلومات
  cat > n8n-data/backup_info.txt <<EOF
ID=$ID
TIMESTAMP_UTC=$TS
VOLUME_REPO=$CV
BRANCH=$BB
CHUNK_SIZE=$CHUNK
GZIP_LEVEL=$GZIP_LVL
BACKUP_BINARYDATA=$BKP_BIN
EOF

  # checksums
  ( cd n8n-data && find . -maxdepth 1 -type f -print0 \
    | sort -z | xargs -0 sha256sum ) > n8n-data/SHA256SUMS.txt 2>/dev/null || true

  echo "  📤 رفع..."
  git add -A
  git commit -q -m "backup $ID"

  # محاولة الرفع مع إعادة المحاولة
  _try=0
  while [ "$_try" -lt 3 ]; do
    if git push -q -u origin "$BB" 2>/dev/null; then
      echo "  ✅ تم الرفع"
      break
    fi
    _try=$((_try + 1))
    echo "  ⚠️ فشل الرفع، محاولة $_try/3..."
    sleep 5
  done

  if [ "$_try" -ge 3 ]; then
    echo "  ❌ فشل الرفع بعد 3 محاولات"
    exit 1
  fi
)
rm -rf "$_tb" 2>/dev/null || true

# ── تحديث meta في الـ volume ──
echo "  📝 تحديث meta في $CV..."
_tvm="$WORK/_tvm"
g_prep_main "$_tvm" "$VU"
write_meta "$_tvm" "$CV" "$BB" "$ID" "$TS"
(
  cd "$_tvm"
  git add -A
  git commit -q -m "meta → $BB" || true
  git push -q origin "$BRANCH" 2>/dev/null || true
)
rm -rf "$_tvm" 2>/dev/null || true

# ── تحديث pointer في الريبو الأساسي ──
echo "  📝 تحديث pointer في $BASE..."
_tbm="$WORK/_tbm"
g_prep_main "$_tbm" "$BASE_URL"
write_meta "$_tbm" "$CV" "$BB" "$ID" "$TS"
(
  cd "$_tbm"
  git add -A
  git commit -q -m "ptr → $CV/$BB" || true
  git push -q origin "$BRANCH" 2>/dev/null || true
)
rm -rf "$_tbm" 2>/dev/null || true

# ── حفظ الحالة ──
save_state "$ID" "$TS" "$CV" "$BB"

echo ""
echo "┌─────────────────────────────────────┐"
echo "│ ✅ باك أب اكتمل!                    │"
echo "│ 📍 $CV / $BB                         │"
echo "│ 🕒 $TS                               │"
echo "└─────────────────────────────────────┘"
echo ""
exit 0
