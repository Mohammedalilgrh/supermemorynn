#!/bin/sh
set -e

echo ""
echo "========================================="
echo "  n8n + GitHub Permanent Storage"
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
echo "Branch: $GITHUB_BRANCH"
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

        # Restore EVERYTHING back to .n8n
        cp -r repo/n8n-data/* "$N8N_DIR/" 2>/dev/null || true
        cp repo/n8n-data/.* "$N8N_DIR/" 2>/dev/null || true

        # Handle compressed database
        if [ -f "$N8N_DIR/database.sqlite.gz" ] && [ ! -f "$N8N_DIR/database.sqlite" ]; then
            gunzip -f "$N8N_DIR/database.sqlite.gz"
            echo "   OK: database (decompressed)"
        fi

        # Remove files that shouldn't be in .n8n
        rm -f "$N8N_DIR/stats.json" 2>/dev/null
        rm -f "$N8N_DIR/env_encryption_key.txt" 2>/dev/null
        rm -rf "$N8N_DIR/exported-workflows" 2>/dev/null

        echo ""
        echo "Restore complete!"

        # Show stats
        if [ -f "repo/n8n-data/stats.json" ]; then
            echo "Last backup:"
            cat repo/n8n-data/stats.json
            echo ""
        fi

        # Show what was restored
        echo "Files restored:"
        ls -la "$N8N_DIR/" 2>/dev/null | head -20
        echo ""
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

echo "Auto backup every ${BACKUP_INTERVAL} seconds"

(
    sleep 60
    echo "Backup system active"
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
echo "========================================="
echo ""

exec n8n start
