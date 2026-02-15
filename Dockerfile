# ============================================
# Stage 1: Debian - نبني كل الأدوات
# ============================================
FROM debian:bookworm-slim AS tools

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      curl \
      jq \
      sqlite3 \
      tar \
      gzip \
      coreutils \
      findutils \
      bash \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# ============================================
# Stage 2: n8n + الأدوات
# ============================================
FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

# نسخ كل شي من Debian (مضمون ما يفوت شي)
COPY --from=tools /usr/bin/           /usr/bin/
COPY --from=tools /usr/lib/           /usr/lib/
COPY --from=tools /bin/               /bin/
COPY --from=tools /lib/               /lib/
COPY --from=tools /etc/ssl/           /etc/ssl/
COPY --from=tools /usr/share/git-core/ /usr/share/git-core/
COPY --from=tools /usr/share/ca-certificates/ /usr/share/ca-certificates/

# تحقق بسيط بدون which
RUN echo "=== Verify ===" && \
    ls -la /usr/bin/git && \
    ls -la /usr/bin/curl && \
    ls -la /usr/bin/jq && \
    ls -la /usr/bin/sqlite3 && \
    ls -la /usr/bin/split && \
    ls -la /usr/bin/sha256sum && \
    ls -la /usr/bin/awk && \
    ls -la /usr/bin/xargs && \
    ls -la /usr/bin/find && \
    ls -la /usr/bin/tac && \
    ls -la /usr/bin/bash && \
    /usr/bin/git --version && \
    echo "=== ALL OK ==="

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
