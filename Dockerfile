FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

# Install required tools for backup/restore scripts (auto-detect apk vs apt-get)
RUN set -eux; \
  if command -v apk >/dev/null 2>&1; then \
    echo "Using apk"; \
    # Ensure repositories exist and avoid TLS issues by using http (Render sometimes has TLS hiccups during build)
    ALPINE_VER="$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)"; \
    if [ ! -s /etc/apk/repositories ] && [ -n "$ALPINE_VER" ]; then \
      printf "http://dl-cdn.alpinelinux.org/alpine/v%s/main\nhttp://dl-cdn.alpinelinux.org/alpine/v%s/community\n" "$ALPINE_VER" "$ALPINE_VER" > /etc/apk/repositories; \
    fi; \
    sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true; \
    for i in 1 2 3; do apk update && break || sleep 2; done; \
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
    echo "Using apt-get"; \
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
    echo "ERROR: No supported package manager found (apk/apt-get)" >&2; \
    exit 1; \
  fi

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# Copy scripts as node owner (avoids extra chmod/chown issues)
COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
