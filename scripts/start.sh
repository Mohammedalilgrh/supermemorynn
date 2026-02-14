#!/bin/sh
set -e

echo ""
echo "========================================="
echo "  n8n + GitHub Permanent Storage"
echo "  INSTANT SAVE MODE"
echo "========================================="
echo ""

if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_REPO_OWNER" ] || [ -z "$GITHUB_REPO_NAME" ]; then
    echo "ERROR: Set GITHUB_TOKEN, GITHUB_REPO_OWNER, GITHUB_REPO_NAME"
    exit 1
fi

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-120}"
N8N_DIR="/home/node/.n8n"
WORK="/backup-data"
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

echo "Owner: $GITHUB_REPO_OWNER"
echo "Repo: $GITHUB_REPO_NAME"
echo ""

git config --global user.email "n8n-bot@automated.com"
git config --global user.name "n8n Auto Backup"
git config --global init.defaultBranch "$GITHUB_BRANCH"

echo "Restoring data from GitHub..."

cd "$WORK"
rm -rf repo

if git clone --branch "$GITHUB_BRANCH" --single-branch --depth 1 "$REPO_URL" repo 2>/dev/null; then
    echo "Connected to repo"

    if [ -d "repo/n8n-data" ]; then
        echo "Found saved data! Restoring..."

        cp -r repo/n8n-data/* "$N8N_DIR/" 2>/dev/null || true
        cp repo/n8n-data/.* "$N8N_DIR/" 2>/dev/null || true

        if [ -f "$N8N_DIR/database.sqlite.gz" ] && [ ! -f "$N8N_DIR/database.sqlite" ]; then
            gunzip -f "$N8N_DIR/database.sqlite.gz"
            echo "   OK: database (decompressed)"
        fi

        rm -f "$N8N_DIR/stats.json" 2>/dev/null
        rm -f "$N8N_DIR/env_encryption_key.txt" 2>/dev/null
        rm -rf "$N8N_DIR/exported-workflows" 2>/dev/null

        echo "Restore complete!"
        echo "Files:"
        ls -la "$N8N_DIR/" 2>/dev/null | head -15
        echo ""

        if [ -f "repo/n8n-data/stats.json" ]; then
            echo "Last backup:"
            cat repo/n8n-data/stats.json
            echo ""
        fi
    else
        echo "First run - no data yet"
    fi
else
    echo "New repo, initializing..."
    mkdir -p repo
    cd repo
    git init
    git checkout -b "$GITHUB_BRANCH"
    mkdir -p n8n-data
    echo "{\"init\": true}" > n8n-data/init.json
    git add .
    git commit -m "init"
    git remote add origin "$REPO_URL"
    git push -u origin "$GITHUB_BRANCH" 2>/dev/null || true
    cd "$WORK"
fi

# ============================================
# INSTANT SAVE: Monitor database changes
# Save to GitHub when database changes
# ============================================
echo "Starting INSTANT save monitor..."

(
    sleep 30
    echo "Instant save monitor active"

    # Save hash of database to detect changes
    LAST_HASH=""

    while true; do
        sleep 10

        if [ -f "$N8N_DIR/database.sqlite" ]; then
            # Get current hash
            CURRENT_HASH=$(md5sum "$N8N_DIR/database.sqlite" 2>/dev/null | cut -d' ' -f1 || echo "none")

            if [ "$CURRENT_HASH" != "$LAST_HASH" ] && [ "$CURRENT_HASH" != "none" ]; then
                echo "[INSTANT] Database changed! Saving..."
                /scripts/backup.sh 2>&1 | while IFS= read -r line; do
                    echo "[INSTANT] $line"
                done
                LAST_HASH="$CURRENT_HASH"
            fi
        fi
    done
) &

# ============================================
# Regular backup every BACKUP_INTERVAL
# ============================================
(
    sleep 60
    echo "Regular backup active (every ${BACKUP_INTERVAL}s)"
    while true; do
        sleep "$BACKUP_INTERVAL"
        /scripts/backup.sh 2>&1 | while IFS= read -r line; do
            echo "[BACKUP] $line"
        done
    done
) &

cleanup() {
    echo ""
    echo "Shutting down, final save..."
    /scripts/backup.sh
    echo "Saved!"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

echo ""
echo "========================================="
echo "  Starting n8n..."
echo "  Database monitor: every 10 seconds"
echo "  Full backup: every ${BACKUP_INTERVAL} seconds"
echo "========================================="
echo ""

exec n8n start
