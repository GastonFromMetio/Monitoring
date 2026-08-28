# Architecture des alertes et notifications Zabbix

Ce document décrit la supervision applicative retenue pour Métio. Zabbix reste
l'interface unique pour consulter les états, les incidents, l'historique et les
notifications. La supervision Docker par Zabbix Agent 2 est volontairement
reportée à une étape ultérieure.

## Objectifs

- détecter simplement qu'une application ne répond plus ;
- distinguer une application vivante mais incapable de travailler ;
- expliquer les incidents avec les informations bornées de `/ops` ;
- envoyer sur Slack les incidents qui demandent une action, puis leur
  récupération ;
- éviter plusieurs notifications pour une même panne ;
- ne jamais exposer de secret, trace complète, donnée personnelle ou donnée
  métier dans Zabbix ou Slack.

## Les trois niveaux de contrôle

### 1. Présence HTTP

L'endpoint de présence confirme uniquement que le service HTTP du conteneur
répond. Le chemin peut différer selon l'application : `/health`, `/up` ou
`/healthz.txt`. Zabbix utilise donc une macro `{$HEALTH.URL}` propre à chaque
hôte plutôt qu'un chemin imposé.

Le contrôle est public, léger et exécuté chaque minute. Après trois minutes
sans réponse HTTP 200, Zabbix ouvre un incident de sévérité **Haute** :
`Application inaccessible sur {HOST.NAME}`.

Ce signal répond à la question : **l'application est-elle joignable ?** Il ne
permet pas de conclure que la base, le cache ou les workers fonctionnent.

### 2. Disponibilité fonctionnelle

`/ready` vérifie les dépendances strictement nécessaires à l'application. Il
retourne HTTP 200 lorsque l'application peut travailler et un code d'erreur,
généralement 503, lorsqu'une dépendance indispensable n'est pas prête.

Certaines applications protègent `/ready` avec le même header
`X-Monitoring-Token` que `/ops`. Zabbix réutilise alors la macro secrète
`{$OPS.TOKEN}` ; le jeton ne doit jamais être placé dans l'URL ou le dépôt.

Après cinq minutes sans réponse HTTP 200, Zabbix ouvre un incident de sévérité
**Moyenne** : `Application non prête sur {HOST.NAME}`.

Ce signal répond à la question : **l'application peut-elle assurer son
service ?**

### 3. Diagnostic opérationnel `/ops`

`/ops` reste protégé et en lecture seule. Il doit retourner HTTP 200 lorsqu'il
peut produire un snapshot, y compris si le JSON déclare `degraded` ou
`critical`. Les items dépendants JSONPath transforment ensuite ce snapshot en
signaux précis :

- état global `ok`, `degraded` ou `critical` ;
- base de données et cache ;
- workers et scheduler ;
- profondeur et âge des queues ;
- erreurs récentes ;
- version déployée et fraîcheur du snapshot.

Le JSON brut reste consultable dans Zabbix pour approfondir l'incident. Il ne
doit jamais contenir de secret, stack trace brute, contenu de job, identifiant
métier ni donnée personnelle.

Les alertes readiness et `/ops` dépendent de la présence HTTP. Les alertes
issues du JSON `/ops` dépendent de la disponibilité de leur item maître. Tous
ces contrôles dépendent aussi du collecteur HTTP/DNS Zabbix. Cette hiérarchie
évite qu'un arrêt complet ou une panne de collecte produise en même temps une
alerte HTTP, une alerte `/ready`, une alerte `/ops` et plusieurs alertes de
composants.

## Santé du collecteur Zabbix

Les domaines applicatifs sont résolus normalement par le DNS intégré de Docker,
puis par le résolveur du serveur. Il n'existe aucune association statique entre
une application et une IP dans le Compose : ajouter ou déplacer une application
ne demande donc aucune variable IP dans Dokploy.

L'incident du 27 août 2026 ne venait pas du DNS lui-même. Le poller HTTP agent de
Zabbix avait accumulé des connexions fermées par les serveurs distants
(`CLOSE_WAIT`) jusqu'à atteindre sa limite de 1 024 fichiers ouverts. Il ne
pouvait alors plus créer le socket UDP nécessaire à la résolution DNS et c-ares
retournait le message trompeur `Could not contact DNS servers`.

Les trois items HTTP maîtres génériques (`metio.health.raw`, `metio.ready.raw`
et `metio.ops.raw`) ainsi que l'ancienne sonde `eviamemo.ops.raw` envoient
`Connection: close`. Cela désactive la réutilisation des connexions persistantes
pour ces sondes et empêche le poller HTTP de remplir sa table de descripteurs.
Le redémarrage de `zabbix-server` vide les sockets déjà accumulés ; la migration
de bootstrap applique le header aux items existants sans supprimer leur token.

Le signal racine n'utilise plus des cibles externes différentes des
applications. L'item calculé `metio.collector.apps.missing` compte toutes les
30 secondes les contrôles de présence réels sans valeur depuis deux minutes.
Si au moins trois applications sur cinq sont concernées, Zabbix ouvre un seul
problème `Collecte HTTP multi-applications interrompue`. Les triggers de
présence applicatifs, réglés à trois minutes, en dépendent et ne notifient donc
pas séparément Slack. Ce problème est classé **Information** : il reste visible
dans Zabbix pour porter les dépendances, mais l'action Slack, qui commence à la
sévérité **Moyenne**, ne l'envoie pas.

Les anciens items Cloudflare/Google et les triggers `Sortie HTTP du collecteur
Zabbix indisponible` / `Résolution DNS du collecteur Zabbix indisponible` sont
désactivés. Ils pouvaient rester verts grâce à leur cache pendant que les noms
applicatifs échouaient, ou devenir non supportés parce qu'un seul fournisseur
était filtré : ils ne représentaient pas fidèlement le trafic à protéger.

## Endpoints observés le 26 août 2026

Les codes ci-dessous ont été vérifiés sans envoyer de jeton secret. Un code
401 ou 403 sur `/ready` confirme que la route existe et qu'elle est protégée ;
sa validation fonctionnelle doit être effectuée depuis Zabbix avec
`{$OPS.TOKEN}`.

| Application | Présence retenue | Résultat observé | Readiness | `/ops` |
| --- | --- | --- | --- | --- |
| Eviamemo | `https://eviamemo.713.fr/health` | 200, corps `OK` | `/ready` public, 200 | configuré |
| Eviaway | `https://eviaway.713.fr/health` | 200, JSON `status=ok` | absent, 404 | items `/ops` désactivés |
| Npec | `https://npec.mgacf.fr/up` | 200 | `/ready` protégé, 401 sans jeton | configuré |
| Stimergie Image Hub | `https://stimergie.metio-dev.fr/healthz.txt` | 200, corps `ok` | `/ready` protégé, 403 sans jeton | configuré |
| TransCare | `https://transcare.713.fr/healthz.txt` | 200, corps `healthy` | `/ready` protégé, 403 sans jeton | configuré |

Eviaway reçoit uniquement le contrôle de présence tant que `/ready` et `/ops`
ne sont pas validés. Son hôte est actif, mais les quatre items hérités du
template `/ops` (`metio.ops.raw`, `metio.ops.status.code`,
`metio.ops.generated_at` et `metio.ops.release.version`) sont désactivés. Cela
évite de stocker la page HTML de connexion actuellement renvoyée par `/ops` et
de laisser des items dépendants non supportés.

## Configuration Zabbix effective

### Template `Metio HTTP — Présence`

- macro d'hôte : `{$HEALTH.URL}` ;
- item HTTP agent : `metio.health.raw` ;
- intervalle : 1 minute ;
- timeout : 10 secondes ;
- code attendu : 200 ;
- header : `Connection: close` ;
- trigger : `nodata(...,3m)=1` ;
- sévérité : Haute ;
- tags : `metio.domain=health`, `metio.signal=liveness`.

Le template est lié aux cinq applications.

### Template `Metio HTTP — Readiness`

- macro d'hôte : `{$READY.URL}` ;
- headers : `X-Monitoring-Token: {$OPS.TOKEN}` et `Connection: close` ;
- item HTTP agent : `metio.ready.raw` ;
- intervalle : 1 minute ;
- timeout : 10 secondes ;
- code attendu : 200 ;
- trigger : `nodata(...,5m)=1` ;
- sévérité : Moyenne ;
- tags : `metio.domain=health`, `metio.signal=readiness`.

Le template est lié à Eviamemo, Npec, Stimergie Image Hub et TransCare. Il ne
doit pas être lié à Eviaway tant que la route `/ready` n'existe pas.

### Template existant `Metio API /ops — JSON générique`

Les règles communes sont :

- état `critical` : Haute, notification immédiate ;
- état `degraded` : Moyenne, notification Slack ;
- `/ops` sans donnée : Haute ;
- détails précis : disponibles lorsque l'application expose les champs utiles
  et que des items dépendants leur sont associés.

Eviamemo conserve sa collecte `/ops` historique tant que la bascule vers le
master item générique n'est pas validée. Ses déclencheurs spécifiques doivent
respecter la même hiérarchie de dépendances.

## Routage des notifications

L'action active `Slack - incidents applications et infrastructures` cible les
groupes `Metio / Applications` ou `Linux servers`, à partir de la sévérité
**Moyenne**. Elle envoie immédiatement le problème et sa récupération à
`slack-notifications` via le type de média Slack.

Le conteneur `zabbix-server` et l'utilisateur `slack-notifications` utilisent
explicitement le fuseau `Europe/Paris`. Ce réglage est nécessaire pour que les
macros temporelles comme `{EVENT.TIME}` soient rendues à l'heure française
dans les notifications, indépendamment du fuseau PHP de l'interface Web.

| Signal | Zabbix | Slack | Délai conseillé |
| --- | --- | --- | --- |
| Présence HTTP perdue | Haute | oui | 3 minutes |
| Readiness perdue | Moyenne | oui | 5 minutes |
| `/ops` dégradé | Moyenne | oui | à la valeur `degraded` |
| `/ops` critique | Haute | oui | immédiat |
| Collecte multi-applications | Information | non | visible dans Zabbix |
| Information ou événement bref | Information/Avertissement | non | visible dans Zabbix |

Chaque incident notifié doit produire :

1. un message de problème ;
2. un message de récupération ;
3. un enregistrement dans **Rapports → Journal des actions**.

Le message doit contenir au minimum l'application, la sévérité, le nom du
déclencheur, la valeur opérationnelle disponible, l'heure et un lien vers le
problème Zabbix. Les notifications de déploiement prévues doivent être évitées
avec une période de maintenance Zabbix.

## Dépendances enregistrées pour réduire le bruit

Ordre des causes, de la plus fondamentale à la plus détaillée :

1. présence HTTP ;
2. readiness ;
3. disponibilité de `/ops` ;
4. composants et métriques extraits de `/ops`.

La configuration enregistre cette chaîne, plus deux dépendances directes vers
les problèmes racine du collecteur. La dépendance directe est volontaire : si
le trigger de présence est lui-même bloqué par le collecteur et reste à `OK`,
les niveaux readiness et `/ops` doivent quand même être bloqués.

## Journaux et supervision Docker reportés

`/ops` ne peut pas expliquer l'arrêt de son propre conteneur puisqu'il ne répond
plus dans ce cas. Une étape ultérieure installera Zabbix Agent 2 sur les hôtes
Docker pour observer les conteneurs, leur healthcheck, leur code de sortie,
leurs redémarrages et les arrêts OOM.

Les logs complets ne doivent pas être envoyés dans Slack. Si leur collecte est
ajoutée ultérieurement, elle sera filtrée, expurgée des secrets, limitée en
taille et accompagnée d'un lien vers la source complète. La supervision Agent 2
et la collecte des logs sont hors du périmètre de la configuration décrite ici.

## Validation avant de déclarer la chaîne opérationnelle

Le 26 août 2026, Zabbix a collecté avec succès des valeurs fraîches, âgées de
moins d'une minute :

- présence : Eviamemo `OK`, Eviaway `{"status":"ok"}`, Npec HTTP 200,
  Stimergie `ok`, TransCare `healthy` ;
- readiness : Eviamemo `{"status":"ready"}`, Npec
  `{"status":"ready",...}`, Stimergie `{"status":"ok"}` et TransCare
  `{"status":"ok"}` ;
- aucun problème ouvert après le rattachement des templates ;
- action Slack active avec une opération de problème et une opération de
  récupération.

Cette vérification prouve la collecte normale et le routage configuré. Aucun
service n'a été volontairement interrompu : le déclenchement réel, le message
Slack d'incident et le message de récupération restent donc à valider lors
d'un test contrôlé.

Pour chaque application :

1. tester l'item de présence et attendre une valeur fraîche ;
2. tester `/ready` avec son header lorsque la route existe ;
3. vérifier le master item `/ops` et ses items dépendants ;
4. confirmer les dépendances des triggers ;
5. provoquer un incident contrôlé ou utiliser un seuil temporaire sûr ;
6. constater le problème dans Zabbix et le message Slack ;
7. restaurer le service et constater la notification de récupération ;
8. vérifier l'entrée correspondante dans le journal des actions.

À 16 h 27 le même jour, plusieurs sondes sont devenues non supportées avec
`Could not resolve host` ou `Could not contact DNS servers`, alors que les
endpoints publics répondaient en HTTP 200 depuis l'extérieur. Les triggers
`nodata` ont produit une cascade présence/readiness. Cet incident est la raison
de l'ajout des résolveurs explicites, de l'hôte collecteur et des dépendances
directes décrites ci-dessus.

Un test du type de média Slack ne remplace pas ce test complet. Enfin, si
Zabbix et toutes les applications sont hébergés sur le même serveur, Zabbix ne
peut pas signaler la panne totale de ce serveur. Un contrôle externe indépendant
sera nécessaire pour couvrir ce scénario.
