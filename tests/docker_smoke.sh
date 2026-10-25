#!/usr/bin/env bash
# Usage: bash tests/docker_smoke.sh IMAGE (image must already be built).
set -euo pipefail
image=${1:?image tag required}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
network="vicohome-smoke-$$"
broker="vicohome-broker-$$"
cleanup() {
  docker rm -f "$broker" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$network" >/dev/null
docker run -d --name "$broker" --network "$network" --network-alias broker \
  --entrypoint /bin/sh eclipse-mosquitto:2 -c \
  'printf "listener 1883\nallow_anonymous true\npersistence false\n" > /tmp/smoke.conf; exec mosquitto -c /tmp/smoke.conf' >/dev/null
docker run --rm -i --network "$network" --entrypoint /bin/bash "$image" -s < "$root/broker_smoke_inner.sh"
