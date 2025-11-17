# Vicohome Bridge Add-on for Home Assistant

Repo: <https://github.com/KIWIDUDE564/vicohome-bridge-addon>

> ⚠️ **Unofficial integration.**  
> This add-on is just a thin wrapper around the excellent open-source
> [`vico-cli`](https://github.com/dydx/vico-cli) project by **dydx**.  
> It is **not** affiliated with Vicohome or the vico-cli author.

The Vicohome Bridge add-on uses `vico-cli` + MQTT to bring your **Vicohome cameras** into Home Assistant.

It:

- Logs into Vicohome with `vico-cli`
- Polls the cloud for **events + device info**
- Publishes JSON events and camera attributes to MQTT
- Uses **MQTT Discovery** to auto-create entities for each camera
- Provides a simple **dashboard** with last-event thumbnails and camera health

Tested on:

- Home Assistant OS (aarch64 / Raspberry Pi)

---

## Strongly recommended account setup

For safety and sanity:

1. Keep your existing Vicohome account as your **main account**.
2. Create a **new “bridge” account** in the Vicohome app (e.g. `homeassistant_bridge@example.com`).
3. From the main account, **share all cameras** to the bridge account.
4. Use **only** the bridge account credentials in this add-on.

This keeps your main login out of Home Assistant and also makes it easy to revoke/remove access later if needed.

---

## Features

For each Vicohome camera the add-on creates:

- `sensor.vicohome_<cam>_last_event`  
  - JSON attributes: `timestamp`, `imageUrl`, `videoUrl`, `eventType`, `serialNumber`, `deviceName`, etc.
- `binary_sensor.vicohome_<cam>_motion`
- `sensor.vicohome_<cam>_battery` (percentage)
- `sensor.vicohome_<cam>_wifi` (signal dBm)
- `binary_sensor.vicohome_<cam>_online`

Plus:

- Motion pulses (`ON` → short delay → `OFF`) for automations
- Base MQTT topic configurable (default `vicohome`)
- Polling interval configurable (default 60s)

---

## Requirements

- **Home Assistant OS** or **Supervised** (add-on support required)
- **MQTT broker** available to Home Assistant  
  Recommended: the official **Mosquitto broker add-on** (`core-mosquitto`)
- A **Vicohome bridge account**  
  - Created in the Vicohome app
  - Cameras are **shared** to this account from your main Vicohome account

Optional (for the dashboard):

- **HACS** installed
- `config-template-card` installed via HACS  
  (used to render the dynamic markdown dashboard)

---

## Installation

### 1. Add the add-on repository

In Home Assistant:

1. Go to **Settings → Add-ons → Add-on Store**.
2. Click the **⋮ menu → Repositories**.
3. Add this repo URL:

   ```text
   https://github.com/KIWIDUDE564/vicohome-bridge-addon
   ```

4. Click **Add**, then **Close**.

You should now see **“Vicohome Bridge”** in the add-on list.

---

### 2. Install the Vicohome Bridge add-on

1. In **Add-on Store**, click **Vicohome Bridge**.
2. Click **Install**.
3. After installation, go to the **Configuration** tab and fill in:

   - `email` – **bridge Vicohome account** email  
     (the one you shared your cameras to, *not* necessarily your main login)
   - `password` – bridge account password
   - `poll_interval` – how often to poll for events (seconds)
   - `base_topic` – MQTT base topic (default: `vicohome`)
   - `log_level` – `debug`, `info`, `warning`, `error` (default: `info`)

   Example:

   ```json
   {
     "email": "homeassistant_bridge@example.com",
     "password": "YOUR_PASSWORD_HERE",
     "poll_interval": 60,
     "base_topic": "vicohome",
     "log_level": "info"
   }
   ```

4. Click **Save**.
5. On the **Info** tab, enable:
   - **Start on boot**
   - **Watchdog**
6. Click **Start**.

---

### 3. Ensure MQTT is configured

The add-on uses Supervisor **service discovery** to find your MQTT broker.

You should have:

1. The **Mosquitto broker** add-on installed and running, **or**
2. Another MQTT broker exposed to Home Assistant as a “MQTT” service.

Then:

1. Go to **Settings → Devices & Services**.
2. Add / configure the **MQTT integration** and point it to your broker.
3. Once MQTT is working, the Vicohome Bridge logs should show something like:

   ```text
   [INFO] Using MQTT broker at core-mosquitto:1883, base topic: vicohome
   ```

No manual host/port config is needed in the add-on; it grabs them from the MQTT service automatically.

---

### 4. Verify that entities are created

After the add-on has been running for a bit:

1. Go to **Settings → Devices & Services → MQTT → Devices**.
2. You should see one device per Vicohome camera, e.g.:

   - `Vicohome Front Driveway`
   - `Vicohome Mid Driveway`
   - `Vicohome Front porch`
   - `Vicohome Generator Shed`
   - `Vicohome Driveway Parking Area`

Each device should contain:

- `Last Event` (sensor)
- `Motion` (binary_sensor)
- `Battery` (sensor)
- `WiFi` (sensor)
- `Online` (binary_sensor)

You can also check via **Developer Tools → States** and search for `vicohome`.

---

## Entities & Topics

By default the add-on:

- Publishes per-camera JSON events to:
  - `vicohome/<safe_camera_id>/events`
  - `vicohome/<safe_camera_id>/state`
  - `vicohome/<safe_camera_id>/motion` (`ON`/`OFF`)
  - `vicohome/<safe_camera_id>/telemetry` (battery/WiFi/online details)

- Registers MQTT Discovery entries for:

  - `sensor.vicohome_<camera>_last_event`
  - `binary_sensor.vicohome_<camera>_motion`
  - `sensor.vicohome_<camera>_battery`
  - `sensor.vicohome_<camera>_wifi`
  - `binary_sensor.vicohome_<camera>_online`

Where `<camera>` is a normalized ID (lowercase, non-alphanumerics replaced with `_`).

The **Last Event** sensor exposes attributes such as:

- `timestamp`
- `imageUrl` (signed thumbnail URL)
- `videoUrl` (M3U8 link)
- `eventType`
- `deviceName` / `serialNumber`
- and other fields from the Vicohome API.

All of this data ultimately comes from `vico-cli` – this add-on just forwards and reshapes it.

---

## Optional: Vicohome dashboard

This dashboard gives you:

- A **Last Events** card with one block per camera:
  - Friendly name
  - “Last event: X minutes ago” + local timestamp
  - Event type
  - Thumbnail image
  - “Watch clip” link, when available
- A **Camera Health** card per camera:
  - Online/Offline
  - Battery %
  - WiFi dBm
  - Last event age & timestamp

### Prerequisites

- [HACS](https://hacs.xyz/) installed
- `config-template-card` installed from HACS:
  - HACS → Frontend → `+` → search `Config Template Card`

Make sure `config-template-card` is **added as a resource** (HACS usually does this automatically).

### Add the dashboard

1. Go to **Settings → Dashboards**.
2. Click **Add Dashboard**.
3. Name it e.g. `Vicohome`.
4. Open that new dashboard → **⋮ → Edit dashboard → ⋮ → Raw configuration editor**.
5. Replace everything with:

```yaml
title: Vicohome
views:
  - title: Vicohome
    path: vicohome
    icon: mdi:cctv
    cards:
      # ==============================
      # Card 1: Last events + thumbnails
      # ==============================
      - type: custom:config-template-card
        entities:
          - sun.sun
        card:
          type: markdown
          title: Vicohome Last Events
          content: >
            {% set sensors = states.sensor
                 | selectattr('entity_id', 'search', '^sensor\.vicohome_.*_last_event$')
                 | list %}

            {% if not sensors %}
            _No Vicohome cameras found yet. Make sure the Vicohome Bridge add-on is running and events have been pulled._
            {% endif %}

            {% for s in sensors %}
            {% set raw_name = s.name %}
            {% set cam_name = raw_name | replace(' Last Event', '') %}

            {% set ts  = state_attr(s.entity_id, 'timestamp') %}
            {% set img = state_attr(s.entity_id, 'imageUrl') %}
            {% set vid = state_attr(s.entity_id, 'videoUrl') %}
            {% set etype = state_attr(s.entity_id, 'eventType') or state_attr(s.entity_id, 'type') %}

            {% if ts %}
              {% set ts_local = as_timestamp(ts) | as_datetime | as_local %}
              {% set ts_rel = ts_local | relative_time %}
            {% else %}
              {% set ts_local = None %}
              {% set ts_rel = 'No events yet' %}
            {% endif %}

            {% if not loop.first %}
            ---
            {% endif %}

            ### {{ cam_name }}

            **Last event:** {{ ts_rel }}
            {% if ts_local %}_ ({{ ts_local }})_{% endif %}

            {% if etype %}
            **Type:** `{{ etype }}`
            {% endif %}

            {% if img %}
            ![thumb]({{ img }})
            {% else %}
            _No image available_
            {% endif %}

            {% if vid %}
            [▶ Watch clip]({{ vid }})
            {% endif %}

            {% endfor %}

      # ==============================
      # Card 2: Camera health overview
      # ==============================
      - type: custom:config-template-card
        entities:
          - sun.sun
        card:
          type: markdown
          title: Vicohome Camera Health
          content: >
            {% set sensors = states.sensor
                 | selectattr('entity_id', 'search', '^sensor\.vicohome_.*_last_event$')
                 | list %}

            {% if not sensors %}
            _No Vicohome cameras found yet._
            {% endif %}

            {% for s in sensors|sort(attribute='name') %}
            {% set raw_name = s.name %}
            {% set cam_name = raw_name | replace(' Last Event', '') %}

            {% set batt_id   = s.entity_id | replace('_last_event', '_battery') %}
            {% set wifi_id   = s.entity_id | replace('_last_event', '_wifi') %}
            {% set online_id = s.entity_id
                               | replace('sensor.', 'binary_sensor.')
                               | replace('_last_event', '_online') %}

            {% set batt   = states(batt_id) %}
            {% set wifi   = states(wifi_id) %}
            {% set online = states(online_id) %}

            {% set ts  = state_attr(s.entity_id, 'timestamp') %}
            {% if ts %}
              {% set ts_local = as_timestamp(ts) | as_datetime | as_local %}
              {% set ts_rel   = ts_local | relative_time %}
              {% set last_str = ts_rel ~ ' (' ~ ts_local ~ ')' %}
            {% else %}
              {% set last_str = 'No events yet' %}
            {% endif %}

            {% if not loop.first %}
            ---
            {% endif %}

            ### {{ cam_name }}

            **Status:** {% if online == 'on' %}✅ Online{% elif online == 'off' %}❌ Offline{% else %}Unknown{% endif %}

            **Battery:** {% if batt in ['unknown', 'unavailable', ''] %}Unknown{% else %}{{ batt }}%{% endif %}

            **WiFi:** {% if wifi in ['unknown', 'unavailable', ''] %}Unknown{% else %}{{ wifi }} dBm{% endif %}

            **Last event:** {{ last_str }}

            {% endfor %}
```

6. Click **Save**, then exit edit mode.

---

## Troubleshooting

### 1. No Vicohome entities show up

**Symptoms:**

- Searching `vicohome` in Developer Tools → States shows nothing
- MQTT integration has no “Vicohome …” devices

**Check:**

1. Add-on logs (Vicohome Bridge → **Log**):

   - Verify `Vicohome Bridge configuration:` prints your settings.
   - You should see something like:

     ```text
     Using MQTT broker at core-mosquitto:1883, base topic: vicohome
     Running initial device discovery via 'vico-cli devices list --format json'...
     Ensuring discovery for device 'Front Driveway' (a628237d...)
     ```

   - If you see an error like `You must set 'email' and 'password'`, fix the config.

2. Confirm the **MQTT integration** is configured and working
   - Try publishing a test message using Developer Tools → MQTT.

3. Make sure your **bridge Vicohome account** actually sees the cameras.
   - Open the Vicohome app while logged in as the bridge account and confirm all cameras appear.
   - If not, log in with your main account and ensure all cameras are **shared** to the bridge user.

---

### 2. MQTT “not authorised” / `received null username or password`

If Mosquitto logs show:

```text
error: received null username or password for unpwd check
Client core-mosquitto.Vicohome disconnected, not authorised.
```

Then:

- Your Mosquitto broker requires authentication, but the Supervisor **MQTT service** is not exposing credentials correctly, or you misconfigured the MQTT integration.

Fix:

1. Ensure the MQTT integration is connected to the same broker as the Mosquitto add-on and using valid credentials.
2. Restart:
   - Mosquitto broker
   - MQTT integration (Configure → Reload)
   - Vicohome Bridge add-on

The bridge uses the credentials provided by `bashio::services mqtt`.

---

### 3. Cameras exist but no events / thumbnails

**Symptoms:**

- `sensor.vicohome_*_last_event` exists, but:
  - `timestamp` attribute is missing or `Unknown`
  - `imageUrl` is empty
  - Dashboard shows “No events yet / No image available”

Possible causes:

1. The **bridge account** has not recorded events yet  
   - When you first switch to a new bridge account, Vicohome may only start tracking events from that account’s perspective.
   - Wait for new motion events or trigger motion in front of the camera.

2. `vico-cli events list --format json` returns empty on the backend  
   - Check the add-on logs: they will show the first 200 chars of the events JSON each poll.
   - If Vicohome is rate-limiting or returning non-JSON, the log will say so.

---

### 4. Some cameras missing, or duplicate/ghost entities

If you changed the add-on version or discovery IDs at some point, Home Assistant may still have **old** MQTT entities.

Fix:

1. Stop the **Vicohome Bridge** add-on.
2. Go to **Settings → Devices & Services → MQTT → Devices**.
3. For each device whose name starts with **Vicohome**:
   - Click it → **⋮ → Delete device**.
4. Reload the MQTT integration (Configure → Reload).
5. Start the **Vicohome Bridge** add-on again.

It will republish discovery with the current IDs, and HA will create fresh entities.

---

### 5. Dashboard errors: “Configuration error / No entities defined”

This usually means **config-template-card** is not installed or not configured as a resource.

Fix:

1. Install **Config Template Card** via HACS:
   - HACS → Frontend → `+` → search `Config Template Card`.
2. Restart Home Assistant or reload Lovelace resources.
3. Ensure the card type in YAML is exactly:

   ```yaml
   type: custom:config-template-card
   ```

4. Make sure each card has an `entities:` block with at least one entity (e.g. `sun.sun`).

---

## Credits

- Huge thanks to **[@dydx](https://github.com/dydx)** for creating and maintaining
  [`vico-cli`](https://github.com/dydx/vico-cli) – this add-on is basically
  “`vico-cli` + MQTT + Home Assistant glue.”
- Vicohome Bridge add-on + dashboard by the community (feel free to fork, tweak, and PR).

Issues / ideas / PRs welcome!
