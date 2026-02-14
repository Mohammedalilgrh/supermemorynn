FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

RUN if command -v apk > /dev/null; then \
        apk add --no-cache git bash curl jq tar gzip dos2unix; \
    elif command -v apt-get > /dev/null; then \
        apt-get update && apt-get install -y git bash curl jq tar gzip dos2unix && rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf > /dev/null; then \
        dnf install -y git bash curl jq tar gzip dos2unix; \
    elif command -v yum > /dev/null; then \
        yum install -y git bash curl jq tar gzip dos2unix; \
    elif command -v microdnf > /dev/null; then \
        microdnf install -y git bash curl jq tar gzip; \
    fi

RUN mkdir -p /scripts /backup-data /home/node/.n8n

COPY scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh
RUN chmod +x /scripts/*.sh
RUN chown -R node:node /home/node/.n8n /scripts /backup-data

USER node
WORKDIR /home/node

ENTRYPOINT ["/scripts/start.sh"]
