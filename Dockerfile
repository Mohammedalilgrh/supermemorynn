# ============================================
# Stage 1: Debian (مو Alpine) - مضمون أكثر
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

# نسخ الأدوات من Debian
COPY --from=tools /usr/bin/git           /usr/bin/git
COPY --from=tools /usr/bin/curl          /usr/bin/curl
COPY --from=tools /usr/bin/jq            /usr/bin/jq
COPY --from=tools /usr/bin/sqlite3       /usr/bin/sqlite3
COPY --from=tools /usr/bin/split         /usr/bin/split
COPY --from=tools /usr/bin/sha256sum     /usr/bin/sha256sum
COPY --from=tools /usr/bin/stat          /usr/bin/stat
COPY --from=tools /usr/bin/du            /usr/bin/du
COPY --from=tools /usr/bin/sort          /usr/bin/sort
COPY --from=tools /usr/bin/tail          /usr/bin/tail
COPY --from=tools /usr/bin/tac           /usr/bin/tac
COPY --from=tools /usr/bin/awk           /usr/bin/awk
COPY --from=tools /usr/bin/xargs         /usr/bin/xargs
COPY --from=tools /usr/bin/find          /usr/bin/find
COPY --from=tools /usr/bin/wc            /usr/bin/wc
COPY --from=tools /usr/bin/cut           /usr/bin/cut
COPY --from=tools /usr/bin/tr            /usr/bin/tr
COPY --from=tools /usr/bin/bash          /usr/bin/bash
COPY --from=tools /usr/bin/gzip          /usr/bin/gzip
COPY --from=tools /bin/tar               /bin/tar

# Git needs extra files
COPY --from=tools /usr/lib/git-core/             /usr/lib/git-core/
COPY --from=tools /usr/share/git-core/           /usr/share/git-core/

# Shared libraries (required for git, curl, sqlite3, jq)
COPY --from=tools /lib/x86_64-linux-gnu/         /lib/x86_64-linux-gnu/
COPY --from=tools /usr/lib/x86_64-linux-gnu/     /usr/lib/x86_64-linux-gnu/

# SSL certificates
COPY --from=tools /etc/ssl/                      /etc/ssl/
COPY --from=tools /usr/share/ca-certificates/    /usr/share/ca-certificates/

# تحقق إن كل أداة موجودة
RUN set -e && \
    echo "=== Verifying tools ===" && \
    which git && \
    which curl && \
    which jq && \
    which sqlite3 && \
    which tar && \
    which gzip && \
    which split && \
    which sha256sum && \
    which stat && \
    which du && \
    which sort && \
    which tail && \
    which tac && \
    which awk && \
    which xargs && \
    which find && \
    which cut && \
    which tr && \
    which bash && \
    git --version && \
    echo "=== ALL TOOLS FOUND ==="

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
