#!/bin/sh

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="/home/node/.n8n"
WORK="/backup-data"
REPO_DIR="$WORK/repo"
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
DATA_DIR="$REPO_DIR/n8n-data"

echo "Backup: $TIMESTAMP"

if [ ! -d "$REPO_DIR/.git" ]; then
    cd "$WORK"
    rm -rf repo
    if ! git clone --branch "$GITHUB_BRANCH" --depth 1 "$REPO_URL" repo 2>/dev/null; then
        mkdir -p repo
        cd repo
        git init
        git checkout -b "$GITHUB_BRANCH"
        git remote add origin "$REPO_URL"
        cd "$WORK"
    fi
fi

cd "$REPO_DIR"
git pull origin "$GITHUB_BRANCH" 2>/dev/null || true

# Clean old data and copy everything fresh
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

# Copy EVERYTHING from .n8n directory
cp -r "$N8N_DIR"/* "$DATA_DIR/" 2>/dev/null || true
cp "$N8N_DIR"/.* "$DATA_DIR/" 2>/dev/null || true

echo "   OK: all n8n data copied"

# Check what we got
if [ -f "$DATA_DIR/database.sqlite" ]; then
    DB_SIZE=$(du -sh "$DATA_DIR/database.sqlite" 2>/dev/null | cut -f1)
    echo "   OK: database ($DB_SIZE)"

    # Compress if too big
    DB_BYTES=$(wc -c < "$DATA_DIR/database.sqlite" 2>/dev/null || echo "0")
    if [ "$DB_BYTES" -gt 83886080 ]; then
        gzip -c "$DATA_DIR/database.sqlite" > "$DATA_DIR/database.sqlite.gz"
        rm -f "$DATA_DIR/database.sqlite"
        echo "   OK: compressed"
    fi
fi

# Save encryption key from ENV
if [ ! -z "$N8N_ENCRYPTION_KEY" ]; then
    echo "$N8N_ENCRYPTION_KEY" > "$DATA_DIR/env_encryption_key.txt"
    echo "   OK: encryption key saved"
fi

# Export workflows via API
N8N_PORT="${N8N_PORT:-5678}"
if curl -s "http://localhost:$N8N_PORT/healthz" > /dev/null 2>&1; then
    mkdir -p "$DATA_DIR/exported-workflows"

    WORKFLOWS=$(curl -s "http://localhost:$N8N_PORT/api/v1/workflows" 2>/dev/null)
    if [ ! -z "$WORKFLOWS" ] && [ "$WORKFLOWS" != "null" ] && [ "$WORKFLOWS" != "" ]; then
        echo "$WORKFLOWS" > "$DATA_DIR/exported-workflows/all.json"
        WF_COUNT=$(echo "$WORKFLOWS" | jq '.data | length' 2>/dev/null || echo "?")
        echo "   OK: $WF_COUNT workflows exported"
    fi

    CREDS=$(curl -s "http://localhost:$N8N_PORT/api/v1/credentials" 2>/dev/null)
    if [ ! -z "$CREDS" ] && [ "$CREDS" != "null" ] && [ "$CREDS" != "" ]; then
        echo "$CREDS" > "$DATA_DIR/exported-workflows/credentials.json"
        echo "   OK: credentials exported"
    fi
else
    echo "   WARN: n8n not ready yet, raw copy only"
fi

# Stats
TOTAL_SIZE=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
FILE_COUNT=$(find "$DATA_DIR" -type f | wc -l)

cat > "$DATA_DIR/stats.json" << EOF
{
    "last_backup": "$TIMESTAMP",
    "size": "$TOTAL_SIZE",
    "files": $FILE_COUNT
}
EOF

# Clean git history if too big
REPO_SIZE_MB=$(du -sm "$REPO_DIR/.git" 2>/dev/null | cut -f1)
if [ "${REPO_SIZE_MB:-0}" -gt 3000 ]; then
    echo "   Cleaning git history..."
    git checkout --orphan temp_branch 2>/dev/null
    git add -A
    git commit -m "cleanup $TIMESTAMP" 2>/dev/null
    git branch -D "$GITHUB_BRANCH" 2>/dev/null
    git branch -m "$GITHUB_BRANCH" 2>/dev/null
    git gc --aggressive --prune=all 2>/dev/null
fi

# Push
git add -A
if ! git diff --staged --quiet 2>/dev/null; then
    git commit -m "backup $TIMESTAMP | $TOTAL_SIZE" 2>/dev/null
    if git push origin "$GITHUB_BRANCH" 2>/dev/null; then
        echo "   Pushed to GitHub"
    else
        git push -f origin "$GITHUB_BRANCH" 2>/dev/null
        echo "   Force pushed"
    fi
else
    echo "   No changes"
fi

echo "Done: $TOTAL_SIZE, $FILE_COUNT files"
