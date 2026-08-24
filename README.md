# Metio Monitoring

Instance Zabbix auto-hébergée pour centraliser la supervision des serveurs, endpoints opérationnels et alertes. L'administration passe par une seule URL, une seule connexion et l'interface native Zabbix.

Le périmètre initial est volontairement limité à cinq applications : **Eviamemo**, **Eviaway**, **Npec**, **Stimergie Image Hub** et **TransCare**. Aucune URL, aucun token et aucune hypothèse sur leurs JSON ne sont enregistrés dans ce dépôt.

## Ce qui est déployé

- PostgreSQL, stockage persistant de Zabbix ;
- Zabbix Server, qui collecte les agents et les endpoints ;
- Zabbix Web, seule interface exposée via Traefik/Dokploy ;
- un bootstrap one-shot qui sécurise le compte administrateur et précrée les cinq applications désactivées ;
- le modèle `Metio API /ops — JSON générique`, utilisable dans le Host Wizard.

Le serveur Zabbix dispose aussi d'un réseau Docker dédié aux sorties HTTP vers les endpoints supervisés. PostgreSQL, le bootstrap et l'interface Web restent sur le réseau interne ; aucun port web supplémentaire n'est exposé.

Il n'y a ni Prometheus, ni Grafana, ni Alertmanager dans cette version.

## Premier déploiement Dokploy

1. Définir ce dépôt comme application Docker Compose dans Dokploy.
2. Créer les variables suivantes dans Dokploy, sans les ajouter au Git :
   - `MONITORING_DOMAIN` ;
   - `POSTGRES_PASSWORD` ;
   - `ZABBIX_ADMIN_PASSWORD` ;
   - `ZABBIX_SERVER_PORT` si le port par défaut `10051` ne convient pas.
3. Vérifier que `DOKPLOY_NETWORK` désigne le réseau externe de Traefik (par défaut `dokploy-network`).
4. Déployer, puis attendre la fin du service `bootstrap`.
5. Se connecter à `https://MONITORING_DOMAIN` avec `Admin` et `ZABBIX_ADMIN_PASSWORD`.

Le bootstrap ne s'exécute qu'une seule fois grâce au volume `bootstrap-state`. Il ne remplace donc jamais ultérieurement un mot de passe ou une configuration modifiés depuis l'interface.

## Ajouter une application

Les cinq hôtes sont visibles dans `Data collection → Hosts`, mais désactivés. Le parcours détaillé pour renseigner une URL `/ops`, tester le JSON, ajouter des JSONPath et créer les alertes est dans [docs/endpoint-configuration.md](docs/endpoint-configuration.md). Le [contrat recommandé des endpoints](docs/monitoring-endpoint-contract.md) décrit la base commune à privilégier pour les nouveaux projets.

La structure du JSON est libre. Le modèle conserve d'abord la réponse brute ; les indicateurs particuliers à une application deviennent des *dependent items* dans Zabbix. Il utilise le header `X-Monitoring-Token` avec une macro secrète et garde son item ainsi que son trigger désactivés tant que l'URL n'a pas été testée. Cela évite d'imposer un contrat artificiel à Eviamemo, Eviaway, Npec, Stimergie Image Hub ou TransCare, ou de créer une alerte sur une URL d'exemple.

## Ajouter un serveur

Le parcours d'ajout d'un agent Linux actif et chiffré est dans [docs/server-agents.md](docs/server-agents.md). Un agent est installé sur chaque serveur, mais l'exploitation reste dans la même interface Zabbix.

## Vérifications locales

```sh
docker compose --env-file .env.example config --quiet
sh -n bootstrap/seed.sh
jq empty bootstrap/projects.json
```

Ces commandes valident la composition et les fichiers du dépôt ; elles ne prouvent pas qu'un déploiement Dokploy, un DNS, un firewall ou un endpoint applicatif fonctionne.
