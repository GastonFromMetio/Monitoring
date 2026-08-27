#!/bin/sh

set -eu

: "${ZABBIX_ADMIN_PASSWORD:?ZABBIX_ADMIN_PASSWORD is required}"

api_url=${ZABBIX_API_URL:-http://zabbix-web:8080/api_jsonrpc.php}
# Cette version laisse s'exécuter une seule migration de configuration. La
# présence d'un marqueur antérieur permet de préserver les objets supprimés
# volontairement dans l'interface, en particulier l'ancien dashboard global.
state_file=/state/seeded-v6
upgrade_existing=0
for previous_state_file in /state/seeded-v4 /state/seeded-v5; do
  [ -f "$previous_state_file" ] && upgrade_existing=1
done
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

get_host_id() {
  technical_name=$1
  params=$(jq -cn --arg host "$technical_name" '{output: ["hostid"], filter: {host: [$host]}}')
  result=$(call host.get "$params" "$auth")
  printf '%s' "$result" | jq -r '.[0].hostid // empty'
}

get_template_id() {
  technical_name=$1
  params=$(jq -cn --arg host "$technical_name" '{output: ["templateid"], filter: {host: [$host]}}')
  result=$(call template.get "$params" "$auth")
  printf '%s' "$result" | jq -r '.[0].templateid // empty'
}

get_template_trigger_id() {
  template_id=$1
  description=$2
  params=$(jq -cn --arg template_id "$template_id" --arg description "$description" '{output: ["triggerid"], hostids: [$template_id], filter: {description: [$description]}}')
  result=$(call trigger.get "$params" "$auth")
  printf '%s' "$result" | jq -r '.[0].triggerid // empty'
}

ensure_host_macro() {
  host_id=$1
  macro_name=$2
  macro_value=$3
  params=$(jq -cn --arg host_id "$host_id" --arg macro "$macro_name" '{output: ["hostmacroid"], hostids: [$host_id], filter: {macro: [$macro]}}')
  result=$(call usermacro.get "$params" "$auth")
  macro_id=$(printf '%s' "$result" | jq -r '.[0].hostmacroid // empty')

  if [ -z "$macro_id" ]; then
    params=$(jq -cn --arg host_id "$host_id" --arg macro "$macro_name" --arg value "$macro_value" '{hostid: $host_id, macro: $macro, value: $value, type: 0}')
    call usermacro.create "$params" "$auth" >/dev/null
  else
    params=$(jq -cn --arg hostmacroid "$macro_id" --arg value "$macro_value" '{hostmacroid: $hostmacroid, value: $value}')
    call usermacro.update "$params" "$auth" >/dev/null
  fi
}

ensure_liveness_template() {
  template_id=$(get_template_id 'metio.http.liveness')
  description='Contrôle HTTP public et léger confirmant que l’application répond. Configurer {$HEALTH.URL} sur chaque hôte avant de lier ce modèle.'

  if [ -z "$template_id" ]; then
    params=$(jq -cn --arg group_id "$template_group_id" --arg description "$description" '{
      host: "metio.http.liveness",
      name: "Metio HTTP — Présence",
      description: $description,
      groups: [{groupid: $group_id}],
      macros: [{macro: "{$HEALTH.URL}", value: ""}]
    }')
    result=$(call template.create "$params" "$auth")
    template_id=$(printf '%s' "$result" | jq -r '.templateids[0]')
  else
    params=$(jq -cn --arg template_id "$template_id" --arg description "$description" '{templateid: $template_id, name: "Metio HTTP — Présence", description: $description}')
    call template.update "$params" "$auth" >/dev/null
  fi

  item_id=$(get_item_id "$template_id" 'metio.health.raw')
  if [ -z "$item_id" ]; then
    params=$(jq -cn --arg template_id "$template_id" '{
      hostid: $template_id,
      name: "Présence HTTP : réponse",
      key_: "metio.health.raw",
      type: 19,
      value_type: 4,
      delay: "1m",
      url: "{$HEALTH.URL}",
      request_method: 0,
      timeout: "10s",
      status_codes: "200",
      follow_redirects: 1,
      retrieve_mode: 0,
      status: 0,
      tags: [
        {tag: "metio.domain", value: "health"},
        {tag: "metio.signal", value: "liveness"}
      ],
      description: "Réponse brute de l’endpoint public de présence. Une valeur fraîche confirme que l’application répond en HTTP 200."
    }')
    call item.create "$params" "$auth" >/dev/null
  fi

  trigger_id=$(get_template_trigger_id "$template_id" 'Application inaccessible sur {HOST.NAME}')
  trigger_params=$(jq -cn --arg template_id "$template_id" '{
    description: "Application inaccessible sur {HOST.NAME}",
    expression: "nodata(/metio.http.liveness/metio.health.raw,3m)=1",
    priority: 4,
    status: 0,
    manual_close: 1,
    comments: "Le contrôle public de présence n’a fourni aucune valeur valide depuis 3 minutes. Vérifier d’abord le collecteur HTTP/DNS, puis l’application, son routage et son endpoint de présence.",
    opdata: "Aucune réponse HTTP 200 depuis 3 minutes.",
    tags: [
      {tag: "metio.domain", value: "health"},
      {tag: "metio.signal", value: "liveness"}
    ]
  }')
  if [ -z "$trigger_id" ]; then
    call trigger.create "$trigger_params" "$auth" >/dev/null
  else
    params=$(printf '%s' "$trigger_params" | jq -c --arg trigger_id "$trigger_id" '. + {triggerid: $trigger_id}')
    call trigger.update "$params" "$auth" >/dev/null
  fi

  printf '%s' "$template_id"
}

ensure_readiness_template() {
  template_id=$(get_template_id 'metio.http.readiness')
  description='Contrôle HTTP confirmant que l’application peut servir. Configurer {$READY.URL} et {$OPS.TOKEN} avant de lier ce modèle.'

  if [ -z "$template_id" ]; then
    params=$(jq -cn --arg group_id "$template_group_id" --arg description "$description" '{
      host: "metio.http.readiness",
      name: "Metio HTTP — Readiness",
      description: $description,
      groups: [{groupid: $group_id}],
      macros: [{macro: "{$READY.URL}", value: ""}]
    }')
    result=$(call template.create "$params" "$auth")
    template_id=$(printf '%s' "$result" | jq -r '.templateids[0]')
  else
    params=$(jq -cn --arg template_id "$template_id" --arg description "$description" '{templateid: $template_id, name: "Metio HTTP — Readiness", description: $description}')
    call template.update "$params" "$auth" >/dev/null
  fi

  item_id=$(get_item_id "$template_id" 'metio.ready.raw')
  if [ -z "$item_id" ]; then
    params=$(jq -cn --arg template_id "$template_id" '{
      hostid: $template_id,
      name: "Readiness HTTP : réponse",
      key_: "metio.ready.raw",
      type: 19,
      value_type: 4,
      delay: "1m",
      url: "{$READY.URL}",
      request_method: 0,
      timeout: "10s",
      status_codes: "200",
      follow_redirects: 1,
      retrieve_mode: 0,
      headers: [{name: "X-Monitoring-Token", value: "{$OPS.TOKEN}"}],
      status: 0,
      tags: [
        {tag: "metio.domain", value: "health"},
        {tag: "metio.signal", value: "readiness"}
      ],
      description: "Réponse brute de l’endpoint readiness. Une valeur fraîche confirme que les dépendances indispensables sont prêtes."
    }')
    call item.create "$params" "$auth" >/dev/null
  fi

  trigger_id=$(get_template_trigger_id "$template_id" 'Application non prête sur {HOST.NAME}')
  trigger_params=$(jq -cn '{
    description: "Application non prête sur {HOST.NAME}",
    expression: "nodata(/metio.http.readiness/metio.ready.raw,5m)=1",
    priority: 3,
    status: 0,
    manual_close: 1,
    comments: "Le contrôle readiness n’a fourni aucune valeur valide depuis 5 minutes. Vérifier d’abord le collecteur HTTP/DNS, puis la présence HTTP et les dépendances applicatives.",
    opdata: "Aucune réponse readiness HTTP 200 depuis 5 minutes.",
    tags: [
      {tag: "metio.domain", value: "health"},
      {tag: "metio.signal", value: "readiness"}
    ]
  }')
  if [ -z "$trigger_id" ]; then
    call trigger.create "$trigger_params" "$auth" >/dev/null
  else
    params=$(printf '%s' "$trigger_params" | jq -c --arg trigger_id "$trigger_id" '. + {triggerid: $trigger_id}')
    call trigger.update "$params" "$auth" >/dev/null
  fi

  printf '%s' "$template_id"
}

ensure_collector_host() {
  host_id=$(get_host_id 'metio-monitoring-collector')
  if [ -z "$host_id" ]; then
    params=$(jq -cn --arg group_id "$applications_group_id" '{
      host: "metio-monitoring-collector",
      name: "Metio Monitoring — Collecteur HTTP",
      status: 0,
      groups: [{groupid: $group_id}],
      tags: [
        {tag: "metio.project", value: "monitoring"},
        {tag: "metio.kind", value: "collector"}
      ],
      description: "Contrôle la sortie HTTP et la résolution DNS du serveur Zabbix. Les alertes applicatives en dépendent pour éviter les faux positifs de collecte."
    }')
    result=$(call host.create "$params" "$auth")
    host_id=$(printf '%s' "$result" | jq -r '.hostids[0]')
  fi
  printf '%s' "$host_id"
}

ensure_collector_http_item() {
  host_id=$1
  item_name=$2
  item_key=$3
  item_url=$4
  status_codes=$5
  item_description=$6
  item_id=$(get_item_id "$host_id" "$item_key")
  item_params=$(jq -cn --arg name "$item_name" --arg key "$item_key" --arg url "$item_url" --arg status_codes "$status_codes" --arg description "$item_description" '{
    name: $name,
    key_: $key,
    type: 19,
    value_type: 4,
    delay: "30s",
    url: $url,
    request_method: 0,
    timeout: "5s",
    status_codes: $status_codes,
    follow_redirects: 1,
    retrieve_mode: 0,
    status: 0,
    tags: [
      {tag: "metio.domain", value: "monitoring"},
      {tag: "metio.signal", value: "collector"}
    ],
    description: $description
  }')

  if [ -z "$item_id" ]; then
    params=$(printf '%s' "$item_params" | jq -c --arg host_id "$host_id" '. + {hostid: $host_id}')
    result=$(call item.create "$params" "$auth")
    item_id=$(printf '%s' "$result" | jq -r '.itemids[0]')
  else
    params=$(printf '%s' "$item_params" | jq -c --arg item_id "$item_id" '. + {itemid: $item_id}')
    call item.update "$params" "$auth" >/dev/null
  fi

  printf '%s' "$item_id"
}

ensure_collector_trigger() {
  host_id=$1
  description=$2
  expression=$3
  priority=$4
  signal=$5
  opdata=$6
  trigger_id=$(get_template_trigger_id "$host_id" "$description")
  trigger_params=$(jq -cn --arg description "$description" --arg expression "$expression" --argjson priority "$priority" --arg signal "$signal" --arg opdata "$opdata" '{
    description: $description,
    expression: $expression,
    priority: $priority,
    status: 0,
    manual_close: 1,
    comments: "Incident de collecte Zabbix. Les alertes applicatives HTTP, readiness et /ops dépendent de ce signal.",
    opdata: $opdata,
    tags: [
      {tag: "metio.domain", value: "monitoring"},
      {tag: "metio.signal", value: $signal}
    ]
  }')
  if [ -z "$trigger_id" ]; then
    result=$(call trigger.create "$trigger_params" "$auth")
    trigger_id=$(printf '%s' "$result" | jq -r '.triggerids[0]')
  else
    params=$(printf '%s' "$trigger_params" | jq -c --arg trigger_id "$trigger_id" '. + {triggerid: $trigger_id}')
    call trigger.update "$params" "$auth" >/dev/null
  fi
  printf '%s' "$trigger_id"
}

ensure_trigger_dependencies() {
  trigger_id=$1
  shift
  dependencies='[]'
  for dependency_id in "$@"; do
    dependencies=$(printf '%s' "$dependencies" | jq -c --arg triggerid "$dependency_id" '. + [{triggerid: $triggerid}]')
  done
  params=$(jq -cn --arg trigger_id "$trigger_id" --argjson dependencies "$dependencies" '{triggerid: $trigger_id, dependencies: $dependencies}')
  call trigger.update "$params" "$auth" >/dev/null
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

ensure_host_dependent_item() {
  host_id=$1
  master_item_id=$2
  item_name=$3
  item_key=$4
  value_type=$5
  units=$6
  jsonpath=$7
  domain=$8
  signal=$9
  description=${10}
  item_id=$(get_item_id "$host_id" "$item_key")

  if [ -z "$item_id" ]; then
    params=$(jq -cn --arg host_id "$host_id" --arg master_item_id "$master_item_id" --arg item_name "$item_name" --arg item_key "$item_key" --arg units "$units" --arg jsonpath "$jsonpath" --arg domain "$domain" --arg signal "$signal" --arg description "$description" --argjson value_type "$value_type" '{
      hostid: $host_id,
      name: $item_name,
      key_: $item_key,
      type: 18,
      master_itemid: $master_item_id,
      value_type: $value_type,
      units: $units,
      status: 0,
      preprocessing: [{type: 12, params: $jsonpath, error_handler: 1}],
      tags: [
        {tag: "metio.domain", value: $domain},
        {tag: "metio.signal", value: $signal}
      ],
      description: $description
    }')
    result=$(call item.create "$params" "$auth")
    item_id=$(printf '%s' "$result" | jq -r '.itemids[0]')
  fi

  printf '%s' "$item_id"
}

ensure_host_trigger() {
  description=$1
  expression=$2
  priority=$3
  domain=$4
  signal=$5
  opdata=$6
  params=$(jq -cn --arg description "$description" '{output: ["triggerid"], filter: {description: [$description]}}')
  result=$(call trigger.get "$params" "$auth")
  trigger_id=$(printf '%s' "$result" | jq -r '.[0].triggerid // empty')

  if [ -z "$trigger_id" ]; then
    params=$(jq -cn --arg description "$description" --arg expression "$expression" --argjson priority "$priority" --arg domain "$domain" --arg signal "$signal" --arg opdata "$opdata" '{
      description: $description,
      expression: $expression,
      priority: $priority,
      status: 1,
      manual_close: 1,
      opdata: $opdata,
      tags: [
        {tag: "metio.domain", value: $domain},
        {tag: "metio.signal", value: $signal}
      ]
    }')
    call trigger.create "$params" "$auth" >/dev/null
  fi
}

ensure_eviamemo_dashboard() {
  host_id=$1
  status_item_id=$2
  release_item_id=$3
  snapshot_item_id=$4
  raw_item_id=$5
  database_item_id=$6
  cache_item_id=$7
  workers_item_id=$8
  queue_depth_item_id=$9
  queue_oldest_item_id=${10}
  heartbeat_item_id=${11}
  critical_alerts_item_id=${12}
  warning_alerts_item_id=${13}
  llm_errors_item_id=${14}
  generation_failed_item_id=${15}
  analysis_errors_item_id=${16}
  dashboard_name='Eviamemo — Exploitation'
  params=$(jq -cn --arg dashboard_name "$dashboard_name" '{output: ["dashboardid"], filter: {name: [$dashboard_name]}}')
  result=$(call dashboard.get "$params" "$auth")
  dashboard_id=$(printf '%s' "$result" | jq -r '.[0].dashboardid // empty')

  if [ -n "$dashboard_id" ]; then
    return
  fi

  params=$(jq -cn --arg dashboard_name "$dashboard_name" --arg host_id "$host_id" --arg status_item_id "$status_item_id" --arg release_item_id "$release_item_id" --arg snapshot_item_id "$snapshot_item_id" --arg raw_item_id "$raw_item_id" --arg database_item_id "$database_item_id" --arg cache_item_id "$cache_item_id" --arg workers_item_id "$workers_item_id" --arg queue_depth_item_id "$queue_depth_item_id" --arg queue_oldest_item_id "$queue_oldest_item_id" --arg heartbeat_item_id "$heartbeat_item_id" --arg critical_alerts_item_id "$critical_alerts_item_id" --arg warning_alerts_item_id "$warning_alerts_item_id" --arg llm_errors_item_id "$llm_errors_item_id" --arg generation_failed_item_id "$generation_failed_item_id" --arg analysis_errors_item_id "$analysis_errors_item_id" '{
    name: $dashboard_name,
    display_period: 60,
    auto_start: 0,
    pages: [
      {
        name: "Exploitation",
        widgets: [
          {
            type: "item", name: "État global", x: 0, y: 0, width: 18, height: 6, view_mode: 0,
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
            type: "item", name: "PostgreSQL", x: 18, y: 0, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $database_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Redis", x: 36, y: 0, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $cache_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Workers", x: 54, y: 0, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $workers_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Queue par défaut", x: 0, y: 6, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $queue_depth_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Plus ancien job prêt", x: 18, y: 6, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $queue_oldest_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Heartbeat worker", x: 36, y: 6, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $heartbeat_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Version déployée", x: 54, y: 6, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $release_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "problems", name: "Incidents ouverts", x: 0, y: 12, width: 72, height: 12, view_mode: 0,
            fields: [
              {type: 3, name: "hostids.0", value: $host_id}, {type: 0, name: "show", value: 3}, {type: 0, name: "show_tags", value: 2},
              {type: 1, name: "tag_priority", value: "metio.signal,metio.domain"}, {type: 0, name: "show_timeline", value: 0},
              {type: 0, name: "highlight_row", value: 1}, {type: 0, name: "show_lines", value: 12}
            ]
          }
        ]
      },
      {
        name: "Activité",
        widgets: [
          {
            type: "item", name: "Alertes critiques (fenêtre /ops)", x: 0, y: 0, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $critical_alerts_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Alertes avertissement (fenêtre /ops)", x: 18, y: 0, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $warning_alerts_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Erreurs LLM (fenêtre /ops)", x: 36, y: 0, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $llm_errors_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "item", name: "Analyses en erreur (fenêtre /ops)", x: 54, y: 0, width: 18, height: 6, view_mode: 0,
            fields: [{type: 4, name: "itemid.0", value: $analysis_errors_item_id}, {type: 0, name: "show.0", value: 1}, {type: 0, name: "show.1", value: 2}, {type: 0, name: "show.2", value: 3}]
          },
          {
            type: "itemhistory", name: "Dernières mesures", x: 0, y: 6, width: 72, height: 18, view_mode: 0,
            fields: [
              {type: 0, name: "layout", value: 1},
              {type: 1, name: "columns.0.name", value: "Queue par défaut"}, {type: 4, name: "columns.0.itemid", value: $queue_depth_item_id},
              {type: 1, name: "columns.1.name", value: "Plus ancien job prêt"}, {type: 4, name: "columns.1.itemid", value: $queue_oldest_item_id},
              {type: 1, name: "columns.2.name", value: "Heartbeat worker"}, {type: 4, name: "columns.2.itemid", value: $heartbeat_item_id},
              {type: 1, name: "columns.3.name", value: "Échecs de génération"}, {type: 4, name: "columns.3.itemid", value: $generation_failed_item_id},
              {type: 1, name: "columns.4.name", value: "Erreurs d’analyse"}, {type: 4, name: "columns.4.itemid", value: $analysis_errors_item_id},
              {type: 0, name: "show_lines", value: 20}, {type: 0, name: "show_timestamp", value: 1}, {type: 0, name: "show_column_header", value: 1}
            ]
          }
        ]
      },
      {
        name: "Données /ops",
        widgets: [
          {
            type: "itemhistory", name: "Derniers snapshots /ops", x: 0, y: 0, width: 72, height: 24, view_mode: 0,
            fields: [
              {type: 0, name: "layout", value: 1}, {type: 1, name: "columns.0.name", value: "Réponse JSON /ops"},
              {type: 4, name: "columns.0.itemid", value: $raw_item_id}, {type: 0, name: "show_lines", value: 5},
              {type: 0, name: "show_timestamp", value: 1}, {type: 0, name: "show_column_header", value: 1}
            ]
          }
        ]
      }
    ]
  }')
  call dashboard.create "$params" "$auth" >/dev/null
}

ensure_eviamemo_profile() {
  host_id=$1
  raw_item_id=$2
  status_item_id=$(get_item_id "$host_id" 'metio.ops.status.code')
  release_item_id=$(get_item_id "$host_id" 'metio.ops.release.version')
  snapshot_item_id=$(get_item_id "$host_id" 'metio.ops.generated_at')
  database_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'PostgreSQL : état' 'eviamemo.database.status' 4 '' '$.checks.database.status' 'dependencies' 'postgres' 'État fourni par le snapshot /ops Eviamemo.')
  cache_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Redis : état' 'eviamemo.cache.status' 4 '' '$.checks.cache.status' 'dependencies' 'redis' 'État fourni par le snapshot /ops Eviamemo.')
  workers_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Workers : état' 'eviamemo.workers.status' 4 '' '$.checks.workers.status' 'workers' 'workers' 'État agrégé des workers Eviamemo.')
  queue_depth_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Queue par défaut : profondeur' 'eviamemo.queue.default.depth' 3 'jobs' "$.checks.workers.queues.items[?(@.name == 'default')].depth.first()" 'workload' 'queue_depth' 'Total atomique des jobs prêts, différés et réservés dans la queue default.')
  queue_oldest_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Queue par défaut : âge du plus ancien job prêt' 'eviamemo.queue.default.oldest_ready_age' 3 's' "$.checks.workers.queues.items[?(@.name == 'default')].oldest_ready_job_age_s.first()" 'workload' 'queue_oldest_age' 'Âge du plus ancien job prêt dans la queue default ; nul lorsqu’aucun job prêt n’est présent.')
  heartbeat_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Worker principal : âge du heartbeat' 'eviamemo.worker.queue.heartbeat_age' 3 's' '$.checks.workers.processes.queue.heartbeat_age_s' 'workers' 'heartbeat_age' 'Âge du dernier heartbeat du worker principal.')
  critical_alerts_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Activité : alertes critiques' 'eviamemo.activity.alerts.critical' 3 '' '$.activity.alerts.critical' 'activity' 'critical_alerts' 'Nombre d’alertes critiques dans la fenêtre déclarée par /ops.')
  warning_alerts_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Activité : alertes avertissement' 'eviamemo.activity.alerts.warning' 3 '' '$.activity.alerts.warning' 'activity' 'warning_alerts' 'Nombre d’alertes avertissement dans la fenêtre déclarée par /ops.')
  llm_errors_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Activité : erreurs LLM' 'eviamemo.activity.llm.errors' 3 '' '$.activity.llm.errors' 'activity' 'llm_errors' 'Nombre d’erreurs LLM dans la fenêtre déclarée par /ops.')
  generation_failed_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Activité : générations en échec' 'eviamemo.activity.generation.failed' 3 '' '$.activity.generation.failed' 'activity' 'generation_failed' 'Nombre de générations en échec dans la fenêtre déclarée par /ops.')
  analysis_errors_item_id=$(ensure_host_dependent_item "$host_id" "$raw_item_id" 'Activité : analyses en erreur' 'eviamemo.activity.analysis.errors' 3 '' '$.activity.analysis.errors' 'activity' 'analysis_errors' 'Nombre d’analyses en erreur dans la fenêtre déclarée par /ops.')

  ensure_host_trigger 'Eviamemo — PostgreSQL indisponible' 'last(/metio-app-eviamemo/eviamemo.database.status)<>"ok"' 4 'dependencies' 'postgres' 'État déclaré : {ITEM.LASTVALUE}'
  ensure_host_trigger 'Eviamemo — Redis indisponible' 'last(/metio-app-eviamemo/eviamemo.cache.status)<>"ok"' 4 'dependencies' 'redis' 'État déclaré : {ITEM.LASTVALUE}'
  ensure_host_trigger 'Eviamemo — Workers indisponibles' 'last(/metio-app-eviamemo/eviamemo.workers.status)<>"ok"' 4 'workers' 'workers' 'État déclaré : {ITEM.LASTVALUE}'
  ensure_eviamemo_dashboard "$host_id" "$status_item_id" "$release_item_id" "$snapshot_item_id" "$raw_item_id" "$database_item_id" "$cache_item_id" "$workers_item_id" "$queue_depth_item_id" "$queue_oldest_item_id" "$heartbeat_item_id" "$critical_alerts_item_id" "$warning_alerts_item_id" "$llm_errors_item_id" "$generation_failed_item_id" "$analysis_errors_item_id"
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
  application_ops_template_id=$3
  application_liveness_template_id=$4
  technical_name="metio-app-$project_id"
  params=$(jq -cn --arg host "$technical_name" '{output: ["hostid"], filter: {host: [$host]}}')
  result=$(call host.get "$params" "$auth")
  host_id=$(printf '%s' "$result" | jq -r '.[0].hostid // empty')

  if [ -z "$host_id" ]; then
    params=$(jq -cn --arg host "$technical_name" --arg name "$project_name" --arg group_id "$applications_group_id" --arg template_id "$application_ops_template_id" --arg liveness_template_id "$application_liveness_template_id" --arg project_id "$project_id" '{
      host: $host,
      name: $name,
      status: 1,
      groups: [{groupid: $group_id}],
      templates: [{templateid: $template_id}, {templateid: $liveness_template_id}],
      tags: [{tag: "metio.project", value: $project_id}, {tag: "metio.kind", value: "application"}],
      macros: [{macro: "{$OPS.URL}", value: ""}, {macro: "{$OPS.TOKEN}", value: "", type: 1}],
      description: "Précréé par Monitoring. Désactivé tant que le endpoint et ses règles ne sont pas configurés dans Zabbix."
    }')
    call host.create "$params" "$auth" >/dev/null
  fi
}

ensure_host_template_link() {
  host_id=$1
  template_id=$2
  params=$(jq -cn --arg host_id "$host_id" '{output: ["hostid"], hostids: [$host_id], selectParentTemplates: ["templateid"]}')
  result=$(call host.get "$params" "$auth")

  if printf '%s' "$result" | jq -e --arg template_id "$template_id" '.[0].parentTemplates[]? | select(.templateid == $template_id)' >/dev/null; then
    return
  fi

  templates=$(printf '%s' "$result" | jq -ce --arg template_id "$template_id" '((.[0].parentTemplates // []) | map({templateid}) + [{templateid: $template_id}] | unique_by(.templateid))')
  params=$(jq -cn --arg host_id "$host_id" --argjson templates "$templates" '{hostid: $host_id, templates: $templates}')
  call host.update "$params" "$auth" >/dev/null
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

liveness_template_id=$(ensure_liveness_template)
liveness_trigger_id=$(get_template_trigger_id "$liveness_template_id" 'Application inaccessible sur {HOST.NAME}')
readiness_template_id=$(ensure_readiness_template)
readiness_trigger_id=$(get_template_trigger_id "$readiness_template_id" 'Application non prête sur {HOST.NAME}')

collector_host_id=$(ensure_collector_host)
ensure_collector_http_item "$collector_host_id" 'Collecteur HTTP : sortie directe Cloudflare' 'metio.collector.http.ip' 'https://1.1.1.1/cdn-cgi/trace' '200' 'Contrôle une première sortie HTTPS sans résolution DNS.' >/dev/null
ensure_collector_http_item "$collector_host_id" 'Collecteur HTTP : sortie directe Google' 'metio.collector.http.ip.google' 'https://8.8.8.8/generate_204' '204' 'Contrôle une seconde sortie HTTPS sans résolution DNS et indépendante de Cloudflare.' >/dev/null
ensure_collector_http_item "$collector_host_id" 'Collecteur HTTP : résolution Cloudflare' 'metio.collector.http.dns' 'https://one.one.one.one/cdn-cgi/trace' '200' 'Contrôle une première résolution DNS suivie d’une sortie HTTPS.' >/dev/null
ensure_collector_http_item "$collector_host_id" 'Collecteur HTTP : résolution Google' 'metio.collector.http.dns.google' 'https://dns.google/generate_204' '204' 'Contrôle une seconde résolution DNS indépendante de Cloudflare.' >/dev/null
collector_outbound_trigger_id=$(ensure_collector_trigger "$collector_host_id" 'Sortie HTTP du collecteur Zabbix indisponible' 'nodata(/metio-monitoring-collector/metio.collector.http.ip,5m)=1 and nodata(/metio-monitoring-collector/metio.collector.http.ip.google,5m)=1' 4 'collector_outbound' 'Aucune des deux sorties HTTPS directes ne fournit de valeur depuis 5 minutes.')
collector_dns_trigger_id=$(ensure_collector_trigger "$collector_host_id" 'Résolution DNS du collecteur Zabbix indisponible' 'nodata(/metio-monitoring-collector/metio.collector.http.dns,5m)=1 and nodata(/metio-monitoring-collector/metio.collector.http.dns.google,5m)=1 and (nodata(/metio-monitoring-collector/metio.collector.http.ip,5m)=0 or nodata(/metio-monitoring-collector/metio.collector.http.ip.google,5m)=0)' 3 'collector_dns' 'Les deux contrôles nommés sont muets depuis 5 minutes alors qu’au moins une sortie HTTPS directe fonctionne.')

ensure_trigger_dependencies "$liveness_trigger_id" "$collector_outbound_trigger_id" "$collector_dns_trigger_id"
ensure_trigger_dependencies "$readiness_trigger_id" "$liveness_trigger_id" "$collector_outbound_trigger_id" "$collector_dns_trigger_id"

template_id=$(ensure_template)
ops_template_id=$template_id
raw_item_id=$(get_item_id "$template_id" 'metio.ops.raw')
status_value_map_id=$(ensure_status_value_map "$template_id")
status_item_id=$(ensure_ops_status_item "$template_id" "$raw_item_id" "$status_value_map_id")
release_item_id=$(ensure_ops_text_item "$template_id" "$raw_item_id" 'Version déployée' 'metio.ops.release.version' '$.release.version' 'health' 'release')
generated_at_item_id=$(ensure_ops_text_item "$template_id" "$raw_item_id" 'Snapshot /ops généré le' 'metio.ops.generated_at' '$.generated_at' 'health' 'snapshot_time')
ensure_ops_trigger 'Application dégradée sur {HOST.NAME}' 'last(/metio.ops.generic/metio.ops.status.code)=1' 2 'status' 'État déclaré : {ITEM.LASTVALUE}'
ensure_ops_trigger 'Application critique sur {HOST.NAME}' 'last(/metio.ops.generic/metio.ops.status.code)=2' 4 'status' 'État déclaré : {ITEM.LASTVALUE}'

ops_unavailable_trigger_id=$(get_template_trigger_id "$template_id" 'Endpoint /ops indisponible sur {HOST.NAME}')
ops_degraded_trigger_id=$(get_template_trigger_id "$template_id" 'Application dégradée sur {HOST.NAME}')
ops_critical_trigger_id=$(get_template_trigger_id "$template_id" 'Application critique sur {HOST.NAME}')
ensure_trigger_dependencies "$ops_unavailable_trigger_id" "$liveness_trigger_id" "$collector_outbound_trigger_id" "$collector_dns_trigger_id"
ensure_trigger_dependencies "$ops_degraded_trigger_id" "$ops_unavailable_trigger_id" "$collector_outbound_trigger_id" "$collector_dns_trigger_id"
ensure_trigger_dependencies "$ops_critical_trigger_id" "$ops_unavailable_trigger_id" "$collector_outbound_trigger_id" "$collector_dns_trigger_id"

ensure_template_dashboard "$template_id" "$raw_item_id" "$status_item_id" "$release_item_id" "$generated_at_item_id"
if [ "$upgrade_existing" -eq 0 ]; then
  ensure_global_dashboard "$applications_group_id"
fi

jq -r '.projects[] | [.id, .name, .health_url, (.ready_url // "")] | join("|")' "$projects_file" | while IFS='|' read -r project_id project_name health_url ready_url; do
  ensure_application_host "$project_id" "$project_name" "$ops_template_id" "$liveness_template_id"
  application_host_id=$(get_host_id "metio-app-$project_id")
  ensure_host_template_link "$application_host_id" "$liveness_template_id"
  ensure_host_macro "$application_host_id" '{$HEALTH.URL}' "$health_url"

  if [ -n "$ready_url" ]; then
    ensure_host_template_link "$application_host_id" "$readiness_template_id"
    ensure_host_macro "$application_host_id" '{$READY.URL}' "$ready_url"
  fi
done

eviamemo_host_id=$(printf '%s' "$(call host.get '{"output":["hostid"],"filter":{"host":["metio-app-eviamemo"]}}' "$auth")" | jq -r '.[0].hostid // empty')
if [ -z "$eviamemo_host_id" ]; then
  echo "Le profil Eviamemo n’a pas pu être préparé : l’hôte est introuvable." >&2
  exit 1
fi

ensure_host_template_link "$eviamemo_host_id" "$ops_template_id"

# Les premières installations d’Eviamemo possèdent déjà une sonde dédiée
# eviamemo.ops.raw. Le rattachement du modèle commun doit préserver cette
# collecte active ; le profil commun est créé seulement sur les hôtes neufs.
eviamemo_legacy_raw_item_id=$(get_item_id "$eviamemo_host_id" 'eviamemo.ops.raw')
if [ -z "$eviamemo_legacy_raw_item_id" ]; then
  eviamemo_raw_item_id=$(get_item_id "$eviamemo_host_id" 'metio.ops.raw')
  if [ -n "$eviamemo_raw_item_id" ]; then
    ensure_eviamemo_profile "$eviamemo_host_id" "$eviamemo_raw_item_id"
  else
    echo "Le profil Eviamemo n’a pas pu être préparé : l’item /ops est introuvable." >&2
    exit 1
  fi
fi

umask 077
touch "$state_file"
echo "Bootstrap Zabbix terminé : sondes HTTP/readiness, garde-fous du collecteur, dépendances d’alertes et profils applicatifs disponibles."
