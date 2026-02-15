FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Tools required by backup/restore scripts
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      curl \
      jq \
      sqlite3 \
      tar \
      gzip \
      coreutils \
      findutils \
    && rm -rf /var/lib/apt/lists/*

# Create folders with correct ownership
RUN install -d -o node -g node /scripts /backup-data /home/node/.n8n

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
