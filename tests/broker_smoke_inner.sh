#!/usr/bin/env bash
set -e
source /run.sh
bashio::log.warning() { printf '%s\n' "$*" >&2; }
bashio::log.debug() { :; }
DATA_DIR=/tmp/vicohome-smoke
mkdir -p "$DATA_DIR"
BASE_TOPIC=vicohome
AVAILABILITY_TOPIC=vicohome/bridge/status
MQTT_ARGS=(-h broker -p 1883 )
DISCOVERY_SESSION=smoke
DISCOVERY_REFRESH_SECONDS=300
BRIDGE_NOW=$(date +%s)
# Wait for the isolated test broker, at most ten seconds.
for attempt in {1..10}; do
  if mqtt_publish "${MQTT_ARGS[@]}" -t test/ready -m ready 2>/dev/null; then break; fi
  sleep 1
done
init_event_store
old=$(jq -nc --argjson ts "$((BRIDGE_NOW - 10))" '[{serialNumber:"BirdCam",deviceName:"Feeder \"Garden\"",traceId:"old",timestamp:$ts,eventType:"bird",birdName:"Robin"}]')
process_events "$old" history
state=$(mosquitto_sub -h broker -t vicohome/birdcam/state -C 1 )
jq -e '.traceId == "old" and .birdName == "Robin"' <<< "$state" >/dev/null
config=$(mosquitto_sub -h broker -t homeassistant/sensor/vicohome_camera_v3_birdcam_last_event/config -C 1 )
jq -e '.device.name == "Vicohome Feeder \"Garden\""' <<< "$config" >/dev/null
[ "$(mosquitto_sub -h broker -t vicohome/birdcam/motion -C 1 )" = OFF ]
# Subscribe before a fresh bird event; transient event-stream delivery must arrive.
mosquitto_sub -h broker -t vicohome/birdcam/events -C 1 -W 5 > /tmp/bird-event &
listener=$!
sleep 1
live=$(jq -nc --argjson ts "$((BRIDGE_NOW + 1))" '[{serialNumber:"BirdCam",deviceName:"Feeder \"Garden\"",traceId:"new",timestamp:$ts,eventType:"bird",birdName:"Robin"}]')
process_events "$live" live
wait "$listener"
jq -e '.traceId == "new" and .eventType == "bird"' /tmp/bird-event >/dev/null
# Reopening the durable store and replaying a batch must leave it unchanged.
before=$(cat "$EVENT_STORE")
init_event_store
process_events "$live" live
[ "$before" = "$(cat "$EVENT_STORE")" ]
BRIDGE_NOW=$((BRIDGE_NOW + 10))
reset_motion
[ "$(mosquitto_sub -h broker -t vicohome/birdcam/motion -C 1 )" = OFF ]
state=$(mosquitto_sub -h broker -t vicohome/birdcam/state -C 1 )
jq -e '.traceId == "new"' <<< "$state" >/dev/null
# Real process failure: no credentials must produce nonzero status and no JSON stdout.
if output=$(vico-cli events list --format json 2>/tmp/cli-error); then exit 1; fi
[ -z "$output" ]
printf 'Bird event delivery, retained discovery/state/idle, restart dedup and CLI errors passed.\n'
# Exercise the run.sh entrypoint/config parsing/poll loop with a fake cloud CLI.
# This helper container bypasses /init, so supply its normally-created s6 env directory.
mkdir -p /data /run/s6/container_environment
cat > /data/options.json <<'JSON'
{"email":"test@example.invalid","password":"test-only","mqtt_host":"broker","mqtt_port":1883,"mqtt_username":"","mqtt_password":"","mqtt_tls":false,"poll_interval":5,"base_topic":"vicoruntime","log_level":"info","bootstrap_history":false,"region":"us","api_base_override":"https://cloud.invalid"}
JSON
cat > /tmp/fake-vico-cli <<'SH'
#!/usr/bin/env bash
if [ "$1" = devices ]; then
  echo '[]'
else
  jq -nc --argjson ts "$(date +%s)" '[{serialNumber:"BirdCam",traceId:"startup",timestamp:($ts-1),eventType:"bird",birdName:"Blackbird"}]'
fi
SH
chmod +x /tmp/fake-vico-cli
# Bashio fetches options from Supervisor; populate its cache with the fixture.
source /usr/lib/bashio/bashio.sh
bashio::cache.set addons.self.options.config "$(cat /data/options.json)"
printf '%s' /tmp/fake-vico-cli > /run/s6/container_environment/VICO_CLI
startup_start=$(date +%s)
/run.sh > /tmp/bridge-startup.log 2>&1 &
bridge_pid=$!
if ! state=$(mosquitto_sub -h broker -t vicoruntime/birdcam/state -C 1 -W 45); then
  cat /tmp/bridge-startup.log
  cat /tmp/vico_events_error.log /tmp/vico_devices_error.log /data/delivery.json 2>/dev/null || true
  kill "$bridge_pid" 2>/dev/null || true
  exit 1
fi
printf 'Startup state received after %ss.\n' "$(( $(date +%s) - startup_start ))"
jq -e '.eventType == "bird" and .birdName == "Blackbird"' <<< "$state" >/dev/null
kill -TERM "$bridge_pid"
wait "$bridge_pid"
[ "$(mosquitto_sub -h broker -t vicoruntime/bridge/status -C 1 -W 5)" = offline ]
printf 'Actual add-on entrypoint, options parsing, cloud-CLI polling and graceful offline passed.\n'
