#!/bin/sh

set -eu

: "${ZABBIX_ADMIN_PASSWORD:?ZABBIX_ADMIN_PASSWORD is required}"

api_url=${ZABBIX_API_URL:-http://zabbix-web:8080/api_jsonrpc.php}
# Cette version laisse s'exécuter une seule migration de configuration sur les
# instances amorcées avec seeded-v1, sans modifier les objets déjà présents.
state_file=/state/seeded-v2
projects_file=/bootstrap/projects.json
request_id=0

if [ -f "$state_file" ]; then
  echo "Bootstrap Zabbix déjà exécuté."
  exit 0
fi

api_request() {
  method=$1
  params=$2
  token=${3:-}
  request_id=$((request_id + 1))
  payload=$(jq -cn --arg method "$method" --argjson params "$params" --argjson id "$request_id" '{jsonrpc: "2.0", method: $method, params: $params, id: $id}')

  if [ -n "$token" ]; then
    curl --fail --silent --show-error --max-time 10 --header 'Content-Type: application/json-rpc' --header "Authorization: Bearer $token" --data "$payload" "$api_url"
  else
    curl --fail --silent --show-error --max-time 10 --header 'Content-Type: application/json-rpc' --data "$payload" "$api_url"
  fi
}

login() {
  password=$1
  params=$(jq -cn --arg password "$password" '{username: "Admin", password: $password}')
  response=$(api_request user.login "$params" 2>/dev/null) || return 1
  printf '%s' "$response" | jq -er '.result // empty' 2>/dev/null
}

api_is_ready() {
  response=$(api_request apiinfo.version '{}' 2>/dev/null) || return 1
  printf '%s' "$response" | jq -e '.result' >/dev/null 2>&1
}

call() {
  method=$1
  params=$2
  token=$3
  response=$(api_request "$method" "$params" "$token")

  if printf '%s' "$response" | jq -e '.error' >/dev/null; then
    printf '%s\n' "Erreur API Zabbix pendant $method: $(printf '%s' "$response" | jq -r '.error.data // .error.message')" >&2
    return 1
  fi

  printf '%s' "$response" | jq -c '.result'
}

ensure_host_group() {
  group_name=$1
  params=$(jq -cn --arg name "$group_name" '{output: ["groupid"], filter: {name: [$name]}}')
  result=$(call hostgroup.get "$params" "$auth")
  group_id=$(printf '%s' "$result" | jq -r '.[0].groupid // empty')

  if [ -z "$group_id" ]; then
    result=$(call hostgroup.create "$(jq -cn --arg name "$group_name" '{name: $name}')" "$auth")
    group_id=$(printf '%s' "$result" | jq -r '.groupids[0]')
  fi

  printf '%s' "$group_id"
}

ensure_template_group() {
  group_name=$1
  params=$(jq -cn --arg name "$group_name" '{output: ["groupid"], filter: {name: [$name]}}')
  result=$(call templategroup.get "$params" "$auth")
  group_id=$(printf '%s' "$result" | jq -r '.[0].groupid // empty')

  if [ -z "$group_id" ]; then
    result=$(call templategroup.create "$(jq -cn --arg name "$group_name" '{name: $name}')" "$auth")
    group_id=$(printf '%s' "$result" | jq -r '.groupids[0]')
  fi

  printf '%s' "$group_id"
}

ensure_template() {
  params='{"output":["templateid"],"filter":{"host":["metio.ops.generic"]}}'
  result=$(call template.get "$params" "$auth")
  template_id=$(printf '%s' "$result" | jq -r '.[0].templateid // empty')

  if [ -z "$template_id" ]; then
    params=$(jq -cn --arg group_id "$template_group_id" '{
      host: "metio.ops.generic",
      name: "Metio API /ops — JSON générique",
      description: "Point de départ pour tout endpoint opérationnel JSON à structure variable.",
      readme: "Renseigner {$OPS.URL} et le secret {$OPS.TOKEN}, tester la réponse JSON, puis activer les contrôles propres à chaque application. Le format JSON est volontairement libre.",
      wizard_ready: 1,
      groups: [{groupid: $group_id}],
      macros: [
        {macro: "{$OPS.URL}", value: ""},
        {macro: "{$OPS.TOKEN}", value: "", type: 1}
      ]
    }')
    result=$(call template.create "$params" "$auth")
    template_id=$(printf '%s' "$result" | jq -r '.templateids[0]')
  fi

  item_params=$(jq -cn --arg template_id "$template_id" '{output: ["itemid"], hostids: [$template_id], filter: {key_: ["metio.ops.raw"]}}')
  result=$(call item.get "$item_params" "$auth")
  item_id=$(printf '%s' "$result" | jq -r '.[0].itemid // empty')

  if [ -z "$item_id" ]; then
    params=$(jq -cn --arg template_id "$template_id" '{
      hostid: $template_id,
      name: "/ops: réponse JSON",
      key_: "metio.ops.raw",
      type: 19,
      value_type: 4,
      delay: "1m",
      url: "{$OPS.URL}",
      request_method: 0,
      timeout: "10s",
      status_codes: "200-299",
      follow_redirects: 1,
      retrieve_mode: 0,
      headers: [{name: "X-Monitoring-Token", value: "{$OPS.TOKEN}"}],
      status: 1,
      tags: [
        {tag: "metio.domain", value: "source"},
        {tag: "metio.signal", value: "snapshot"}
      ],
      description: "Réponse brute. Désactivée par défaut pour éviter toute requête vers une URL de démonstration ; l’activer après le test de l’endpoint. Ajouter ensuite des items dépendants pour les champs JSON utiles."
    }')
    result=$(call item.create "$params" "$auth")
    item_id=$(printf '%s' "$result" | jq -r '.itemids[0]')
  fi

  trigger_params='{"output":["triggerid"],"filter":{"description":["Endpoint /ops indisponible sur {HOST.NAME}"]}}'
  result=$(call trigger.get "$trigger_params" "$auth")
  trigger_id=$(printf '%s' "$result" | jq -r '.[0].triggerid // empty')

  if [ -z "$trigger_id" ]; then
    params='{"description":"Endpoint /ops indisponible sur {HOST.NAME}","expression":"nodata(/metio.ops.generic/metio.ops.raw,5m)=1","priority":4,"status":1,"manual_close":1,"tags":[{"tag":"metio.domain","value":"health"},{"tag":"metio.signal","value":"endpoint"}]}'
    call trigger.create "$params" "$auth" >/dev/null
  fi

  printf '%s' "$template_id"
}

get_item_id() {
  host_id=$1
  item_key=$2
  params=$(jq -cn --arg host_id "$host_id" --arg item_key "$item_key" '{output: ["itemid"], hostids: [$host_id], filter: {key_: [$item_key]}}')
  result=$(call item.get "$params" "$auth")
  printf '%s' "$result" | jq -r '.[0].itemid // empty'
}

ensure_status_value_map() {
  template_id=$1
  value_map_name='Metio / état opérationnel'
  result=$(call valuemap.get '{"output":["valuemapid","hostid","name"]}' "$auth")
  value_map_id=$(printf '%s' "$result" | jq -r --arg template_id "$template_id" --arg value_map_name "$value_map_name" '.[] | select(.hostid == $template_id and .name == $value_map_name) | .valuemapid' | head -n 1)

  if [ -z "$value_map_id" ]; then
    params=$(jq -cn --arg template_id "$template_id" --arg value_map_name "$value_map_name" '{
      hostid: $template_id,
      name: $value_map_name,
      mappings: [
        {type: 0, value: "0", newvalue: "OK"},
        {type: 0, value: "1", newvalue: "Dégradé"},
        {type: 0, value: "2", newvalue: "Critique"},
        {type: 0, value: "3", newvalue: "Inconnu"}
      ]
    }')
    result=$(call valuemap.create "$params" "$auth")
    value_map_id=$(printf '%s' "$result" | jq -r '.valuemapids[0]')
  fi

  printf '%s' "$value_map_id"
}

ensure_ops_status_item() {
  template_id=$1
  master_item_id=$2
  value_map_id=$3
  item_id=$(get_item_id "$template_id" 'metio.ops.status.code')

  if [ -z "$item_id" ]; then
    params=$(jq -cn --arg template_id "$template_id" --arg master_item_id "$master_item_id" --arg value_map_id "$value_map_id" '{
      hostid: $template_id,
      name: "/ops: état",
      key_: "metio.ops.status.code",
      type: 18,
      master_itemid: $master_item_id,
      value_type: 3,
      valuemapid: $value_map_id,
      preprocessing: [
        {type: 12, params: "$.status", error_handler: 1},
        {
          type: 21,
          params: "var status = value.trim().toLowerCase();\nif (status === \"ok\") return 0;\nif (status === \"degraded\") return 1;\nif (status === \"critical\") return 2;\nreturn 3;",
          error_handler: 0
        }
      ],
      tags: [
        {tag: "metio.domain", value: "health"},
        {tag: "metio.signal", value: "status"}
      ],
      description: "État normalisé de $.status. Les réponses sans status sont ignorées pour conserver la compatibilité avec les endpoints JSON libres."
    }')
    result=$(call item.create "$params" "$auth")
    item_id=$(printf '%s' "$result" | jq -r '.itemids[0]')
  fi

  printf '%s' "$item_id"
}

ensure_ops_text_item() {
  template_id=$1
  master_item_id=$2
  item_name=$3
  item_key=$4
  jsonpath=$5
  domain=$6
  signal=$7
  item_id=$(get_item_id "$template_id" "$item_key")

  if [ -z "$item_id" ]; then
    params=$(jq -cn --arg template_id "$template_id" --arg master_item_id "$master_item_id" --arg item_name "$item_name" --arg item_key "$item_key" --arg jsonpath "$jsonpath" --arg domain "$domain" --arg signal "$signal" '{
      hostid: $template_id,
      name: $item_name,
      key_: $item_key,
      type: 18,
      master_itemid: $master_item_id,
      value_type: 4,
      preprocessing: [{type: 12, params: $jsonpath, error_handler: 1}],
      tags: [
        {tag: "metio.domain", value: $domain},
        {tag: "metio.signal", value: $signal}
      ]
    }')
    result=$(call item.create "$params" "$auth")
    item_id=$(printf '%s' "$result" | jq -r '.itemids[0]')
  fi

  printf '%s' "$item_id"
}

ensure_ops_trigger() {
  description=$1
  expression=$2
  priority=$3
  signal=$4
  status=$5
  params=$(jq -cn --arg description "$description" '{output: ["triggerid"], filter: {description: [$description]}}')
  result=$(call trigger.get "$params" "$auth")
  trigger_id=$(printf '%s' "$result" | jq -r '.[0].triggerid // empty')

  if [ -z "$trigger_id" ]; then
    params=$(jq -cn --arg description "$description" --arg expression "$expression" --argjson priority "$priority" --arg signal "$signal" --arg status "$status" '{
      description: $description,
      expression: $expression,
      priority: $priority,
      status: 1,
      manual_close: 1,
      opdata: $status,
      tags: [
        {tag: "metio.domain", value: "health"},
        {tag: "metio.signal", value: $signal}
      ]
    }')
    call trigger.create "$params" "$auth" >/dev/null
  fi
}

ensure_template_dashboard() {
  template_id=$1
  raw_item_id=$2
  status_item_id=$3
  release_item_id=$4
  generated_at_item_id=$5
  dashboard_name='Santé de l’application'
  params=$(jq -cn --arg template_id "$template_id" --arg dashboard_name "$dashboard_name" '{output: ["dashboardid"], templateids: [$template_id], filter: {name: [$dashboard_name]}}')
  result=$(call templatedashboard.get "$params" "$auth")
  dashboard_id=$(printf '%s' "$result" | jq -r '.[0].dashboardid // empty')

  if [ -n "$dashboard_id" ]; then
    return
  fi

  params=$(jq -cn --arg template_id "$template_id" --arg raw_item_id "$raw_item_id" --arg status_item_id "$status_item_id" --arg release_item_id "$release_item_id" --arg generated_at_item_id "$generated_at_item_id" --arg dashboard_name "$dashboard_name" '{
    templateid: $template_id,
    name: $dashboard_name,
    display_period: 60,
    auto_start: 0,
    pages: [
      {
        name: "Santé",
        widgets: [
          {
            type: "item", name: "État opérationnel", x: 0, y: 0, width: 24, height: 6, view_mode: 0,
            fields: [
              {type: 4, name: "itemid.0", value: $status_item_id},
              {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3},
              {type: 1, name: "thresholds.0.color", value: "00A65A"}, {type: 1, name: "thresholds.0.threshold", value: "0"},
              {type: 1, name: "thresholds.1.color", value: "F39C12"}, {type: 1, name: "thresholds.1.threshold", value: "1"},
              {type: 1, name: "thresholds.2.color", value: "DD4B39"}, {type: 1, name: "thresholds.2.threshold", value: "2"},
              {type: 1, name: "thresholds.3.color", value: "78909C"}, {type: 1, name: "thresholds.3.threshold", value: "3"}
            ]
          },
          {
            type: "item", name: "Version déployée", x: 24, y: 0, width: 24, height: 6, view_mode: 0,
            fields: [
              {type: 4, name: "itemid.0", value: $release_item_id},
              {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}
            ]
          },
          {
            type: "item", name: "Snapshot déclaré", x: 48, y: 0, width: 24, height: 6, view_mode: 0,
            fields: [
              {type: 4, name: "itemid.0", value: $generated_at_item_id},
              {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}
            ]
          },
          {
            type: "problems", name: "Incidents ouverts", x: 0, y: 6, width: 72, height: 12, view_mode: 0,
            fields: [
              {type: 0, name: "show", value: 3}, {type: 0, name: "show_tags", value: 2},
              {type: 1, name: "tag_priority", value: "metio.signal,metio.domain"},
              {type: 0, name: "show_timeline", value: 0}, {type: 0, name: "highlight_row", value: 1},
              {type: 0, name: "show_lines", value: 10}, {type: 1, name: "reference", value: "PRB01"}
            ]
          }
        ]
      },
      {
        name: "Données",
        widgets: [
          {
            type: "itemnavigator", name: "Indicateurs collectés", x: 0, y: 0, width: 24, height: 18, view_mode: 0,
            fields: [
              {type: 0, name: "group_by.0.attribute", value: 3}, {type: 1, name: "group_by.0.tag_name", value: "metio.domain"},
              {type: 0, name: "show_lines", value: 1000}, {type: 1, name: "reference", value: "DATA1"}
            ]
          },
          {
            type: "itemhistory", name: "Derniers snapshots /ops", x: 24, y: 0, width: 48, height: 18, view_mode: 0,
            fields: [
              {type: 0, name: "layout", value: 1}, {type: 1, name: "columns.0.name", value: "Réponse JSON /ops"},
              {type: 4, name: "columns.0.itemid", value: $raw_item_id}, {type: 0, name: "show_lines", value: 5},
              {type: 0, name: "show_timestamp", value: 1}, {type: 0, name: "show_column_header", value: 1},
              {type: 1, name: "reference", value: "RAW01"}
            ]
          }
        ]
      }
    ]
  }')
  call templatedashboard.create "$params" "$auth" >/dev/null
}

ensure_global_dashboard() {
  applications_group_id=$1
  dashboard_name='Métio — Tour de contrôle'
  params=$(jq -cn --arg dashboard_name "$dashboard_name" '{output: ["dashboardid"], filter: {name: [$dashboard_name]}}')
  result=$(call dashboard.get "$params" "$auth")
  dashboard_id=$(printf '%s' "$result" | jq -r '.[0].dashboardid // empty')

  if [ -n "$dashboard_id" ]; then
    return
  fi

  params=$(jq -cn --arg applications_group_id "$applications_group_id" --arg dashboard_name "$dashboard_name" '{
    name: $dashboard_name,
    display_period: 60,
    auto_start: 0,
    pages: [
      {
        name: "Vue d’ensemble",
        widgets: [
          {
            type: "honeycomb", name: "État des applications", x: 0, y: 0, width: 36, height: 12, view_mode: 0,
            fields: [
              {type: 2, name: "groupids.0", value: $applications_group_id}, {type: 1, name: "items.0", value: "/ops: état"},
              {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2},
              {type: 0, name: "interpolation", value: 0},
              {type: 1, name: "thresholds.0.color", value: "00A65A"}, {type: 1, name: "thresholds.0.threshold", value: "0"},
              {type: 1, name: "thresholds.1.color", value: "F39C12"}, {type: 1, name: "thresholds.1.threshold", value: "1"},
              {type: 1, name: "thresholds.2.color", value: "DD4B39"}, {type: 1, name: "thresholds.2.threshold", value: "2"},
              {type: 1, name: "thresholds.3.color", value: "78909C"}, {type: 1, name: "thresholds.3.threshold", value: "3"},
              {type: 1, name: "reference", value: "APPS1"}
            ]
          },
          {
            type: "problemsbysv", name: "Incidents par gravité", x: 36, y: 0, width: 36, height: 4, view_mode: 0,
            fields: [
              {type: 2, name: "groupids.0", value: $applications_group_id}, {type: 0, name: "show_type", value: 1},
              {type: 0, name: "layout", value: 0}, {type: 1, name: "reference", value: "SEV01"}
            ]
          },
          {
            type: "problems", name: "Incidents à traiter", x: 36, y: 4, width: 36, height: 8, view_mode: 0,
            fields: [
              {type: 0, name: "show", value: 3}, {type: 2, name: "groupids.0", value: $applications_group_id},
              {type: 0, name: "show_tags", value: 2}, {type: 1, name: "tag_priority", value: "metio.signal,metio.domain"},
              {type: 0, name: "show_timeline", value: 0}, {type: 0, name: "highlight_row", value: 1},
              {type: 0, name: "show_lines", value: 12}, {type: 1, name: "reference", value: "PRB02"}
            ]
          }
        ]
      }
    ]
  }')
  call dashboard.create "$params" "$auth" >/dev/null
}

ensure_application_host() {
  project_id=$1
  project_name=$2
  technical_name="metio-app-$project_id"
  params=$(jq -cn --arg host "$technical_name" '{output: ["hostid"], filter: {host: [$host]}}')
  result=$(call host.get "$params" "$auth")
  host_id=$(printf '%s' "$result" | jq -r '.[0].hostid // empty')

  if [ -z "$host_id" ]; then
    params=$(jq -cn --arg host "$technical_name" --arg name "$project_name" --arg group_id "$applications_group_id" --arg template_id "$template_id" --arg project_id "$project_id" '{
      host: $host,
      name: $name,
      status: 1,
      groups: [{groupid: $group_id}],
      templates: [{templateid: $template_id}],
      tags: [{tag: "metio.project", value: $project_id}, {tag: "metio.kind", value: "application"}],
      macros: [{macro: "{$OPS.URL}", value: ""}, {macro: "{$OPS.TOKEN}", value: "", type: 1}],
      description: "Précréé par Monitoring. Désactivé tant que le endpoint et ses règles ne sont pas configurés dans Zabbix."
    }')
    call host.create "$params" "$auth" >/dev/null
  fi
}

echo "Attente de l'API Zabbix…"
bootstrap_deadline=$(( $(date +%s) + 180 ))
auth=''
admin_id=''
password_is_default=0
api_reachable=0
admin_lookup_failed=0
while [ "$(date +%s)" -lt "$bootstrap_deadline" ]; do
  if api_is_ready; then
    api_reachable=1
    auth=$(login zabbix || true)
    if [ -n "$auth" ]; then
      password_is_default=1
    else
      auth=$(login "$ZABBIX_ADMIN_PASSWORD" || true)
    fi

    if [ -n "$auth" ]; then
      admin_result=$(call user.get '{"output":["userid"],"filter":{"username":["Admin"]}}' "$auth" 2>/dev/null || true)
      admin_id=$(printf '%s' "$admin_result" | jq -r '.[0].userid // empty' 2>/dev/null || true)
      if [ -n "$admin_id" ]; then
        break
      fi
      admin_lookup_failed=1
      auth=''
      password_is_default=0
    fi
  fi

  sleep 2
done

if [ -z "$auth" ] || [ -z "$admin_id" ]; then
  if [ "$api_reachable" -eq 0 ]; then
    echo "L’API Zabbix est restée inaccessible après 3 minutes. Vérifier les logs zabbix-web et zabbix-server, ainsi que leur connexion PostgreSQL." >&2
  elif [ "$admin_lookup_failed" -eq 1 ]; then
    echo "L’API Zabbix accepte la connexion Admin, mais la configuration utilisateur est illisible. Vérifier les permissions du compte Admin et les logs de l’API Zabbix." >&2
  else
    echo "L’API Zabbix répond, mais le mot de passe Admin est refusé. Pour une instance existante, ZABBIX_ADMIN_PASSWORD dans Dokploy doit correspondre au mot de passe actuel du compte Admin ; ne pas le publier dans les logs." >&2
  fi
  exit 1
fi

if [ "$password_is_default" -eq 1 ]; then
  change_password=$(jq -cn --arg admin_id "$admin_id" --arg password "$ZABBIX_ADMIN_PASSWORD" '{userid: $admin_id, passwd: $password, current_passwd: "zabbix"}')
  call user.update "$change_password" "$auth" >/dev/null
  auth=$(login "$ZABBIX_ADMIN_PASSWORD")
fi

applications_group_id=$(ensure_host_group 'Metio / Applications')
template_group_id=$(ensure_template_group 'Metio / Endpoints')
template_id=$(ensure_template)
raw_item_id=$(get_item_id "$template_id" 'metio.ops.raw')
status_value_map_id=$(ensure_status_value_map "$template_id")
status_item_id=$(ensure_ops_status_item "$template_id" "$raw_item_id" "$status_value_map_id")
release_item_id=$(ensure_ops_text_item "$template_id" "$raw_item_id" 'Version déployée' 'metio.ops.release.version' '$.release.version' 'health' 'release')
generated_at_item_id=$(ensure_ops_text_item "$template_id" "$raw_item_id" 'Snapshot /ops généré le' 'metio.ops.generated_at' '$.generated_at' 'health' 'snapshot_time')
ensure_ops_trigger 'Application dégradée sur {HOST.NAME}' 'last(/metio.ops.generic/metio.ops.status.code)=1' 2 'status' 'État déclaré : {ITEM.LASTVALUE}'
ensure_ops_trigger 'Application critique sur {HOST.NAME}' 'last(/metio.ops.generic/metio.ops.status.code)=2' 4 'status' 'État déclaré : {ITEM.LASTVALUE}'
ensure_template_dashboard "$template_id" "$raw_item_id" "$status_item_id" "$release_item_id" "$generated_at_item_id"
ensure_global_dashboard "$applications_group_id"

jq -r '.projects[] | [.id, .name] | join("|")' "$projects_file" | while IFS='|' read -r project_id project_name; do
  ensure_application_host "$project_id" "$project_name"
done

umask 077
touch "$state_file"
echo "Bootstrap Zabbix terminé : cinq applications précréées, la tour de contrôle et le dashboard de santé sont disponibles."
