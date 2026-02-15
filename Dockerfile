FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

RUN set -eux; \
  echo "=== OS RELEASE ==="; (cat /etc/os-release || true); \
  echo "=== WHICH apk/apt-get ==="; (command -v apk || true); (command -v apt-get || true); \
  if command -v apk >/dev/null 2>&1; then \
    echo "=== APK REPOS (before) ==="; (cat /etc/apk/repositories || true); \
    # بعض الصور تكون repos https وتسبب مشاكل، نخليها http كـ fallback
    sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true; \
    echo "=== APK REPOS (after) ==="; (cat /etc/apk/repositories || true); \
    apk update; \
    apk add --no-cache \
      ca-certificates \
      git \
      curl \
      jq \
      sqlite \
      tar \
      gzip \
      coreutils \
      findutils; \
    update-ca-certificates || true; \
  elif command -v apt-get >/dev/null 2>&1; then \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      curl \
      jq \
      sqlite3 \
      tar \
      gzip \
      coreutils \
      findutils; \
    rm -rf /var/lib/apt/lists/*; \
  else \
    echo "ERROR: No supported package manager found (apk/apt-get)." >&2; \
    exit 1; \
  fi

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /scripts /backup-data /home/node/.n8n

COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} \; && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENV N8N_USER_FOLDER=/home/node/.n8n
ENV GIT_TERMINAL_PROMPT=0

ENTRYPOINT ["sh", "/scripts/start.sh"]
