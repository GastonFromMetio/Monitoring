# Contrat recommandé des endpoints de monitoring

Le modèle Zabbix de ce dépôt accepte n'importe quel JSON `/ops`. Pour les nouveaux projets, ce contrat commun rend les alertes et les mappings plus simples, sans imposer de modifier une application déjà instrumentée.

## Rôles des endpoints

- `GET /health` est public, minimal et très léger : il confirme que le processus HTTP répond. Il ne révèle aucune dépendance, erreur ou donnée interne.
- `GET /ready` est facultatif, mais recommandé si la disponibilité dépend d'une base, d'un cache ou d'un autre composant strictement nécessaire. Il retourne `503` lorsqu'un composant indispensable n'est pas prêt.
- `GET /ops` est protégé et strictement en lecture seule. Il retourne un snapshot JSON opérationnel destiné à Zabbix, jamais un dump d'erreurs ou de données métier.

`/ops` doit retourner `200` lorsqu'il arrive à produire le snapshot, même si celui-ci indique un état `degraded` ou `critical`. Les valeurs JSON permettent alors à Zabbix d'expliquer l'alerte. Un `5xx` est réservé à l'incapacité du endpoint à produire une réponse exploitable.

## Enveloppe conseillée pour `/ops`

```json
{
  "schema_version": 1,
  "service": "nom-technique-du-service",
  "generated_at": "2026-08-24T12:00:00Z",
  "status": "ok",
  "release": { "version": "build-ou-commit-sans-secret" },
  "checks": {
    "database": { "status": "ok", "latency_ms": 12 },
    "workers": {
      "status": "ok",
      "heartbeat_age_s": 18,
      "queues": [{ "name": "default", "pending": 0, "oldest_job_age_s": 0 }]
    },
    "errors": { "count_last_5m": 0 }
  }
}
```

Un champ n'est ajouté que si l'application possède une source fiable. Ne jamais transformer une donnée inconnue en `0` : omettre le champ ou retourner `null` avec une raison non sensible. Les états autorisés sont `ok`, `degraded` et `critical`.

## Sécurité et fiabilité

- Protéger `/ops` par un jeton dédié en header, une allowlist réseau ou l'authentification déjà en place ; ne jamais mettre de jeton dans l'URL.
- Ne retourner ni secret, stack trace, message d'exception brut, donnée personnelle, contenu de job ou identifiant métier.
- Utiliser `Cache-Control: no-store`, des timeouts courts et des contrôles bornés ; un appel de monitoring ne doit jamais écrire, lancer un job ou ralentir les requêtes normales.
- Préférer les compteurs et âges : latence, jobs en attente, âge du plus vieux job, âge d'un heartbeat, erreurs récentes, version et horodatage UTC.
- Dans Zabbix, conserver le JSON brut puis extraire les champs réels avec des items dépendants JSONPath. Définir des seuils, durées et conditions de récupération explicites afin d'éviter les alertes transitoires.
