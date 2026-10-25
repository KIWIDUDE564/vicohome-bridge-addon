# Event delivery helpers for run.sh. Keep all mutable state in the parent shell.
bridge_now() { date +%s; }

init_event_store() {
  mkdir -p "${DATA_DIR}" || return 1
  EVENT_STORE="${DATA_DIR}/delivery.json"
  if [ ! -f "${EVENT_STORE}" ]; then
    local now
    now=${BRIDGE_NOW:-$(bridge_now)}
    jq -n --argjson now "$now" '{version:1,cutoff:$now,seen:{},latest:{},motion:{}}' > "${EVENT_STORE}.tmp" &&
      mv "${EVENT_STORE}.tmp" "${EVENT_STORE}" || return 1
  fi
  jq -e '
    def timestamp: type == "number" and . >= 0 and isfinite;
    type == "object" and .version == 1 and (.cutoff|timestamp) and
    (.seen|type == "object" and all(.[];timestamp)) and
    (.latest|type == "object" and all(.[];type == "object" and (.ts|timestamp) and (.key|type == "string" and length > 0))) and
    (.motion|type == "object" and all(.[];timestamp)) and
    (if has("history_complete") then (.history_complete|type == "boolean") else true end)
  ' "${EVENT_STORE}" >/dev/null 2>&1
}

ack_event() {
  local action="$1" deadline="$2" now="$3"
  jq --argjson action "$action" --argjson deadline "$deadline" --argjson now "$now" '
    .seen |= with_entries(select(.value >= $now - 518400)) |
    if $action.history then . else .seen[$action.key] = $action.ts end |
    if $action.state then .latest[$action.camera] = {ts:$action.ts,key:$action.key} else . end |
    if $deadline > 0 then .motion[$action.camera] = $deadline else . end
  ' "$EVENT_STORE" > "${EVENT_STORE}.tmp" && mv "${EVENT_STORE}.tmp" "$EVENT_STORE"
}

process_events() {
  local json="$1" mode="${2:-live}" now actions action camera safe_id event history state ts deadline kind
  now=${BRIDGE_NOW:-$(bridge_now)}
  if ! actions=$(printf '%s' "$json" | jq -c --slurpfile ledger "$EVENT_STORE" \
      --argjson now "$now" --arg mode "$mode" -f "${BRIDGE_LIB_DIR}/events.jq"); then
    bashio::log.warning "Invalid event response; retrying next poll."
    return 0
  fi
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    camera=$(jq -r '.camera' <<< "$action")
    safe_id=$(sanitize_id "$camera")
    event=$(jq -c '.event' <<< "$action")
    history=$(jq -r '.history' <<< "$action")
    state=$(jq -r '.state' <<< "$action")
    ts=$(jq -r '.ts|floor' <<< "$action")
    ensure_discovery_published "$camera" "$(jq -r '.deviceName // .cameraName // empty' <<< "$event")" || break
    # Non-retained event stream. Stop on failure so newer state never overtakes retries.
    if [ "$history" != true ]; then
      mosquitto_pub "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/events" -m "$event" -q 1 || break
    fi
    if [ "$state" = true ]; then
      mosquitto_pub "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/state" -m "$event" -q 1 -r || break
    fi
    deadline=0
    kind=$(jq -r '.eventType // "unknown" | if type=="string" then ascii_downcase else "unknown" end' <<< "$event")
    if [ "$history" != true ] && [ "$ts" -ge "$((now - 120))" ]; then
      case "$kind" in
        motion|person|human|bird)
          mosquitto_pub "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/motion" -m ON -q 1 || break
          deadline=$((now + 5)) ;;
      esac
    fi
    if ! ack_event "$action" "$deadline" "$now"; then
      bashio::log.warning "Could not persist event acknowledgement; retrying next poll."
      break
    fi
  done <<< "$actions"
  return 0
}

reset_motion() {
  local force="${1:-false}" now camera safe_id
  now=${BRIDGE_NOW:-$(bridge_now)}
  while IFS= read -r camera; do
    [ -z "$camera" ] && continue
    safe_id=$(sanitize_id "$camera")
    if mosquitto_pub "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/motion" -m OFF -q 1; then
      jq --arg camera "$camera" 'del(.motion[$camera])' "$EVENT_STORE" > "${EVENT_STORE}.tmp" &&
        mv "${EVENT_STORE}.tmp" "$EVENT_STORE" || return 1
    fi
  done < <(jq -r --argjson now "$now" --argjson force "$force" '.motion|to_entries[]|select($force or .value <= $now)|.key' "$EVENT_STORE")
}

fetch_events() {
  local mode="${1:-live}" now start end output
  local args=(events list --format json)
  if [ "$mode" = history ]; then
    now=${BRIDGE_NOW:-$(bridge_now)}
    # jq uses UTC RFC3339, accepted by the bundled CLI on Linux and macOS.
    start=$(jq -nr --argjson t "$((now - 432000))" '$t|todateiso8601')
    end=$(jq -nr --argjson t "$now" '$t|todateiso8601')
    args+=(--startTime "$start" --endTime "$end")
  fi
  if ! output=$("${VICO_CLI:-/usr/local/bin/vico-cli}" "${args[@]}" 2> /tmp/vico_events_error.log); then
    bashio::log.warning "Event request failed; retrying next poll."
    return 0
  fi
  if ! printf '%s' "$output" | jq -e 'type == "array"' >/dev/null 2>&1; then
    bashio::log.warning "Event request did not return a JSON array; retrying next poll."
    return 0
  fi
  process_events "$output" "$mode"
  if [ "$mode" = history ]; then
    local remaining
    remaining=$(printf '%s' "$output" | jq -c --slurpfile ledger "$EVENT_STORE" --argjson now "${BRIDGE_NOW:-$(bridge_now)}" --arg mode history -f "${BRIDGE_LIB_DIR}/events.jq") || return 0
    if [ -z "$remaining" ]; then
      jq '.history_complete = true' "$EVENT_STORE" > "${EVENT_STORE}.tmp" && mv "${EVENT_STORE}.tmp" "$EVENT_STORE"
    fi
  fi
  if [ "$mode" = live ] && [ "$BOOTSTRAP_HISTORY" = true ] && [ "$(jq -r '.history_complete // false' "$EVENT_STORE")" != true ] && [ "$(jq length <<< "$output")" = 0 ]; then
    fetch_events history
  fi
}
