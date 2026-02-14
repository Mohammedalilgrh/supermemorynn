#!/bin/sh

echo "=== n8n Full Restore ==="

if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_REPO_OWNER" ] || [ -z "$GITHUB_REPO_NAME" ]; then
    echo "Set: GITHUB_TOKEN, GITHUB_REPO_OWNER, GITHUB_REPO_NAME"
    exit 1
fi

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"

cd /tmp
rm -rf n8n-restore
mkdir -p n8n-restore
cd n8n-restore

echo "Downloading..."
git clone --branch "$GITHUB_BRANCH" --depth 1 "$REPO_URL" repo

if [ ! -d "repo/n8n-data" ]; then
    echo "ERROR: No data!"
    exit 1
fi

mkdir -p "$N8N_DIR"

cp -r repo/n8n-data/* "$N8N_DIR/" 2>/dev/null || true
cp repo/n8n-data/.* "$N8N_DIR/" 2>/dev/null || true

if [ -f "$N8N_DIR/database.sqlite.gz" ]; then
    gunzip -f "$N8N_DIR/database.sqlite.gz"
fi

rm -f "$N8N_DIR/stats.json" 2>/dev/null
rm -f "$N8N_DIR/env_encryption_key.txt" 2>/dev/null
rm -rf "$N8N_DIR/exported-workflows" 2>/dev/null

echo ""
echo "=== Restore Complete ==="
cat repo/n8n-data/stats.json 2>/dev/null
echo ""

rm -rf /tmp/n8n-restore
