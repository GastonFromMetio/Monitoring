# Cockpit de supervision

Le cockpit ne cherche pas à afficher chaque donnée au même endroit. Il organise l'accès en deux temps : repérer l'application qui requiert une action, puis comprendre son état dans sa propre fiche.

## Tour de contrôle

Ouvrir **Dashboards → Métio — Tour de contrôle** pour la lecture d'exploitation.

- **État des applications** affiche une cellule par application du groupe `Metio / Applications`. La valeur vient de `/ops: état` : `OK`, `Dégradé`, `Critique` ou `Inconnu`.
- **Incidents par gravité** donne le volume réel de problèmes ouverts, y compris lorsqu'un endpoint ne produit plus de nouvelle réponse.
- **Incidents à traiter** contient uniquement les problèmes actifs, leurs tags et leur durée. C'est la liste à suivre, pas une collection de graphiques.

Une cellule conserve la dernière valeur connue si l'endpoint devient indisponible. Le trigger `Endpoint /ops indisponible` est donc l'information qui fait foi dans ce cas ; il apparaît à droite dans les incidents ouverts.

## Fiche d'une application

Depuis **Monitoring → Hosts**, ouvrir le menu de l'hôte puis **Dashboards**. Le template `Metio API /ops — JSON générique` fournit le dashboard `Santé de l’application` à chaque hôte lié.

La page **Santé** ne contient que l'état normalisé, la version, l'horodatage déclaré et les incidents ouverts. La page **Données** contient le JSON `/ops` conservé par Zabbix ainsi qu'un navigateur d'indicateurs regroupés par `metio.domain`.

Cette séparation est volontaire : on accède à toute donnée collectée sans obliger l'astreinte à interpréter une page remplie de métriques non comparables.

## Ajouter une vue spécialisée

Après avoir observé une même famille de signaux sur plusieurs applications, créer un template Zabbix spécialisé plutôt que d'alourdir le cockpit commun. Par exemple : un profil `workers` pour les queues et heartbeats, ou un profil `dependencies` pour la latence base/cache/API.

Chaque profil doit répondre à une question courte et opérationnelle. S'il ne déclenche ni décision ni diagnostic régulier, l'indicateur reste consultable dans `Données` sans carte dédiée.
