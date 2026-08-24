# Ajouter un serveur

L'interface Zabbix reste unique, mais chaque serveur surveillé exécute un agent léger. Préférer **Zabbix Agent 2 en checks actifs** : le serveur surveillé initie la connexion vers le port TCP `10051` du hub, il n'est donc pas nécessaire d'ouvrir un port entrant sur chaque machine.

## Parcours dans l'interface

1. Dans **Data collection → Hosts**, lancer **Host Wizard**.
2. Choisir le template `Linux by Zabbix agent active`.
3. Nommer le serveur avec le même `Hostname` que dans son agent.
4. Choisir TLS PSK, générer une identité et une clé propres à ce serveur.
5. Vérifier les premières valeurs avant de mettre des seuils plus restrictifs.

Le template Linux collecte CPU, mémoire, systèmes de fichiers, réseau et disponibilité. Les alertes sont ensuite créées dans **Data collection → Triggers** et leurs destinations dans **Alerts → Actions**.

## Configuration minimale de l'agent

Les valeurs ci-dessous sont des exemples à adapter au nom du hub et à une PSK unique. Elles ne doivent pas être ajoutées au dépôt Monitoring.

```ini
ServerActive=monitoring.example.net:10051
Hostname=nom-du-serveur
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=nom-du-serveur
TLSPSKFile=/etc/zabbix/agent.psk
```

Le pare-feu du hub doit autoriser le port `10051/TCP` depuis les serveurs réellement administrés. Aucun autre port Zabbix n'a besoin d'être exposé publiquement pour le mode actif.
