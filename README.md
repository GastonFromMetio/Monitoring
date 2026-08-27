# Metio Monitoring

Instance Zabbix auto-hébergée pour centraliser la supervision des serveurs, endpoints opérationnels et alertes. L'administration passe par une seule URL, une seule connexion et l'interface native Zabbix. Elle comprend une **Tour de contrôle** globale et une fiche de santé héritée par chaque application, afin que l'état soit lisible avant d'ouvrir les données détaillées.

Le périmètre initial est volontairement limité à cinq applications : **Eviamemo**, **Eviaway**, **Npec**, **Stimergie Image Hub** et **TransCare**. Seules leurs URLs publiques de présence/readiness sont enregistrées dans le dépôt ; les tokens, URLs `/ops` et contenus métier restent configurés hors Git.

## Ce qui est déployé

- PostgreSQL, stockage persistant de Zabbix ;
- Zabbix Server, qui collecte les agents et les endpoints ;
- un proxy DNS local qui interroge ses upstreams en DNS-over-HTTPS ;
- Zabbix Web, seule interface exposée via Traefik/Dokploy ;
- un bootstrap one-shot qui sécurise le compte administrateur et précrée les cinq applications désactivées ;
- le modèle `Metio API /ops — JSON générique`, utilisable dans le Host Wizard.
- l'hôte `Metio Monitoring — Collecteur HTTP`, qui distingue une panne de sortie réseau d'une panne DNS et bloque les faux positifs applicatifs dépendants ;
- le dashboard global `Métio — Tour de contrôle` : état des applications, gravité et incidents ouverts ;
- le dashboard d'hôte `Santé de l’application` : état, version, snapshot, incidents et données collectées.
- le dashboard `Eviamemo — Exploitation` : dépendances, workers, queues, activité IA et snapshots
  du premier profil applicatif concret.

Le serveur Zabbix dispose aussi d'un réseau Docker dédié aux sorties HTTP vers les endpoints supervisés. PostgreSQL, le bootstrap et l'interface Web restent sur le réseau interne ; aucun port web supplémentaire n'est exposé.

Il n'y a ni Prometheus, ni Grafana, ni Alertmanager dans cette version.

## Premier déploiement Dokploy

1. Définir ce dépôt comme application Docker Compose dans Dokploy.
2. Créer les variables suivantes dans Dokploy, sans les ajouter au Git :
   - `MONITORING_DOMAIN` ;
   - `POSTGRES_PASSWORD` ;
   - `ZABBIX_ADMIN_PASSWORD` ;
   - `MONITORING_DNS_SUBNET` et `MONITORING_DNS_ADDRESS` uniquement si le réseau privé proposé dans `.env.example` entre en conflit avec un réseau existant ;
   - `ZABBIX_SERVER_PORT` si le port par défaut `10051` ne convient pas.
3. Vérifier que `DOKPLOY_NETWORK` désigne le réseau externe de Traefik (par défaut `dokploy-network`).
4. Déployer, puis attendre la fin du service `bootstrap`.
5. Se connecter à `https://MONITORING_DOMAIN` avec `Admin` et `ZABBIX_ADMIN_PASSWORD`.

Le bootstrap ne remplace jamais un mot de passe ou une configuration modifiés depuis l'interface.
Son marqueur de version lui permet seulement d'ajouter une migration de configuration explicitement
prévue lors d'une mise à jour du dépôt.

## Ajouter une application

Les cinq hôtes sont visibles dans `Data collection → Hosts`, mais désactivés. Le parcours détaillé pour renseigner une URL `/ops`, tester le JSON, ajouter des JSONPath et créer les alertes est dans [docs/endpoint-configuration.md](docs/endpoint-configuration.md). Le [contrat recommandé des endpoints](docs/monitoring-endpoint-contract.md) décrit la base commune à privilégier pour les nouveaux projets, tandis que [docs/dashboard-configuration.md](docs/dashboard-configuration.md) explique le cockpit et ses conventions de classement.

Eviamemo est le premier profil concret : les signaux et le parcours d'activation de son dashboard
sont dans [docs/eviamemo-dashboard.md](docs/eviamemo-dashboard.md).

L'architecture effective des alertes HTTP, readiness, `/ops` et du routage
Slack est décrite dans
[docs/alerting-notifications.md](docs/alerting-notifications.md).

La structure du JSON reste libre. Le modèle conserve d'abord la réponse brute ; les indicateurs particuliers à une application deviennent des *dependent items* dans Zabbix. Les nouveaux endpoints qui fournissent l'enveloppe recommandée obtiennent en plus un état coloré et comparable dans la Tour de contrôle. Le modèle utilise le header `X-Monitoring-Token` avec une macro secrète et garde son item ainsi que ses triggers désactivés tant que l'URL n'a pas été testée. Cela évite de créer une alerte sur une macro non configurée.

## Ajouter un serveur

Le parcours d'ajout d'un agent Linux actif et chiffré est dans [docs/server-agents.md](docs/server-agents.md). Un agent est installé sur chaque serveur, mais l'exploitation reste dans la même interface Zabbix.

## Vérifications locales

```sh
docker compose --env-file .env.example config --quiet
sh -n bootstrap/seed.sh
jq empty bootstrap/projects.json
```

Ces commandes valident la composition et les fichiers du dépôt ; elles ne prouvent pas qu'un déploiement Dokploy, un DNS, un firewall ou un endpoint applicatif fonctionne.
