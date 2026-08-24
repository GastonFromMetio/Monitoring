# Eviamemo — Exploitation

Le bootstrap crée le dashboard Zabbix `Eviamemo — Exploitation`. Il complète la Tour de contrôle :
la Tour de contrôle répond à « quelle application faut-il regarder ? », tandis que ce dashboard
répond à « qu'est-ce qui explique l'état d'Eviamemo ? ».

## Pages

- **Exploitation** : état global, PostgreSQL, Redis, workers, profondeur et ancienneté de la queue
  par défaut, heartbeat du worker, version déployée et incidents ouverts.
- **Activité** : alertes déclarées par Eviamemo sur sa fenêtre `/ops`, erreurs LLM, analyses en
  erreur et historique récent des signaux de travail.
- **Données /ops** : les cinq derniers snapshots bruts, horodatés, pour approfondir sans masquer
  une donnée collectée.

Les métriques proviennent d'une seule requête `GET /ops` par minute. Les items Zabbix sont tous
dépendants de cette réponse ; le dashboard n'ajoute donc aucune charge à Eviamemo.

## Signaux réellement extraits

| Domaine | Item Zabbix | JSONPath |
| --- | --- | --- |
| Dépendances | `eviamemo.database.status` | `$.checks.database.status` |
| Dépendances | `eviamemo.cache.status` | `$.checks.cache.status` |
| Workers | `eviamemo.workers.status` | `$.checks.workers.status` |
| Workers | `eviamemo.worker.queue.heartbeat_age` | `$.checks.workers.processes.queue.heartbeat_age_s` |
| Charge | `eviamemo.queue.default.depth` | `$.checks.workers.queues.items[?(@.name == 'default')].depth.first()` |
| Charge | `eviamemo.queue.default.oldest_ready_age` | `$.checks.workers.queues.items[?(@.name == 'default')].oldest_ready_job_age_s.first()` |
| Activité | `eviamemo.activity.alerts.critical` / `.warning` | `$.activity.alerts.critical` / `.warning` |
| Activité | `eviamemo.activity.llm.errors` | `$.activity.llm.errors` |
| Activité | `eviamemo.activity.generation.failed` | `$.activity.generation.failed` |
| Activité | `eviamemo.activity.analysis.errors` | `$.activity.analysis.errors` |

Les trois triggers précis (PostgreSQL, Redis et workers) sont créés mais restent désactivés. La
profondeur de queue et son ancienneté sont affichées sans seuil arbitraire : les seuils doivent être
choisis après observation de la charge réelle.

## Activation sûre

1. Déployer la version d'Eviamemo qui expose `/ops` et définir un `MONITORING_OPS_TOKEN` unique
   dans son environnement Dokploy.
2. Dans l'hôte Zabbix **Eviamemo**, renseigner `{$OPS.URL}` et la macro secrète `{$OPS.TOKEN}`.
   Le jeton n'est ni écrit dans ce dépôt ni affiché par le dashboard.
3. Tester l'item `/ops: réponse JSON` dans Zabbix. Il doit retourner un snapshot JSON avec un
   `status` et un `generated_at` avant toute activation.
4. Activer l'item maître, l'hôte, puis vérifier le dashboard `Eviamemo — Exploitation` après une à
   deux minutes. Activer ensuite les triggers utiles, y compris les trois triggers précis, une fois
   les premières valeurs validées.

Si un champ n'est pas encore fourni par le snapshot, l'item dépendant ignore cette valeur. Cela
n'invente ni un zéro ni un incident.

## Rattachement au modèle générique

Eviamemo est aussi lié au modèle `Metio API /ops — JSON générique`, comme les autres applications.
Sur les installations historiques, sa sonde dédiée `eviamemo.ops.raw` reste la collecte active : le
rattachement n'active pas l'item générique ni ses triggers. Cela évite une double collecte pendant la
transition. Pour basculer la collecte elle-même vers le modèle, renseigner `{$OPS.URL}` et le secret
`{$OPS.TOKEN}`, tester `/ops`, puis désactiver explicitement la sonde dédiée après validation.
