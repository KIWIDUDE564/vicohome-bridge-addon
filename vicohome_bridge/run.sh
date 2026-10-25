#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Vicohome Bridge, based on KIWIDUDE564's add-on and dydx/vico-cli.
BRIDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BRIDGE_LIB_DIR}/events.sh"

# mosquitto_pub 2.0 has no -W timeout option. BusyBox timeout bounds connects/PUBACK waits.
mqtt_publish() {
  timeout 15 mosquitto_pub "$@"
}

publish_availability() {
  local state="$1"
  mqtt_publish "${MQTT_ARGS[@]}" -t "${AVAILABILITY_TOPIC}" -m "${state}" -q 1 -r \
    || bashio::log.warning "Failed to publish availability state '${state}' to ${AVAILABILITY_TOPIC}"
}

sanitize_id() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

# Keep Supervisor discovery as the default; an explicit host selects an external broker.
configure_mqtt() {
  MQTT_HOST=$(bashio::config 'mqtt_host')
  if [ -n "$MQTT_HOST" ] && [ "$MQTT_HOST" != null ]; then
    MQTT_PORT=$(bashio::config 'mqtt_port')
    MQTT_USERNAME=$(bashio::config 'mqtt_username')
    MQTT_PASSWORD=$(bashio::config 'mqtt_password')
  else
    if ! bashio::services.available mqtt; then
      bashio::log.error "Configure mqtt_host or enable the Supervisor MQTT service."
      return 1
    fi
    MQTT_HOST=$(bashio::services mqtt host)
    MQTT_PORT=$(bashio::services mqtt port)
    MQTT_USERNAME=$(bashio::services mqtt username)
    MQTT_PASSWORD=$(bashio::services mqtt password)
  fi
  if [ -z "$MQTT_PORT" ] || [ "$MQTT_PORT" = null ]; then MQTT_PORT=1883; fi
  MQTT_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT")
  if [ -n "$MQTT_USERNAME" ] && [ "$MQTT_USERNAME" != null ]; then
    MQTT_ARGS+=(-u "$MQTT_USERNAME" -P "$MQTT_PASSWORD")
  fi
  if [ "$(bashio::config mqtt_tls)" = true ]; then
    MQTT_ARGS+=(--cafile /etc/ssl/certs/ca-certificates.crt)
  fi
}

ensure_discovery_published() {
  local camera_id="$1" camera_name="$2" safe_id marker now last=0 session=""
  safe_id=$(sanitize_id "$camera_id")
  marker="${DATA_DIR}/discovery_${safe_id}"
  now=$(bridge_now)
  if [ -f "$marker" ]; then
    read -r session last < "$marker" || true
    if [[ "$last" =~ ^[0-9]+$ ]] && [ "$session" = "$DISCOVERY_SESSION" ] && [ "$((now - last))" -lt "$DISCOVERY_REFRESH_SECONDS" ]; then
      return 0
    fi
  fi
  if [ -z "$camera_name" ] || [ "$camera_name" = null ]; then camera_name="Camera ${camera_id}"; fi
  local device_ident="vicohome_camera_v3_${safe_id}" suffix domain payload
  for suffix in last_event motion battery wifi online; do
    domain=sensor
    case "$suffix" in motion|online) domain=binary_sensor;; esac
    payload=$(jq -nc --arg suffix "$suffix" --arg ident "$device_ident" --arg name "Vicohome ${camera_name}" \
      --arg base "${BASE_TOPIC}/${safe_id}" --arg availability "$AVAILABILITY_TOPIC" '
      {unique_id:($ident+"_"+$suffix), availability_topic:$availability,
       payload_available:"online",payload_not_available:"offline",
       device:{identifiers:[$ident],name:$name,manufacturer:"Vicohome",model:"Camera"}}
      + (if $suffix == "last_event" then
          {name:($name+" Last Event"),state_topic:($base+"/state"),json_attributes_topic:($base+"/state"),
           value_template:"{{ value_json.get(\"eventType\") or value_json.get(\"type\") or value_json.get(\"event_type\") or \"unknown\" }}"}
         elif $suffix == "motion" then
          {name:($name+" Motion"),state_topic:($base+"/motion"),device_class:"motion",payload_on:"ON",payload_off:"OFF",off_delay:5}
         elif $suffix == "battery" then
          {name:($name+" Battery"),state_topic:($base+"/telemetry"),device_class:"battery",state_class:"measurement",
           unit_of_measurement:"%",value_template:"{{ value_json.get(\"batteryLevel\") }}"}
         elif $suffix == "wifi" then
          {name:($name+" WiFi"),state_topic:($base+"/telemetry"),device_class:"signal_strength",state_class:"measurement",
           entity_category:"diagnostic",unit_of_measurement:"dBm",value_template:"{{ value_json.get(\"signalStrength\") }}"}
         else
          {name:($name+" Online"),state_topic:($base+"/telemetry"),device_class:"connectivity",entity_category:"diagnostic",
           payload_on:"ON",payload_off:"OFF",value_template:"{% if value_json.get(\"online\") %}ON{% else %}OFF{% endif %}"}
         end)') || return 1
    if ! mqtt_publish "${MQTT_ARGS[@]}" -t "homeassistant/${domain}/${device_ident}_${suffix}/config" -m "$payload" -q 1 -r; then
      bashio::log.warning "Discovery publication failed for ${device_ident}; will retry."
      return 1
    fi
  done
  mqtt_publish "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/motion" -m OFF -q 1 -r || return 1
  printf '%s %s\n' "$DISCOVERY_SESSION" "$now" > "$marker"
}

publish_device_health() {
  local device_json="$1"

  local camera_id
  camera_id=$(echo "${device_json}" | jq -r '.serialNumber // .deviceId // .device_id // .camera_id // .camera.uuid // .cameraId // empty')
  if [ -z "${camera_id}" ] || [ "${camera_id}" = "null" ]; then
    bashio::log.debug "Device payload missing serial/camera ID, skipping health publish."
    return
  fi

  local camera_name
  camera_name=$(echo "${device_json}" | jq -r '.deviceName // .camera_name // .camera.name // .cameraName // .title // empty')
  if [ -z "${camera_name}" ] || [ "${camera_name}" = "null" ]; then
    camera_name="Camera ${camera_id}"
  fi

  local display_name="${camera_name}"

  local ip_raw
  ip_raw=$(echo "${device_json}" | jq -r '.ip // empty')

  local online_raw
  online_raw=$(echo "${device_json}" | jq -r 'if has("online") then .online elif has("isOnline") then .isOnline else .deviceOnline end | select(. != null)' 2>/dev/null)
  local online_json="false"
  local online_explicit="false"
  if [ -n "${online_raw}" ] && [ "${online_raw}" != "null" ]; then
    case "${online_raw}" in
      true|false)
        online_json="${online_raw}"
        online_explicit="true"
        ;;
      1)
        online_json="true"
        online_explicit="true"
        ;;
      0)
        online_json="false"
        online_explicit="true"
        ;;
      ON|on|On)
        online_json="true"
        online_explicit="true"
        ;;
      OFF|off|Off)
        online_json="false"
        online_explicit="true"
        ;;
      *)
        ;;
    esac
  fi

  if [ "${online_explicit}" != "true" ]; then
    if [ -n "${ip_raw}" ] && [ "${ip_raw}" != "null" ]; then
      online_json="true"
    else
      online_json="false"
    fi
  fi

  local safe_id
  safe_id=$(sanitize_id "${camera_id}")

  ensure_discovery_published "${camera_id}" "${camera_name}" || return 1

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local telemetry_payload
  telemetry_payload=$(echo "${device_json}" | jq -c \
    --arg timestamp "${timestamp}" \
    --argjson online "${online_json}" \
    '{batteryLevel:(.batteryLevel // .battery_percent // .batteryPercent // .battery // null), signalStrength:(.signalStrength // .signal_strength // .signalDbm // .signal_dbm // .wifiStrength // .rssi // null), online:$online, ip:(.ip // ""), timestamp:$timestamp}')

  local battery_summary
  battery_summary=$(echo "${telemetry_payload}" | jq -r 'if .batteryLevel == null then "null" else (.batteryLevel|tostring) end')
  local signal_summary
  signal_summary=$(echo "${telemetry_payload}" | jq -r 'if .signalStrength == null then "null" else (.signalStrength|tostring) end')
  local ip_summary
  ip_summary=$(echo "${telemetry_payload}" | jq -r '.ip // ""')

  bashio::log.debug "Telemetry summary for ${display_name} (${safe_id}): battery=${battery_summary}, wifi=${signal_summary}, online=${online_json}, ip=${ip_summary}"
  bashio::log.debug "Telemetry payload for ${safe_id}: ${telemetry_payload}"

  local telemetry_topic="${BASE_TOPIC}/${safe_id}/telemetry"
  mqtt_publish "${MQTT_ARGS[@]}" \
    -t "${telemetry_topic}" \
    -m "${telemetry_payload}" \
    -q 1 -r || bashio::log.warning "Failed to publish telemetry for ${telemetry_topic}"
}

poll_device_health() {
  bashio::log.info "Polling vico-cli for device info..."

  local devices_output
  if ! devices_output=$("${VICO_CLI:-/usr/local/bin/vico-cli}" devices list --format json 2>/tmp/vico_devices_error.log); then
    bashio::log.warning "vico-cli devices list failed; retrying next poll."
    bashio::log.warning "stderr (first 200 chars): $(head -c 200 /tmp/vico_devices_error.log 2>/dev/null)"
    return
  fi

  if [ -z "${devices_output}" ] || [ "${devices_output}" = "null" ]; then
    bashio::log.info "vico-cli devices list returned no data."
    return
  fi

  if ! echo "${devices_output}" | jq -e 'type=="array"' >/dev/null 2>&1; then
    bashio::log.warning "Device list output was not JSON array, skipping telemetry publish."
    return
  fi

  local device_count
  device_count=$(echo "${devices_output}" | jq 'length')
  bashio::log.info "vico-cli devices list returned ${device_count} device(s) for telemetry publishing."
  bashio::log.debug "Device list payload preview: $(echo "${devices_output}" | tr -d '\n' | head -c 400)"

  echo "${devices_output}" | jq -c '.[]' | while read -r device; do
    publish_device_health "${device}"
  done
}

bridge_main() {
  # Load bashio library
  source /usr/lib/bashio/bashio.sh

  # ==========================
  #  Config from options.json
  # ==========================
  EMAIL=$(bashio::config 'email')
  PASSWORD=$(bashio::config 'password')
  POLL_INTERVAL=$(bashio::config 'poll_interval')
  LOG_LEVEL=$(bashio::config 'log_level')
  BASE_TOPIC=$(bashio::config 'base_topic')
  BOOTSTRAP_HISTORY=$(bashio::config 'bootstrap_history')
  REGION=$(bashio::config 'region')
  API_BASE_OVERRIDE=$(bashio::config 'api_base_override')

  [ -z "${BOOTSTRAP_HISTORY}" ] && BOOTSTRAP_HISTORY="false"

  # Defaults
  if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [ "$POLL_INTERVAL" -lt 5 ] || [ "$POLL_INTERVAL" -gt 3600 ]; then POLL_INTERVAL=60; fi
  [ -z "${LOG_LEVEL}" ] && LOG_LEVEL="info"
  [ -z "${BASE_TOPIC}" ] && BASE_TOPIC="vicohome"
  if [ "${REGION}" = "null" ]; then
    REGION=""
  fi
  [ -z "${REGION}" ] && REGION="auto"
  AVAILABILITY_TOPIC="${BASE_TOPIC}/bridge/status"
  # How often (in seconds) to refresh MQTT discovery payloads so deleted entities get recreated.
  DISCOVERY_REFRESH_SECONDS=300
  DISCOVERY_SESSION="$(bridge_now)-$$"

  bashio::log.info "Vicohome Bridge configuration:"
  bashio::log.info "  poll_interval = ${POLL_INTERVAL}s"
  bashio::log.info "  base_topic    = ${BASE_TOPIC}"
  bashio::log.info "  log_level     = ${LOG_LEVEL}"
  bashio::log.info "  region        = ${REGION}"
  if [ -n "${API_BASE_OVERRIDE}" ] && [ "${API_BASE_OVERRIDE}" != "null" ]; then
    bashio::log.info "  api_base_override = ${API_BASE_OVERRIDE}"
  else
    API_BASE_OVERRIDE=""
  fi

  bashio::log.level "${LOG_LEVEL}"

  if [ -z "${EMAIL}" ] || [ -z "${PASSWORD}" ]; then
    bashio::log.error "You must set 'email' and 'password' in the add-on configuration."
    exit 1
  fi

  # ==========================
  #  MQTT service discovery
  # ==========================
  configure_mqtt || return 1

  bashio::log.info "Using MQTT broker at ${MQTT_HOST}:${MQTT_PORT}, base topic: ${BASE_TOPIC}"

  trap 'publish_availability offline' EXIT
  trap 'exit 0' TERM INT
  publish_availability online

  # ==========================
  #  Environment for vico-cli
  # ==========================
  export VICOHOME_EMAIL="${EMAIL}"
  export VICOHOME_PASSWORD="${PASSWORD}"
  export VICOHOME_DEBUG="0"
  [ "$LOG_LEVEL" = debug ] && export VICOHOME_DEBUG="1"
  export VICOHOME_REGION="${REGION}"
  if [ -n "${API_BASE_OVERRIDE}" ]; then
    export VICOHOME_API_BASE="${API_BASE_OVERRIDE}"
  fi

  DATA_DIR="${DATA_DIR:-/data}"
  init_event_store || { bashio::log.error "Invalid delivery ledger; refusing to replay events."; return 1; }
  reset_motion true


  local next_poll=0 now
  while true; do
    reset_motion || bashio::log.warning "Motion reset will be retried."
    now=$(bridge_now)
    if [ "$now" -ge "$next_poll" ]; then
      publish_availability online
      poll_device_health
      fetch_events live
      next_poll=$((now + POLL_INTERVAL))
    fi
    sleep 5
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  bridge_main
fi
