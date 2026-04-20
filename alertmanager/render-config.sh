#!/bin/sh
set -eu

: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL is required}"
: "${SLACK_CHANNEL:=#monitoring}"

cat >/etc/alertmanager/alertmanager.yml <<EOF
global:
  resolve_timeout: 5m

route:
  receiver: slack-notifications
  group_by: ["alertname", "server_name", "instance"]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h

receivers:
  - name: slack-notifications
    slack_configs:
      - api_url: "${SLACK_WEBHOOK_URL}"
        channel: "${SLACK_CHANNEL}"
        send_resolved: true
        title: >-
          [{{ .Status | toUpper }}]
          {{ if .CommonLabels.server_name }}{{ .CommonLabels.server_name }}{{ else }}{{ .CommonLabels.alertname }}{{ end }}
        text: >-
          {{ range .Alerts -}}
          *Alerte:* {{ .Annotations.summary }}
          *Description:* {{ .Annotations.description }}
          *Statut:* {{ .Status }}
          {{ end }}
EOF

exec /bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/alertmanager
