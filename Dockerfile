# ============================================
# Stage 1: Alpine (نفس نوع n8n image)
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
# Stage 2: n8n + الأدوات (بدون كسر النظام)
# ============================================
FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

# ننسخ بس الأدوات (ما نلمس /bin/ أو /lib/)
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

# awk (بـ Alpine اسمه gawk بعد تثبيت coreutils/findutils)
COPY --from=tools /usr/bin/gawk          /usr/local/bin/gawk
RUN ln -sf /usr/local/bin/gawk /usr/local/bin/awk

# Git extra files
COPY --from=tools /usr/libexec/git-core/ /usr/local/libexec/git-core/
COPY --from=tools /usr/share/git-core/   /usr/share/git-core/

# المكتبات المطلوبة (بمجلد منفصل ما يكسر النظام)
COPY --from=tools /usr/lib/              /usr/local/lib/
COPY --from=tools /lib/                  /usr/local/lib/alpine/

# SSL certificates
COPY --from=tools /etc/ssl/certs/        /etc/ssl/certs/

# ضبط مسار المكتبات
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib/alpine:$LD_LIBRARY_PATH"
ENV GIT_EXEC_PATH="/usr/local/libexec/git-core"
ENV PATH="/usr/local/bin:$PATH"

# تحقق
RUN echo "=== Verify ===" && \
    /usr/local/bin/git --version && \
    /usr/local/bin/curl --version 2>&1 | head -1 && \
    /usr/local/bin/jq --version && \
    /usr/local/bin/sqlite3 --version && \
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
