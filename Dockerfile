FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

# Install required tools for backup/restore scripts (auto-detect apk vs apt-get)
RUN set -eux; \
  if command -v apk >/dev/null 2>&1; then \
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
  elif command -v apt-get >/dev/null 2>&1; then \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      curl \
      jq \
      sqlite3 \
      tar \
      gzip \
      coreutils \
      findutils && \
    rm -rf /var/lib/apt/lists/*; \
  else \
    echo "ERROR: No supported package manager found (apk/apt-get)." >&2; \
    exit 1; \
  fi

# Create folders with correct ownership
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /scripts /backup-data /home/node/.n8n

# Copy scripts
COPY --chown=node:node scripts/ /scripts/

# Fix Windows CRLF + make executable
RUN find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} \; && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENV N8N_USER_FOLDER=/home/node/.n8n
ENV GIT_TERMINAL_PROMPT=0

ENTRYPOINT ["sh", "/scripts/start.sh"]
