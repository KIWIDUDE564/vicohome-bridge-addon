# Vicohome Bridge Add-on Changelog

## 2.1.0
- Build native amd64 and aarch64 images using architecture-specific Home Assistant bases and test both in CI.
- Preserve CLI event classification, normalize timestamps to UTC, return JSON arrays for empty lists, and fail correctly on authentication, API, HTTP, and parsing errors.
- Persist chronological event deduplication across restarts, cap live/history work, and seed only latest state per camera without historical motion. Failed publications remain retryable; partial failures may duplicate messages.
- Replace per-event background motion processes with tracked deadlines and Home Assistant off-delay; retain discovery, state, telemetry, and idle OFF.
- Encode camera names safely, guard missing template fields, retry failed discovery, and preserve existing v3 entity identities.
- Add optional external MQTT host/port/credentials/TLS while retaining Supervisor discovery; pass MQTT arguments safely.
- Point installation metadata at tomkennedy513's fork while crediting KIWIDUDE564 and dydx/vico-cli. Document delivery, availability, API-window and live-validation limits.

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
