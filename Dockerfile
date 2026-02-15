FROM docker.n8n.io/n8nio/n8n:2.3.6

USER root

# تثبيت الأدوات اللازمة لنظام Debian
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    bash \
    curl \
    jq \
    sqlite3 \
    tar \
    gzip \
    && rm -rf /var/lib/apt/lists/*

# إنشاء المجلدات الضرورية
RUN mkdir -p /scripts /backup-data /home/node/.n8n

# نسخ السكربتات
COPY scripts/ /scripts/

# تصحيح صيغة الملفات (لضمان عملها على لينكس) ومنح صلاحيات التشغيل
RUN sed -i 's/\r$//' /scripts/*.sh
RUN chmod +x /scripts/*.sh
RUN chown -R node:node /home/node/.n8n /scripts /backup-data

USER node
WORKDIR /home/node

# تشغيل السكربت الرئيسي
ENTRYPOINT ["sh", "/scripts/start.sh"]
