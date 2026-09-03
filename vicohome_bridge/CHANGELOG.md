# Vicohome Bridge Add-on Changelog

## 2.1.0
- Fixed a crash loop on active cameras: the main poll loop now publishes only **new** events instead of re-listing and re-publishing the entire recent window every cycle. Previously a busy camera (e.g. a bird feeder with a few hundred events/day) caused hundreds of `mosquitto_pub` calls and motion-pulse subshells per poll, which could get the add-on OOM-killed; when that happened every entity went `unavailable` even though the camera was online.
- Added a persisted de-duplication store at `/data/published_events` (a bounded list of already-published event ids, `traceId` with a timestamp+serial fallback). It survives restarts and add-on updates.
- Added safe first-run seeding: on the very first poll with no state, the add-on records every event currently in the window as already-seen and publishes only the most recent one, so a fresh install / restart with a full backlog no longer floods MQTT.
- Added a `MAX_PUBLISH_PER_POLL` safety cap (60) so even an unexpected surge of new events can't blast MQTT in a single cycle; the remainder publish on subsequent polls.
- Refactored the duplicated per-event publish logic into a single `process_event` function shared by the main loop and the history bootstrap, and removed dead code that called an undefined `bootstrap_history_if_needed`.

## 2.0.0
- Added region-aware API routing so the add-on and bundled `vico-cli` can call the Vicohome EU or US endpoints (or auto-select the default) without manual code edits.
- Exposed `region` and `api_base_override` configuration options and plumbed them through the runtime environment so every CLI command, telemetry poll, and motion pull honors the selected geography.

## 1.2.2
- Extended the bootstrap history pull to cover the last 5 days of Vicohome activity so Last Event sensors populate even when your account has been idle for more than a day.

## 1.2.1
- Reworked the bootstrap history fallback to use an in-memory flag and replay the last 24 hours of Vicohome events whenever `vico-cli` reports no recent motion, ensuring the normal MQTT workflows run even during the bootstrap phase.

## 1.2.0
- Added an optional bootstrap history pull that backfills the most recent event per camera when Vicohome reports no recent activi
ty, so the Last Event sensors populate even before new motion occurs.
- Provided a `bootstrap_history` configuration toggle (default `true`) and persisted per-camera markers so the historical publish
ing only runs once per install unless you disable/delete the data files.

## 1.1.9
- Added an automatic MQTT discovery refresh (every ~5 minutes) so Home Assistant recreates Vicohome entities if you delete them or when payloads change over time.
- Logged the discovery refresh reason to the add-on log for easier troubleshooting when sensors appear to lag behind changes.

## 1.1.8
- Fixed a regression where the telemetry publisher could crash with an `online_json` error when Vicohome omitted status flags, ensuring the add-on keeps running even with sparse device data.
- Added detailed debug logging for telemetry and events (and documented how to enable it) so troubleshooting stalled updates is much easier.

## 1.1.7
- Added a retained MQTT availability topic and wired every discovery payload to it so Home Assistant marks the entities unavailable whenever the add-on goes offline.

## 1.1.6
- Fixed the Last Event sensor discovery template so it also recognizes `event_type` payloads, ensuring Home Assistant always shows the motion type regardless of the JSON casing Vicohome uses.

## 1.1.5
- Improved the telemetry publisher so it recognizes more battery and Wi-Fi signal fields from Vicohome payloads and always forwards that data to Home Assistant.
- Added missing trailing newlines to repository metadata and the main run script to avoid formatting diffs when packaging the add-on.

## 1.1.4
- Fixed a bash runtime error when telemetry payloads arrived without an explicit `online` field by ensuring the fallback logic
  always initializes the variable before use.

## 1.1.3
- Added explicit changelog metadata so Home Assistant shows release notes in the add-on store.
- Documented the telemetry and MQTT discovery improvements introduced in this release.
- Fixed repository metadata to point to the real project home.

## 1.1.2
- Initial release of the add-on.
