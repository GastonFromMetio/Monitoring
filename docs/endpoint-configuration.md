# Configurer un endpoint opérationnel

Les cinq applications précréées ne supposent ni URL ni structure JSON. Elles sont désactivées après le premier démarrage : activer une application n'est donc jamais une opération implicite.

## Ajouter ou activer un endpoint depuis Zabbix

1. Ouvrir **Data collection → Hosts**, puis l'application.
2. Dans **Macros**, remplacer `{$OPS.URL}` par l'URL complète de l'endpoint.
3. Si l'endpoint est protégé, saisir `Bearer <token>` dans `{$OPS.AUTHORIZATION}` et choisir le type de macro **Secret text**.
4. Ouvrir **Items**, sélectionner `/ops: réponse JSON` puis **Test**. Corriger l'URL, le header ou le code attendu avant d'activer l'hôte.
5. Dans l'hôte, créer un **Dependent item** dont le master est `/ops: réponse JSON`. Ajouter une étape de prétraitement **JSONPath** avec le chemin réel de l'application.
6. Créer le trigger correspondant dans **Data collection → Hosts → Triggers**, avec une durée et une sévérité adaptées.
7. Activer l'hôte uniquement après que le test et les premières valeurs sont corrects.

Les règles restent alors visibles, modifiables et auditables dans la même interface que les serveurs et les alertes.

## Exemples de mapping

| Signal | JSONPath possible | Type Zabbix | Exemple de trigger |
| --- | --- | --- | --- |
| Jobs en attente | `$.queue.pending` | Numeric (unsigned) | `max(/<hôte>/ops.queue.pending,5m)>100` |
| Dernier heartbeat worker | `$.workers.default.last_seen_seconds` | Numeric (unsigned), unité `s` | `min(/<hôte>/ops.worker.last_seen,5m)>120` |
| Erreurs récentes | `$.errors.last_5m` | Numeric (unsigned) | `sum(/<hôte>/ops.errors.last_5m,5m)>3` |
| État d'une dépendance | `$.dependencies.redis.status` | Text | `last(/<hôte>/ops.redis.status)<>"ok"` |

Ces chemins sont des exemples, pas un contrat imposé. Une application peut avoir plusieurs queues, un tableau de workers ou aucun worker.

## Quand créer un profil réutilisable

Après avoir configuré une première application d'une même famille, ouvrir son modèle d'endpoint et créer un template Zabbix avec les items dépendants et triggers validés. Les projets qui ont réellement le même JSON pourront alors hériter de ce template ; les autres restent sur le modèle JSON générique.

Ne pas stocker un stack trace, un document métier, un token ou des données personnelles dans l'endpoint. L'endpoint doit exposer des résumés opérationnels : compteurs, états, dates, identifiants techniques et liens internes éventuels.
