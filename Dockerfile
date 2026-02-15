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
    echo "=== LOCATIONS ===" && \
    which git && \
    which curl && \
    which jq && \
    which sqlite3 && \
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
    which wc && \
    which cut && \
    which tr && \
    which gzip && \
    which tar && \
    echo "=== DONE ==="

FROM docker.n8n.io/n8nio/n8n:2.3.6
USER root
RUN echo "test only"
