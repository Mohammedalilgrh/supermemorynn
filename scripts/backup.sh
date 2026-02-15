#!/bin/sh
set -eu
umask 077

# ========= Config =========
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

BASE_REPO="${GITHUB_REPO_NAME:?missing GITHUB_REPO_NAME}"
OWNER="${GITHUB_REPO_OWNER:?missing GITHUB_REPO_OWNER}"
TOKEN="${GITHUB_TOKEN:?missing GITHUB_TOKEN}"

# خله أقل من 5GB بهامش
MAX_REPO_SIZE_MB="${MAX_REPO_SIZE_MB:-4800}"
REPO_SIZE_MARGIN_MB="${REPO_SIZE_MARGIN_MB:-300}"

# لازم أقل من 100MB (حد GitHub للملف)
CHUNK_SIZE="${CHUNK_SIZE:-40M}"

# حتى ما يرهق Render
MIN_BACKUP_INTERVAL_SEC="${MIN_BACKUP_INTERVAL_SEC:-300}"     # 5 دقائق
FORCE_BACKUP_EVERY_SEC="${FORCE_BACKUP_EVERY_SEC:-86400}"     # يوم

# حفظ binaryData يخلي الحجم يكبر بسرعة
BACKUP_BINARYDATA="${BACKUP_BINARYDATA:-true}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

STATE_FILE="$WORK/.backup_state"
LOCK_DIR="$WORK/.backup_lock"

META_DIR="n8n-data/_meta"
META_LATEST_REPO="$META_DIR/latest_repo"
META_LATEST_BRANCH="$META_DIR/latest_branch"
META_LATEST_ID="$META_DIR/latest_id"
META_LATEST_TS="$META_DIR/latest_timestamp"
META_HISTORY="$META_DIR/history.log"

mkdir -p "$WORK"

# ========= Lock =========
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# ========= Deps =========
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need_cmd git
need_cmd curl
need_cmd jq
need_cmd sqlite3
need_cmd tar
need_cmd gzip
need_cmd split
need_cmd du
need_cmd stat
need_cmd sort
need_cmd awk
need_cmd xargs
need_cmd sha256sum

# ========= Helpers =========
now_epoch() { date +%s; }
utc_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
backup_id() { date +"%Y-%m-%d_%H-%M-%S"; }

api_json() {
  curl -sS -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "$1"
}

repo_exists() {
  code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/${OWNER}/${1}")
  [ "$code" = "200" ]
}

create_repo() {
  name="$1"
  curl -sS -X POST -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"$name\",\"private\":true}" \
    "https://api.github.com/user/repos" >/dev/null
}

ensure_repo() {
  r="$1"
  if ! repo_exists "$r"; then
    create_repo "$r"
  fi
}

get_repo_size_mb() {
  r="$1"
  size_kb=$(api_json "https://api.github.com/repos/${OWNER}/${r}" | jq '.size // 0')
  awk "BEGIN{printf \"%d\", ($size_kb/1024)}"
}

git_ident() {
  git config user.email >/dev/null 2>&1 || git config user.email "backup@local"
  git config user.name  >/dev/null 2>&1 || git config user.name  "n8n-backup-bot"
}

git_prepare_main() {
  dir="$1"; url="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q
    git_ident
    git remote add origin "$url"
    if git fetch -q --depth 1 origin "$GITHUB_BRANCH" 2>/dev/null; then
      git checkout -q -B "$GITHUB_BRANCH" FETCH_HEAD
    else
      git checkout -q --orphan "$GITHUB_BRANCH"
      mkdir -p "$META_DIR"
      echo "initialized $(date -u)" > "$META_DIR/initialized.txt"
      git add -A
      git commit -q -m "init meta"
      git push -q -u origin "$GITHUB_BRANCH" || true
    fi
  )
}

write_meta_and_history() {
  dir="$1"; latest_repo="$2"; latest_branch="$3"; id="$4"; ts="$5"
  (
    cd "$dir"
    mkdir -p "$META_DIR"
    printf "%s" "$latest_repo"   > "$META_LATEST_REPO"
    printf "%s" "$latest_branch" > "$META_LATEST_BRANCH"
    printf "%s" "$id"            > "$META_LATEST_ID"
    printf "%s" "$ts"            > "$META_LATEST_TS"

    # append-only history
    echo "$ts $latest_repo $latest_branch $id" >> "$META_HISTORY"
  )
}

read_pointer_from_base() {
  base_url="$1"; tmp="$2"
  git_prepare_main "$tmp" "$base_url"
  (
    cd "$tmp"
    r=""; b=""
    [ -f "$META_LATEST_REPO" ] && r=$(cat "$META_LATEST_REPO" 2>/dev/null || true)
    [ -f "$META_LATEST_BRANCH" ] && b=$(cat "$META_LATEST_BRANCH" 2>/dev/null || true)
    printf "%s %s\n" "$r" "$b"
  )
}

# توقيع سريع للتغيير (يشمل WAL/SHM)
db_sig() {
  db="$N8N_DIR/database.sqlite"
  wal="$N8N_DIR/database.sqlite-wal"
  shm="$N8N_DIR/database.sqlite-shm"
  sig=""
  [ -f "$db" ]  && sig="${sig}db:$(stat -c '%Y:%s' "$db" 2>/dev/null || echo 0:0);"
  [ -f "$wal" ] && sig="${sig}wal:$(stat -c '%Y:%s' "$wal" 2>/dev/null || echo 0:0);"
  [ -f "$shm" ] && sig="${sig}shm:$(stat -c '%Y:%s' "$shm" 2>/dev/null || echo 0:0);"
  printf "%s" "$sig"
}

bin_sig() {
  [ "$BACKUP_BINARYDATA" = "true" ] || { printf "skip"; return; }
  bd="$N8N_DIR/binaryData"
  [ -d "$bd" ] || { printf "none"; return; }
  du -sk "$bd" 2>/dev/null | awk '{print "bdkb:"$1}' || echo "bdkb:0"
}

should_backup() {
  [ -f "$N8N_DIR/database.sqlite" ] || exit 0

  now="$(now_epoch)"
  last_epoch=0
  last_force=0
  last_db=""
  last_bin=""

  if [ -f "$STATE_FILE" ]; then
    last_epoch=$(grep '^LAST_BACKUP_EPOCH=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
    last_force=$(grep '^LAST_FORCE_EPOCH=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
    last_db=$(grep '^LAST_DB_SIG=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || echo "")
    last_bin=$(grep '^LAST_BIN_SIG=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || echo "")
  fi

  cur_db="$(db_sig)"
  cur_bin="$(bin_sig)"

  if [ $((now - last_force)) -ge "$FORCE_BACKUP_EVERY_SEC" ]; then
    echo "FORCE"; return
  fi

  if [ "$cur_db" = "$last_db" ] && [ "$cur_bin" = "$last_bin" ]; then
    echo "NOCHANGE"; return
  fi

  if [ $((now - last_epoch)) -lt "$MIN_BACKUP_INTERVAL_SEC" ]; then
    echo "COOLDOWN"; return
  fi

  echo "YES"
}

update_state() {
  id="$1"; ts="$2"; repo="$3"; branch="$4"
  now="$(now_epoch)"
  cat > "$STATE_FILE" <<EOF
LAST_BACKUP_ID=$id
LAST_BACKUP_TS=$ts
LAST_BACKUP_EPOCH=$now
LAST_FORCE_EPOCH=$now
LAST_REPO=$repo
LAST_BRANCH=$branch
LAST_DB_SIG=$(db_sig)
LAST_BIN_SIG=$(bin_sig)
EOF
}

# ========= Decide =========
DECISION="$(should_backup)"
[ "$DECISION" = "NOCHANGE" ] && exit 0
[ "$DECISION" = "COOLDOWN" ] && exit 0

ID="$(backup_id)"
TS="$(utc_ts)"
BACKUP_BRANCH="backup/$ID"

# ========= Base repo =========
ensure_repo "$BASE_REPO"
BASE_URL="https://${TOKEN}@github.com/${OWNER}/${BASE_REPO}.git"

# ========= Current volume repo from pointer =========
tmp_ptr="$WORK/_tmp_ptr"
ptr="$(read_pointer_from_base "$BASE_URL" "$tmp_ptr" 2>/dev/null || true)"
rm -rf "$tmp_ptr" 2>/dev/null || true

CURRENT_REPO="$(printf "%s" "$ptr" | awk '{print $1}')"
[ -n "$CURRENT_REPO" ] || CURRENT_REPO="$BASE_REPO"
ensure_repo "$CURRENT_REPO"

# ========= Rotation =========
size_mb="$(get_repo_size_mb "$CURRENT_REPO" || echo 0)"
threshold=$((MAX_REPO_SIZE_MB - REPO_SIZE_MARGIN_MB))
if [ "$size_mb" -ge "$threshold" ]; then
  CURRENT_REPO="${BASE_REPO}-vol-$(date +%s)"
  ensure_repo "$CURRENT_REPO"
fi
VOLUME_URL="https://${TOKEN}@github.com/${OWNER}/${CURRENT_REPO}.git"

# ========= Create orphan backup branch (append-only) =========
tmp_b="$WORK/_tmp_backup_branch"
rm -rf "$tmp_b"
mkdir -p "$tmp_b"

(
  cd "$tmp_b"
  git init -q
  git_ident
  git remote add origin "$VOLUME_URL"

  git checkout -q --orphan "$BACKUP_BRANCH"
  rm -rf ./* ./.??* 2>/dev/null || true
  mkdir -p n8n-data

  # best-effort checkpoint حتى لا تضيع WAL
  sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

  # 1) DB dump (بدون gzip حتى Git يضغطه بدِلتا أحسن مع الزمن) -> split
  : > n8n-data/db_dump.stderr
  sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" ".dump" 2>n8n-data/db_dump.stderr \
    | split -b "$CHUNK_SIZE" - "n8n-data/db.sql.part_"

  ls n8n-data/db.sql.part_* >/dev/null 2>&1 || { echo "DB dump failed"; exit 1; }

  # 2) ملفات ~/.n8n (عدا sqlite) -> tar.gz -> split
  : > n8n-data/files_archive.stderr
  TAR_EXCLUDES="--exclude=database.sqlite --exclude=database.sqlite-wal --exclude=database.sqlite-shm"
  if [ "$BACKUP_BINARYDATA" != "true" ]; then
    TAR_EXCLUDES="$TAR_EXCLUDES --exclude=binaryData"
  fi

  # shellcheck disable=SC2086
  tar -C "$N8N_DIR" -cf - $TAR_EXCLUDES . 2>n8n-data/files_archive.stderr \
    | gzip -c \
    | split -b "$CHUNK_SIZE" - "n8n-data/files.tar.gz.part_"

  ls n8n-data/files.tar.gz.part_* >/dev/null 2>&1 || { echo "Files archive failed"; exit 1; }

  # info
  cat > n8n-data/backup_info.txt <<EOF
ID=$ID
TIMESTAMP_UTC=$TS
REPO=$CURRENT_REPO
BRANCH=$BACKUP_BRANCH
CHUNK_SIZE=$CHUNK_SIZE
BACKUP_BINARYDATA=$BACKUP_BINARYDATA
EOF

  # hashes (اختياري)
  (
    cd n8n-data
    find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum
  ) > n8n-data/SHA256SUMS.txt 2>/dev/null || true

  git add -A
  git commit -q -m "n8n backup $ID"
  git push -q -u origin "$BACKUP_BRANCH"
)

rm -rf "$tmp_b" 2>/dev/null || true

# ========= Update meta pointers (volume main + base main) =========
tmp_vm="$WORK/_tmp_volume_main"
git_prepare_main "$tmp_vm" "$VOLUME_URL"
write_meta_and_history "$tmp_vm" "$CURRENT_REPO" "$BACKUP_BRANCH" "$ID" "$TS"
(
  cd "$tmp_vm"
  git add -A
  git commit -q -m "meta: latest -> $BACKUP_BRANCH" || true
  git push -q origin "$GITHUB_BRANCH" || true
)
rm -rf "$tmp_vm" 2>/dev/null || true

tmp_bm="$WORK/_tmp_base_main"
git_prepare_main "$tmp_bm" "$BASE_URL"
write_meta_and_history "$tmp_bm" "$CURRENT_REPO" "$BACKUP_BRANCH" "$ID" "$TS"
(
  cd "$tmp_bm"
  git add -A
  git commit -q -m "meta: latest -> $CURRENT_REPO/$BACKUP_BRANCH" || true
  git push -q origin "$GITHUB_BRANCH" || true
)
rm -rf "$tmp_bm" 2>/dev/null || true

update_state "$ID" "$TS" "$CURRENT_REPO" "$BACKUP_BRANCH"
exit 0
