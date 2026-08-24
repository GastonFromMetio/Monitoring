# Configurer un endpoint opérationnel

Les cinq applications précréées ne supposent ni URL ni structure JSON. Elles sont désactivées après le premier démarrage : activer une application n'est donc jamais une opération implicite.

## Créer une nouvelle application

Pour une application qui ne fait pas partie des hôtes précréés :

1. Ouvrir **Data collection → Hosts → Create host** ou le **Host Wizard**.
2. Ajouter l'hôte au groupe `Metio / Applications` et lier le template `Metio API /ops — JSON générique`.
3. Ajouter les tags d'hôte `metio.kind=application` et `metio.project=<identifiant-technique>`.
4. Définir les macros `{$OPS.URL}` et `{$OPS.TOKEN}`, puis poursuivre avec l'activation ci-dessous.

Ce rattachement au groupe et au template est ce qui rend l'application visible dans la Tour de contrôle et lui fournit sa fiche de santé.

## Ajouter ou activer un endpoint depuis Zabbix

1. Ouvrir **Data collection → Hosts**, puis l'application.
2. Dans **Macros**, remplacer `{$OPS.URL}` par l'URL complète de l'endpoint.
3. Saisir le token partagé par l'application dans `{$OPS.TOKEN}` et conserver le type de macro **Secret text**. Le modèle l'envoie dans le header `X-Monitoring-Token` : le token n'apparaît donc ni dans l'URL ni dans le dépôt.
4. Ouvrir **Items**, sélectionner `/ops: réponse JSON` puis **Test**. Corriger l'URL, le header ou le code attendu avant de l'activer. Cet item est désactivé par défaut, comme son trigger générique, afin qu'une macro d'URL vide ne génère jamais de faux incident.
5. Si l'endpoint suit le contrat recommandé, vérifier les trois items hérités : `/ops: état`, `Version déployée` et `Snapshot /ops généré le`. Ils sont extraits sans requête supplémentaire depuis la réponse brute. Les réponses JSON qui ne les fournissent pas restent valides ; les valeurs absentes sont simplement ignorées.
6. Dans l'hôte, créer les **Dependent items** propres à l'application, avec `/ops: réponse JSON` comme master. Ajouter une étape de prétraitement **JSONPath** avec le chemin réel, puis les tags `metio.domain` et `metio.signal` pour qu'ils soient classés dans le dashboard de l'hôte.
7. Créer le trigger correspondant dans **Data collection → Hosts → Triggers**, avec une durée, une sévérité et des tags adaptés. Les trois triggers hérités de santé (`endpoint`, `dégradée`, `critique`) restent volontairement désactivés jusqu'à cette étape.
8. Activer l'item `/ops: réponse JSON`, les triggers retenus et l'hôte uniquement après que le test et les premières valeurs sont corrects.

À l'activation, l'application apparaît dans **Monitoring → Hosts → Dashboards → Santé de l’application**. Si son endpoint fournit `status`, elle apparaît aussi dans **Dashboards → Métio — Tour de contrôle**. La page `Données` de son dashboard donne accès au JSON brut et aux indicateurs collectés ; les métriques ne doivent donc pas toutes être affichées dans la vue de santé.

Les règles restent alors visibles, modifiables et auditables dans la même interface que les serveurs et les alertes.

## Exemples de mapping

| Signal | JSONPath possible | Type Zabbix | Exemple de trigger |
| --- | --- | --- | --- |
| Profondeur de la première queue déclarée | `$.checks.workers.queues.items[0].depth` | Numeric (unsigned) | `max(/<hôte>/ops.queue.depth,5m)>100` |
| Dernier heartbeat worker | `$.checks.workers.heartbeat_age_s` | Numeric (unsigned), unité `s` | `min(/<hôte>/ops.worker.last_seen,5m)>120` |
| Erreurs récentes | `$.checks.errors.count_last_5m` | Numeric (unsigned) | `max(/<hôte>/ops.errors.last_5m,5m)>3` |
| État d'une dépendance | `$.checks.database.status` | Text | `last(/<hôte>/ops.database.status)<>"ok"` |

Ces chemins sont des exemples, pas un contrat imposé. Une application peut avoir plusieurs queues, un tableau de workers ou aucun worker.

## Classer les métriques pour les rendre consultables

Les tableaux de bord ne déduisent pas l'importance d'une clé JSON. Lors de la création d'un item spécifique, appliquer au minimum les deux tags suivants :

| Tag | Valeurs conseillées | Usage |
| --- | --- | --- |
| `metio.domain` | `workload`, `workers`, `dependencies`, `errors`, `business` | regroupe les indicateurs dans la page `Données` |
| `metio.signal` | `queue_depth`, `latency`, `heartbeat`, `error_count`, `availability` | rend les incidents filtrables et compréhensibles |

Le dashboard de santé reste limité aux informations communes et aux incidents actifs. Une métrique n'y obtient une carte ou un graphe dédié que si elle répond à une question d'exploitation récurrente.

## Quand créer un profil réutilisable

Après avoir configuré une première application d'une même famille, ouvrir son modèle d'endpoint et créer un template Zabbix avec les items dépendants et triggers validés. Les projets qui ont réellement le même JSON pourront alors hériter de ce template ; les autres restent sur le modèle JSON générique.

Ne pas stocker un stack trace, un document métier, un token ou des données personnelles dans l'endpoint. L'endpoint doit exposer des résumés opérationnels : compteurs, états, dates, identifiants techniques et liens internes éventuels.
