FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

RUN apk add --no-cache git bash curl jq tar gzip

RUN mkdir -p /scripts /backup-data /home/node/.n8n

COPY scripts/ /scripts/

RUN chmod +x /scripts/*.sh
RUN chown -R node:node /home/node/.n8n /scripts /backup-data

USER node
WORKDIR /home/node

ENTRYPOINT ["/scripts/start.sh"]
