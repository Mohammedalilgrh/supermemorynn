# ============================================
# Stage 1: Alpine - نجهز الأدوات
# ============================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      git \
      curl \
      jq \
      sqlite \
      tar \
      gzip \
      coreutils \
      findutils \
      ca-certificates

# ============================================
# Stage 2: n8n + الأدوات
# ============================================
FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

COPY --from=tools /usr/bin/git           /usr/local/bin/git
COPY --from=tools /usr/bin/curl          /usr/local/bin/curl
COPY --from=tools /usr/bin/jq            /usr/local/bin/jq
COPY --from=tools /usr/bin/sqlite3       /usr/local/bin/sqlite3
COPY --from=tools /usr/bin/split         /usr/local/bin/split
COPY --from=tools /usr/bin/sha256sum     /usr/local/bin/sha256sum
COPY --from=tools /usr/bin/stat          /usr/local/bin/stat
COPY --from=tools /usr/bin/du            /usr/local/bin/du
COPY --from=tools /usr/bin/sort          /usr/local/bin/sort
COPY --from=tools /usr/bin/tail          /usr/local/bin/tail
COPY --from=tools /usr/bin/tac           /usr/local/bin/tac
COPY --from=tools /usr/bin/xargs         /usr/local/bin/xargs
COPY --from=tools /usr/bin/find          /usr/local/bin/find
COPY --from=tools /usr/bin/wc            /usr/local/bin/wc
COPY --from=tools /usr/bin/cut           /usr/local/bin/cut
COPY --from=tools /usr/bin/tr            /usr/local/bin/tr

COPY --from=tools /usr/libexec/git-core/ /usr/local/libexec/git-core/
COPY --from=tools /usr/share/git-core/   /usr/share/git-core/
COPY --from=tools /usr/lib/              /usr/local/lib/
COPY --from=tools /etc/ssl/certs/        /etc/ssl/certs/

ENV LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
ENV GIT_EXEC_PATH="/usr/local/libexec/git-core"
ENV PATH="/usr/local/bin:$PATH"

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
