#!/bin/sh

set -eu

: "${ZABBIX_ADMIN_PASSWORD:?ZABBIX_ADMIN_PASSWORD is required}"

api_url=${ZABBIX_API_URL:-http://zabbix-web:8080/api_jsonrpc.php}
state_file=/state/seeded-v1
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
  printf '%s' "$response" | jq -er '.result' 2>/dev/null
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
      readme: "Renseigner {$OPS.URL}, tester la réponse JSON, puis créer les items dépendants et les triggers propres à chaque application. Le format JSON est volontairement libre.",
      wizard_ready: 1,
      groups: [{groupid: $group_id}],
      macros: [
        {macro: "{$OPS.URL}", value: "https://replace-me.invalid/ops"},
        {macro: "{$OPS.AUTHORIZATION}", value: ""}
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
      headers: [{name: "Authorization", value: "{$OPS.AUTHORIZATION}"}],
      description: "Réponse brute. Ajouter des items dépendants pour les champs JSON utiles."
    }')
    result=$(call item.create "$params" "$auth")
    item_id=$(printf '%s' "$result" | jq -r '.itemids[0]')
  fi

  trigger_params='{"output":["triggerid"],"filter":{"description":["Endpoint /ops indisponible sur {HOST.NAME}"]}}'
  result=$(call trigger.get "$trigger_params" "$auth")
  trigger_id=$(printf '%s' "$result" | jq -r '.[0].triggerid // empty')

  if [ -z "$trigger_id" ]; then
    params='{"description":"Endpoint /ops indisponible sur {HOST.NAME}","expression":"nodata(/metio.ops.generic/metio.ops.raw,5m)=1","priority":4,"manual_close":1,"tags":[{"tag":"metio.signal","value":"endpoint"}]}'
    call trigger.create "$params" "$auth" >/dev/null
  fi

  printf '%s' "$template_id"
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
      macros: [{macro: "{$OPS.URL}", value: "https://replace-me.invalid/ops"}, {macro: "{$OPS.AUTHORIZATION}", value: ""}],
      description: "Précréé par Monitoring. Désactivé tant que le endpoint et ses règles ne sont pas configurés dans Zabbix."
    }')
    call host.create "$params" "$auth" >/dev/null
  fi
}

echo "Attente de l'API Zabbix…"
attempt=1
auth=''
admin_id=''
password_is_default=0
while [ "$attempt" -le 90 ]; do
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
    auth=''
    password_is_default=0
  fi

  attempt=$((attempt + 1))
  sleep 2
done

if [ -z "$auth" ] || [ -z "$admin_id" ]; then
  echo "Impossible de se connecter à Zabbix ou de lire sa configuration." >&2
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

jq -r '.projects[] | [.id, .name] | join("|")' "$projects_file" | while IFS='|' read -r project_id project_name; do
  ensure_application_host "$project_id" "$project_name"
done

umask 077
touch "$state_file"
echo "Bootstrap Zabbix terminé : cinq applications précréées et désactivées."
