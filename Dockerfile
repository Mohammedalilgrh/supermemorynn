# ============================================
# Stage 1: Alpine كامل - نبني كل الأدوات
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
      bash \
      openssh-client \
      ca-certificates

# ============================================
# Stage 2: n8n + الأدوات
# ============================================
FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

# نسخ كل الأدوات والمكتبات من Alpine
COPY --from=tools /usr/bin/           /usr/bin/
COPY --from=tools /usr/lib/           /usr/lib/
COPY --from=tools /usr/libexec/       /usr/libexec/
COPY --from=tools /usr/share/git-core/ /usr/share/git-core/
COPY --from=tools /bin/tar            /bin/tar
COPY --from=tools /usr/bin/gzip       /usr/bin/gzip
COPY --from=tools /etc/ssl/           /etc/ssl/
COPY --from=tools /usr/share/ca-certificates/ /usr/share/ca-certificates/

# تحقق إن كل أداة شغالة
RUN set -e && \
    echo "=== Verifying tools ===" && \
    git --version && \
    curl --version | head -1 && \
    jq --version && \
    sqlite3 --version && \
    tar --version | head -1 && \
    gzip --version | head -1 && \
    split --version | head -1 && \
    sha256sum --version | head -1 && \
    stat --version | head -1 && \
    du --version | head -1 && \
    sort --version | head -1 && \
    tail --version | head -1 && \
    tac --version | head -1 && \
    awk --version | head -1 && \
    xargs --version | head -1 && \
    find --version | head -1 && \
    cut --version | head -1 && \
    tr --version | head -1 && \
    echo "=== ALL TOOLS OK ==="

# إعداد المجلدات
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# نسخ السكربتات
COPY --chown=node:node scripts/ /scripts/

# إصلاح line endings + صلاحيات
RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
