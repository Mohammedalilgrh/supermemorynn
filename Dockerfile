FROM docker.n8n.io/n8nio/n8n:2.3.6-debian

USER root

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
