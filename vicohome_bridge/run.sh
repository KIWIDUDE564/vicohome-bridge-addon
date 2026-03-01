#!/usr/bin/with-contenv bash
# shellcheck shell=bash

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
HAS_BOOTSTRAPPED="false"

# Defaults
[ -z "${POLL_INTERVAL}" ] && POLL_INTERVAL=60
[ -z "${LOG_LEVEL}" ] && LOG_LEVEL="info"
[ -z "${BASE_TOPIC}" ] && BASE_TOPIC="vicohome"
if [ "${REGION}" = "null" ]; then
  REGION=""
fi
[ -z "${REGION}" ] && REGION="auto"
AVAILABILITY_TOPIC="${BASE_TOPIC}/bridge/status"
# How often (in seconds) to refresh MQTT discovery payloads so deleted entities get recreated.
DISCOVERY_REFRESH_SECONDS=300

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
if ! bashio::services.available "mqtt"; then
  bashio::log.error "MQTT service not available. Make sure the MQTT integration/add-on is set up."
  exit 1
fi

MQTT_HOST=$(bashio::services mqtt "host")
MQTT_PORT=$(bashio::services mqtt "port")
MQTT_USERNAME=$(bashio::services mqtt "username")
MQTT_PASSWORD=$(bashio::services mqtt "password")

MQTT_ARGS="-h ${MQTT_HOST} -p ${MQTT_PORT}"
if [ -n "${MQTT_USERNAME}" ] && [ "${MQTT_USERNAME}" != "null" ]; then
  MQTT_ARGS="${MQTT_ARGS} -u ${MQTT_USERNAME} -P ${MQTT_PASSWORD}"
fi

bashio::log.info "Using MQTT broker at ${MQTT_HOST}:${MQTT_PORT}, base topic: ${BASE_TOPIC}"

publish_availability() {
  local state="$1"
  mosquitto_pub ${MQTT_ARGS} -t "${AVAILABILITY_TOPIC}" -m "${state}" -r \
    || bashio::log.warning "Failed to publish availability state '${state}' to ${AVAILABILITY_TOPIC}"
}

trap 'publish_availability offline' EXIT
publish_availability online

# ==========================
#  Environment for vico-cli
# ==========================
export VICOHOME_EMAIL="${EMAIL}"
export VICOHOME_PASSWORD="${PASSWORD}"
export VICOHOME_DEBUG="1"
export VICOHOME_REGION="${REGION}"
if [ -n "${API_BASE_OVERRIDE}" ]; then
  export VICOHOME_API_BASE="${API_BASE_OVERRIDE}"
fi

mkdir -p /data

# ==========================
#  Helper functions
# ==========================

sanitize_id() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

# v3 marker so HA treats these as a new generation of devices/entities
ensure_discovery_published() {
  local camera_id="$1"
  local camera_name="$2"

  local safe_id
  safe_id=$(sanitize_id "${camera_id}")

  local publish_required="true"
  local marker="/data/cameras_seen_v3_${safe_id}"
  local now
  now=$(date +%s)
  local refresh_reason="initial publish"

  if [ -f "${marker}" ]; then
    local last_touch
    last_touch=$(stat -c %Y "${marker}" 2>/dev/null || echo 0)
    local age=$((now - last_touch))

    if [ "${age}" -lt "${DISCOVERY_REFRESH_SECONDS}" ]; then
      publish_required="false"
    else
      refresh_reason="${age}s since last publish exceeded ${DISCOVERY_REFRESH_SECONDS}s refresh window"
    fi
  fi

  if [ "${publish_required}" != "true" ]; then
    return 0
  fi

  bashio::log.debug "Publishing MQTT discovery for ${safe_id} (${camera_name}): ${refresh_reason}."

  # v3 device identifier / unique_id base
  local device_ident="vicohome_camera_v3_${safe_id}"
  local state_topic="${BASE_TOPIC}/${safe_id}/state"
  local motion_topic="${BASE_TOPIC}/${safe_id}/motion"
  local telemetry_topic="${BASE_TOPIC}/${safe_id}/telemetry"

  local sensor_topic="homeassistant/sensor/${device_ident}_last_event/config"
  local motion_config_topic="homeassistant/binary_sensor/${device_ident}_motion/config"
  local battery_config_topic="homeassistant/sensor/${device_ident}_battery/config"
  local wifi_config_topic="homeassistant/sensor/${device_ident}_wifi/config"
  local online_config_topic="homeassistant/binary_sensor/${device_ident}_online/config"

  if [ -z "${camera_name}" ] || [ "${camera_name}" = "null" ]; then
    camera_name="Camera ${camera_id}"
  fi

  # Last Event sensor (state = event type, attributes = full JSON)
  local sensor_payload
  sensor_payload=$(cat <<EOF
{"name":"Vicohome ${camera_name} Last Event","unique_id":"${device_ident}_last_event","state_topic":"${state_topic}","availability_topic":"${AVAILABILITY_TOPIC}","payload_available":"online","payload_not_available":"offline","value_template":"{{ value_json.eventType or value_json.type or value_json.event_type }}","json_attributes_topic":"${state_topic}","device":{"identifiers":["${device_ident}"],"name":"Vicohome ${camera_name}","manufacturer":"Vicohome","model":"Camera"}}
EOF
)

  # Motion binary sensor (short pulse on motion/person/bird/human)
  local motion_payload
  motion_payload=$(cat <<EOF
{"name":"Vicohome ${camera_name} Motion","unique_id":"${device_ident}_motion","state_topic":"${motion_topic}","availability_topic":"${AVAILABILITY_TOPIC}","payload_available":"online","payload_not_available":"offline","device_class":"motion","payload_on":"ON","payload_off":"OFF","expire_after":30,"device":{"identifiers":["${device_ident}"],"name":"Vicohome ${camera_name}","manufacturer":"Vicohome","model":"Camera"}}
EOF
)

  local battery_payload
  battery_payload=$(cat <<EOF
{"name":"Vicohome ${camera_name} Battery","unique_id":"${device_ident}_battery","state_topic":"${telemetry_topic}","availability_topic":"${AVAILABILITY_TOPIC}","payload_available":"online","payload_not_available":"offline","value_template":"{{ value_json.batteryLevel }}","unit_of_measurement":"%","device_class":"battery","state_class":"measurement","device":{"identifiers":["${device_ident}"],"name":"Vicohome ${camera_name}","manufacturer":"Vicohome","model":"Camera"}}
EOF
)

  local wifi_payload
  wifi_payload=$(cat <<EOF
{"name":"Vicohome ${camera_name} WiFi","unique_id":"${device_ident}_wifi","state_topic":"${telemetry_topic}","availability_topic":"${AVAILABILITY_TOPIC}","payload_available":"online","payload_not_available":"offline","value_template":"{{ value_json.signalStrength }}","unit_of_measurement":"dBm","device_class":"signal_strength","state_class":"measurement","entity_category":"diagnostic","device":{"identifiers":["${device_ident}"],"name":"Vicohome ${camera_name}","manufacturer":"Vicohome","model":"Camera"}}
EOF
)

  local online_payload
  online_payload=$(cat <<EOF
{"name":"Vicohome ${camera_name} Online","unique_id":"${device_ident}_online","state_topic":"${telemetry_topic}","availability_topic":"${AVAILABILITY_TOPIC}","payload_available":"online","payload_not_available":"offline","value_template":"{% if value_json.online %}ON{% else %}OFF{% endif %}","payload_on":"ON","payload_off":"OFF","device_class":"connectivity","entity_category":"diagnostic","device":{"identifiers":["${device_ident}"],"name":"Vicohome ${camera_name}","manufacturer":"Vicohome","model":"Camera"}}
EOF
)

  mosquitto_pub ${MQTT_ARGS} -t "${sensor_topic}" -m "${sensor_payload}" -q 0 || \
    bashio::log.warning "Failed to publish MQTT discovery config for sensor ${device_ident}_last_event"

  mosquitto_pub ${MQTT_ARGS} -t "${motion_config_topic}" -m "${motion_payload}" -q 0 || \
    bashio::log.warning "Failed to publish MQTT discovery config for binary_sensor ${device_ident}_motion"

  mosquitto_pub ${MQTT_ARGS} -t "${battery_config_topic}" -m "${battery_payload}" -q 0 || \
    bashio::log.warning "Failed to publish MQTT discovery config for sensor ${device_ident}_battery"

  mosquitto_pub ${MQTT_ARGS} -t "${wifi_config_topic}" -m "${wifi_payload}" -q 0 || \
    bashio::log.warning "Failed to publish MQTT discovery config for sensor ${device_ident}_wifi"

  mosquitto_pub ${MQTT_ARGS} -t "${online_config_topic}" -m "${online_payload}" -q 0 || \
    bashio::log.warning "Failed to publish MQTT discovery config for binary_sensor ${device_ident}_online"

  if ! touch "${marker}"; then
    bashio::log.warning "Failed to update discovery marker ${marker}; discovery refresh scheduling may misbehave."
  fi
}

publish_event_for_camera() {
  local camera_safe_id="$1"
  local event_json="$2"

  mosquitto_pub ${MQTT_ARGS} \
    -t "${BASE_TOPIC}/${camera_safe_id}/events" \
    -m "${event_json}" \
    -q 0 || bashio::log.warning "Failed to publish MQTT message for ${BASE_TOPIC}/${camera_safe_id}/events"

  mosquitto_pub ${MQTT_ARGS} \
    -t "${BASE_TOPIC}/${camera_safe_id}/state" \
    -m "${event_json}" \
    -q 0 || bashio::log.warning "Failed to publish MQTT message for ${BASE_TOPIC}/${camera_safe_id}/state"
}

publish_motion_pulse() {
  local camera_safe_id="$1"
  local motion_topic="${BASE_TOPIC}/${camera_safe_id}/motion"

  mosquitto_pub ${MQTT_ARGS} \
    -t "${motion_topic}" \
    -m "ON" \
    -q 0 || bashio::log.warning "Failed to publish motion ON for ${motion_topic}"

  (
    sleep 5
    mosquitto_pub ${MQTT_ARGS} \
      -t "${motion_topic}" \
      -m "OFF" \
      -q 0 || bashio::log.warning "Failed to publish motion OFF for ${motion_topic}"
  ) &
}

run_bootstrap_history() {
  if [ "${BOOTSTRAP_HISTORY}" != "true" ] || [ "${HAS_BOOTSTRAPPED}" = "true" ]; then
    return 0
  fi

  bashio::log.info "Running one-time bootstrap history pull from vico-cli..."

  BOOTSTRAP_JSON=$(/usr/local/bin/vico-cli events list \
    --format json \
    --since 120h 2>/tmp/vico_bootstrap_error.log)
  EXIT_CODE=$?

  if [ ${EXIT_CODE} -ne 0 ] || [ -z "${BOOTSTRAP_JSON}" ] || [ "${BOOTSTRAP_JSON}" = "null" ]; then
    bashio::log.warning "Bootstrap history pull failed (exit ${EXIT_CODE}). stderr: $(head -c 200 /tmp/vico_bootstrap_error.log 2>/dev/null)"
    HAS_BOOTSTRAPPED="true"
    return 0
  fi

  if echo "${BOOTSTRAP_JSON}" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "${BOOTSTRAP_JSON}" | jq -c 'reverse | .[]' | while read -r event; do
      CAMERA_ID=$(echo "${event}" | jq -r '.serialNumber // .deviceId // .device_id // .camera_id // .camera.uuid // .cameraId // empty')
      [ -z "${CAMERA_ID}" ] && continue

      SAFE_ID=$(sanitize_id "${CAMERA_ID}")
      CAMERA_NAME=$(echo "${event}" | jq -r '.deviceName // .camera_name // .camera.name // .cameraName // .title // empty')
      EVENT_TYPE=$(echo "${event}" | jq -r '.eventType // .type // .event_type // empty')

      ensure_discovery_published "${CAMERA_ID}" "${CAMERA_NAME}"
      publish_event_for_camera "${SAFE_ID}" "${event}"

      if [ "${EVENT_TYPE}" = "motion" ] || [ "${EVENT_TYPE}" = "person" ] || [ "${EVENT_TYPE}" = "human" ] || [ "${EVENT_TYPE}" = "bird" ]; then
        publish_motion_pulse "${SAFE_ID}"
      fi
    done
  fi

  HAS_BOOTSTRAPPED="true"
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
  online_raw=$(echo "${device_json}" | jq -r '.online // .isOnline // .deviceOnline // empty' 2>/dev/null)
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

  ensure_discovery_published "${camera_id}" "${camera_name}"

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
  mosquitto_pub ${MQTT_ARGS} \
    -t "${telemetry_topic}" \
    -m "${telemetry_payload}" \
    -q 0 || bashio::log.warning "Failed to publish telemetry for ${telemetry_topic}"
}

poll_device_health() {
  bashio::log.info "Polling vico-cli for device info..."

  local devices_output
  devices_output=$(/usr/local/bin/vico-cli devices list --format json 2>/tmp/vico_devices_error.log)
  local exit_code=$?

  if [ ${exit_code} -ne 0 ]; then
    bashio::log.warning "vico-cli devices list exited with code ${exit_code}."
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

# ==========================
#  Optional: log vico-cli version
# ==========================
if /usr/local/bin/vico-cli version >/tmp/vico_version.log 2>&1; then
  VICO_VERSION_LINE=$(head -n1 /tmp/vico_version.log)
  bashio::log.info "vico-cli version: ${VICO_VERSION_LINE}"
else
  VICO_VERSION_ERR=$(head -n1 /tmp/vico_version.log 2>/dev/null)
  [ -n "${VICO_VERSION_ERR}" ] && \
    bashio::log.warning "Could not get vico-cli version. Output: ${VICO_VERSION_ERR}"
fi

bashio::log.info "Starting Vicohome Bridge main loop: polling every ${POLL_INTERVAL}s"
bashio::log.info "NOTE: Entities are created lazily when events are received."

# ==========================
#  Main loop
# ==========================
while true; do
  poll_device_health
  bashio::log.info "Polling vico-cli for events..."

  JSON_OUTPUT=$(/usr/local/bin/vico-cli events list --format json 2>/tmp/vico_error.log)
  EXIT_CODE=$?

  if [ ${EXIT_CODE} -ne 0 ]; then
    bashio::log.error "vico-cli exited with code ${EXIT_CODE}."
    bashio::log.error "vico-cli stderr (first 300 chars): $(head -c 300 /tmp/vico_error.log 2>/dev/null)"
    sleep "${POLL_INTERVAL}"
    continue
  fi

  if [ -z "${JSON_OUTPUT}" ] || [ "${JSON_OUTPUT}" = "null" ]; then
    bashio::log.info "vico-cli reported no events in the recent window."
    run_bootstrap_history
    sleep "${POLL_INTERVAL}"
    continue
  fi

  if [ ${EXIT_CODE} -eq 0 ] && echo "${JSON_OUTPUT}" | grep -q "No events found"; then
    bashio::log.info "vico-cli reported no events in the recent window."
    run_bootstrap_history
    sleep "${POLL_INTERVAL}"
    continue
  fi

  if [ ${EXIT_CODE} -eq 0 ] && echo "${JSON_OUTPUT}" | grep -q "No events found"; then
    bashio::log.info "vico-cli reported no events in the recent window."
    bootstrap_history_if_needed
    sleep "${POLL_INTERVAL}"
    continue
  fi

  bashio::log.info "vico-cli output (first 200 chars): $(echo "${JSON_OUTPUT}" | head -c 200)"

  # Quick sanity check so we don't feed clearly non-JSON into jq
  first_char=$(printf '%s' "${JSON_OUTPUT}" | sed -n '1s/^\(.\).*$/\1/p')
  if [ "${first_char}" != "[" ] && [ "${first_char}" != "{" ]; then
    bashio::log.info "vico-cli output does not look like JSON (starts with '${first_char}'), skipping parse this cycle."
    sleep "${POLL_INTERVAL}"
    continue
  fi

  # If it's an array of events
  if echo "${JSON_OUTPUT}" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "${JSON_OUTPUT}" | jq -c 'reverse | .[]' | while read -r event; do
      CAMERA_ID=$(echo "${event}" | jq -r '.serialNumber // .deviceId // .device_id // .camera_id // .camera.uuid // .cameraId // empty')
      if [ -z "${CAMERA_ID}" ] || [ "${CAMERA_ID}" = "null" ]; then
        bashio::log.info "Event without camera/device ID, skipping. Event snippet: $(echo "${event}" | head -c 120)"
        continue
      fi

      CAMERA_NAME=$(echo "${event}" | jq -r '.deviceName // .camera_name // .camera.name // .cameraName // .title // empty')
      if [ -z "${CAMERA_NAME}" ] || [ "${CAMERA_NAME}" = "null" ]; then
        CAMERA_NAME="Camera ${CAMERA_ID}"
      fi
      EVENT_TYPE=$(echo "${event}" | jq -r '.eventType // .type // .event_type // empty')

      SAFE_ID=$(sanitize_id "${CAMERA_ID}")

      event_preview=$(echo "${event}" | tr -d '\n' | head -c 400)
      bashio::log.debug "Event for ${SAFE_ID} (${CAMERA_NAME}) type='${EVENT_TYPE}': ${event_preview}"

      ensure_discovery_published "${CAMERA_ID}" "${CAMERA_NAME}"
      publish_event_for_camera "${SAFE_ID}" "${event}"

      if [ "${EVENT_TYPE}" = "motion" ] || [ "${EVENT_TYPE}" = "person" ] || [ "${EVENT_TYPE}" = "human" ] || [ "${EVENT_TYPE}" = "bird" ]; then
        bashio::log.debug "Triggering motion pulse for ${SAFE_ID} because event type '${EVENT_TYPE}' requires it."
        publish_motion_pulse "${SAFE_ID}"
      fi
    done
  else
    # Single-event JSON object
    event="${JSON_OUTPUT}"

    CAMERA_ID=$(echo "${event}" | jq -r '.serialNumber // .deviceId // .device_id // .camera_id // .camera.uuid // .cameraId // empty')
    if [ -z "${CAMERA_ID}" ] || [ "${CAMERA_ID}" = "null" ]; then
      bashio::log.info "Single event without camera/device ID. Event snippet: $(echo "${event}" | head -c 120)"
      sleep "${POLL_INTERVAL}"
      continue
    fi

    CAMERA_NAME=$(echo "${event}" | jq -r '.deviceName // .camera_name // .camera.name // .cameraName // .title // empty')
    if [ -z "${CAMERA_NAME}" ] || [ "${CAMERA_NAME}" = "null" ]; then
      CAMERA_NAME="Camera ${CAMERA_ID}"
    fi
    EVENT_TYPE=$(echo "${event}" | jq -r '.eventType // .type // .event_type // empty')

    SAFE_ID=$(sanitize_id "${CAMERA_ID}")

    event_preview=$(echo "${event}" | tr -d '\n' | head -c 400)
    bashio::log.debug "Event for ${SAFE_ID} (${CAMERA_NAME}) type='${EVENT_TYPE}': ${event_preview}"

    ensure_discovery_published "${CAMERA_ID}" "${CAMERA_NAME}"
    publish_event_for_camera "${SAFE_ID}" "${event}"

    if [ "${EVENT_TYPE}" = "motion" ] || [ "${EVENT_TYPE}" = "person" ] || [ "${EVENT_TYPE}" = "human" ] || [ "${EVENT_TYPE}" = "bird" ]; then
      bashio::log.debug "Triggering motion pulse for ${SAFE_ID} because event type '${EVENT_TYPE}' requires it."
      publish_motion_pulse "${SAFE_ID}"
    fi
  fi

  sleep "${POLL_INTERVAL}"
done
