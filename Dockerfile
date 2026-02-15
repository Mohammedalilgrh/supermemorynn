# ============================================
# Stage 1: Alpine - نجهز كل شي
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
      ca-certificates && \
    mkdir -p /toolbox && \
    cp $(which git)       /toolbox/ && \
    cp $(which curl)      /toolbox/ && \
    cp $(which jq)        /toolbox/ && \
    cp $(which sqlite3)   /toolbox/ && \
    cp $(which split)     /toolbox/ && \
    cp $(which sha256sum) /toolbox/ && \
    cp $(which stat)      /toolbox/ && \
    cp $(which du)        /toolbox/ && \
    cp $(which sort)      /toolbox/ && \
    cp $(which tail)      /toolbox/ && \
    cp $(which tac)       /toolbox/ && \
    cp $(which awk)       /toolbox/ && \
    cp $(which xargs)     /toolbox/ && \
    cp $(which find)      /toolbox/ && \
    cp $(which wc)        /toolbox/ && \
    cp $(which cut)       /toolbox/ && \
    cp $(which tr)        /toolbox/ && \
    cp $(which gzip)      /toolbox/ && \
    cp $(which tar)       /toolbox/ && \
    ls -la /toolbox/

# ============================================
# Stage 2: n8n + الأدوات
# ============================================
FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

# الأدوات
COPY --from=tools /toolbox/              /usr/local/bin/

# Git extra files
COPY --from=tools /usr/libexec/git-core/ /usr/local/libexec/git-core/
COPY --from=tools /usr/share/git-core/   /usr/share/git-core/

# كل المكتبات (مهم جداً!)
COPY --from=tools /usr/lib/              /usr/local/lib/
COPY --from=tools /lib/                  /usr/local/lib2/

# SSL
COPY --from=tools /etc/ssl/certs/        /etc/ssl/certs/

# المسارات
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH"
ENV GIT_EXEC_PATH="/usr/local/libexec/git-core"
ENV PATH="/usr/local/bin:$PATH"

# المجلدات
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# السكربتات
COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
