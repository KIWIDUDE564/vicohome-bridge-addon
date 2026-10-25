# Regression checks

Run at the repository root with Python 3, Bash, and jq:

```sh
python3 -m unittest discover -s tests -v
bash -n vicohome_bridge/run.sh
bash -n vicohome_bridge/events.sh
cd vicohome_bridge/vico-cli-main
go test ./...
```

Python tests invoke the real Bash and jq delivery code with temporary persistent
ledgers and failing/successful MQTT publishers. They cover chronological ordering,
multiple cameras, first-run seeding, restart deduplication, same-time event IDs,
backlogs larger than the batch cap, expired-ID pruning, failed state/discovery
publication, malformed/empty/failed CLI results, missing event fields, bootstrap
flags, idle resets, quoted camera names, passwords, and broker selection.
Go tests cover classification/timestamps, list error/empty output contracts,
regional authentication and shared HTTP/API error handling.

Build each architecture (Docker emulation is needed on a different host platform):

```sh
docker build --platform linux/amd64 --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.19 -t vicohome:test-amd64 vicohome_bridge
docker build --platform linux/arm64 --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.19 -t vicohome:test-aarch64 vicohome_bridge
bash tests/docker_smoke.sh vicohome:test-amd64
bash tests/docker_smoke.sh vicohome:test-aarch64
```

The broker smoke test starts an isolated Mosquitto container/network, runs real
MQTT publication/subscription through the built add-on's Bash/jq/Go binaries,
then removes the test container/network. No host broker ports are exposed. It
checks bird metadata, safely quoted discovery, retained state/idle, transient
bird events, persistent dedup, process error behavior, and the real run.sh main
loop/graceful shutdown with fake cloud responses. It supplies the s6 environment
directory and fixture options in Bashio's cache; it does not start Supervisor,
exercise the normal /init sequence, or authenticate with Vicohome.

Home Assistant installation, actual camera payload variations, cloud windowing,
region credentials, template rendering, automations, TLS with your broker,
SIGKILL behavior and physical amd64/ARM64 hardware still need live validation.
