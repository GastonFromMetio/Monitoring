# Monitoring stack

Stack Docker simple pour Dokploy avec :

- `Prometheus` pour le scraping et les alertes
- `Alertmanager` pour l'envoi des notifications Slack
- `Grafana` pour les dashboards
- `node-exporter` pour les ressources serveurs

## Ce que couvre la stack

- Ressources des serveurs configurés dans Prometheus
- Endpoints `/metrics` de serveurs applicatifs
- Alertes sur les cibles down/up
- Alertes sur la santé de la stack elle-même

## Fichiers importants

- [`docker-compose.yml`](./docker-compose.yml)
- [`prometheus/prometheus.yml.tmpl`](./prometheus/prometheus.yml.tmpl)
- [`prometheus/alerts.yml`](./prometheus/alerts.yml)
- [`prometheus/render-config.sh`](./prometheus/render-config.sh)
- [`alertmanager/render-config.sh`](./alertmanager/render-config.sh)
- [`grafana/provisioning/datasources/datasource.yml`](./grafana/provisioning/datasources/datasource.yml)
- [`grafana/provisioning/dashboards/dashboards.yml`](./grafana/provisioning/dashboards/dashboards.yml)
- [`grafana/dashboards/overview.json`](./grafana/dashboards/overview.json)

## Mise en route

1. Copier `.env.example` en `.env` et renseigner :
   - `GRAFANA_ADMIN_PASSWORD`
   - `PANTHERA_METRICS_AUTH_TOKEN`
   - `SLACK_WEBHOOK_URL`
   - `SLACK_CHANNEL` si besoin
2. Lancer la stack avec Docker Compose ou via Dokploy

## Ajouter un serveur

Pour monitorer un nouveau serveur Linux :

- Ajouter son `node-exporter` dans `prometheus/prometheus.yml.tmpl`
- Donner un `server_name` unique
- Réutiliser le même label dans les dashboards et alertes

Pour monitorer un nouvel endpoint `/metrics` :

- Ajouter une nouvelle cible dans le job `app-metrics`
- Si l'endpoint nécessite un autre token, créer un nouveau job

## Point d'attention

L'alerte `AppRestartLoop` suppose que l'endpoint expose `process_start_time_seconds`.
Si ce n'est pas le cas, il faut soit ajouter cette métrique côté application, soit remplacer cette règle par une métrique métier plus adaptée.
