# Vicohome multiarch stability implementation plan

Goal: reliable amd64/aarch64 builds and bounded, restart-safe MQTT polling, preserving Bash + vico-cli and existing v3 entity IDs.
Spec: user handoff dated 2026-10-25. Live video and galleries excluded. Work only on fix/multiarch-stability; push to tomkennedy513, never upstream/main. One commit per logical fix, no attribution trailers; preserve upstream credits.

## Design
Use native platform Docker builder stages and a global BUILD_FROM argument. Retain Bash orchestration and jq JSON handling. Use an atomic JSON delivery ledger under /data: persistent initial cutoff, time-bounded event IDs, per-camera latest timestamp. Seed only latest state per camera for historical events. Cap each publication batch at 60, process chronologically, and acknowledge only successful QoS 1 publications. Motion resets are tracked per camera by the single polling process, with HA off_delay as a fallback. MQTT discovery is JSON encoded and retained; external broker settings override Supervisor discovery.

## Tasks (each includes red test, implementation, green suite, one final commit)
- [x] Build: Dockerfile/build.yaml/config.yaml and native CI matrix; validate architecture agreement and binary smoke checks. Checkpoint attachment unavailable; reconstruct described equivalent.
- [x] CLI: list RunE errors, JSON [] on empty, event type preservation/default, UTC timestamps, request timeouts. Go regression tests against local HTTP server and command handlers.
- [x] Delivery: run.sh plus event jq helper; durable dedup, chronological ordering, latest per camera, bounded history/live batches, safe motion resets. Regression tests exercise real Bash functions with fake CLI/MQTT and temporary persistent data.
- [x] MQTT: optional external config, array arguments, retained safely encoded discovery/state/telemetry, retry discovery failures and periodic availability. Test quoted names/passwords and publication flags.
- [x] Release: fork metadata/install URLs, 2.1.0 changelog, delivery guarantees and limitations. Run full Go, Bash, regression, Docker amd64/arm64 builds/smokes, review final diff/history and push fork branch.

## Review focus
MQTT partial success/crash before ledger commit can duplicate delivery; document at-least-once behavior. Retained online is no persistent LWT. Cutoff suppresses historical automations including first startup and downtime older than freshness threshold. Corrupt ledger must fail closed rather than replay. Late events must not regress state. Tests must cover same timestamps, malformed JSON, failed initialization, large backlog and bootstrap arguments.


## Verification record
- Existing and added Go tests passed locally (regional auth, list JSON/errors, classification/timestamp variants, HTTP/API failures).
- 22 Python regressions passed, including empty IDs, a 50,000-ID ledger, nested corruption, same-time IDs, large multi-camera history and restart-safe delivery.
- Final Docker builds passed for linux/amd64 (emulated on ARM64 host) and linux/arm64. Real isolated-broker smoke tests passed on both images, including Bashio fixture option parsing, run.sh polling with a fake CLI, and graceful offline shutdown.
- YAML architecture and option/schema consistency, Bash syntax, and diff whitespace checks passed.
- Independent read-only review found three delivery defects (empty IDs, oversized argv ledger, nested corrupt records); each received a failing regression and passing fix. Real broker checks caught an unsupported mosquitto_pub timeout flag; BusyBox timeout now bounds the publisher.
- Live Supervisor API/options retrieval, HA template rendering, Vicohome credentials/regional hardware, private broker TLS and cloud event completeness remain unverified. No persistent MQTT Last Will is claimed.
- User clarified bird-camera priority and approved finishing this fork as a checkpoint before a future bird-specific repository.
