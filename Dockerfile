FROM n8nio/n8n:latest

USER root

# تثبيت الأدوات المطلوبة
RUN apk add --no-cache \
    git \
    bash \
    curl \
    jq \
    openssh-client \
    tar \
    gzip

# إنشاء مجلدات العمل
RUN mkdir -p /backup-scripts /n8n-backup /home/node/.n8n

# نسخ السكربتات
COPY scripts/start.sh /backup-scripts/start.sh
COPY scripts/backup.sh /backup-scripts/backup.sh
COPY scripts/restore.sh /backup-scripts/restore.sh

# صلاحيات التشغيل
RUN chmod +x /backup-scripts/*.sh
RUN chown -R node:node /home/node/.n8n /backup-scripts /n8n-backup

USER node

WORKDIR /home/node

ENTRYPOINT ["/backup-scripts/start.sh"]
