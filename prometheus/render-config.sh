#!/bin/sh
set -eu

: "${PANTHERA_METRICS_AUTH_TOKEN:?PANTHERA_METRICS_AUTH_TOKEN is required}"

escaped_token=$(printf '%s' "$PANTHERA_METRICS_AUTH_TOKEN" | sed 's/[\\/&]/\\&/g')
sed "s/__PANTHERA_METRICS_AUTH_TOKEN__/$escaped_token/g" \
  /etc/prometheus/prometheus.yml.tmpl \
  >/etc/prometheus/prometheus.yml

exec /bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.enable-lifecycle
