# Home Assistant, Mosquitto and Matter

Home Listen 2.2 adds an optional MQTT 5 connection on the **home Android phone**.
It sends sound-event metadata and monitoring health to Home Assistant through
Eclipse Mosquitto. Home Assistant runs household automations and controls its
already-paired Matter devices. The connection works with Guardian and Live +
Guardian and is independent of the existing cloud push service.

No microphone audio, recording, pairing invitation or cloud credential goes over
MQTT. The MQTT password is kept separately in Android encrypted storage; broker
settings and the device identifier are ordinary app preferences. MQTT is off by
default. Turning it on, restarting the app or changing House mode does not start
microphone capture. Start monitoring by tapping the home phone.

## Set up the home hub

1. Run [Home Assistant](https://www.home-assistant.io/installation/) on an
   always-on machine at home. Existing compatible hardware can be used; this is
   separate from the Android phone. Home Assistant and Mosquitto do not require
   a subscription. Hardware, electricity and any optional remote access service
   are your own costs.
2. Install the official **Mosquitto broker** app in Home Assistant OS, or run
   [Mosquitto](https://mosquitto.org/documentation/) on your own home server.
   Create a dedicated broker account for the phone and configure Home Assistant's
   [MQTT integration](https://www.home-assistant.io/integrations/mqtt/) to use
   the same broker. MQTT discovery must be enabled; its default prefix is
   `homeassistant`.
3. On the home phone open **Settings → Home Assistant & Matter**. Turn on
   **Connect this home phone**. Enter the hub's broker hostname/IP, port and
   dedicated MQTT username/password. A Home Assistant login token is not needed.
4. Keep TLS on for port 8883 with a certificate trusted by Android. For a private
   LAN only, you can switch TLS off and use port 1883 with a private IP or `.local`
   name. A standalone private-LAN configuration and device-scoped ACL example
   are in [integrations/mosquitto](../integrations/mosquitto). Replace `DEVICE_ID`
   with the identifier shown under **Advanced setup**, and adapt permissions to
   your existing broker. These standalone files are not Home Assistant OS app
   configuration. Never forward the plaintext port to the internet.
5. Save the connection. **Broker connected** means Mosquitto acknowledged the
   connection and configuration publications; confirm the Home Listen device
   appears under Home Assistant **Settings → Devices & services → MQTT**.
   The app cannot prove that Home Assistant or a particular automation received
   an event just from a broker acknowledgement.
6. Optionally enter your Home Assistant base address, for example
   `http://homeassistant.local:8123`. **Open Home Assistant** opens that address
   using Android's installed browser/app handler.

The discovery prefix is configurable for existing installations. Use a unique
device identifier per home phone; app reinstall generates a new one. After a
broker/prefix change, remove the old Home Listen device in Home Assistant if
it is no longer needed. On clean shutdown, the phone publishes `offline`;
unexpected loss uses MQTT's retained Last Will. Force-stop and network loss can
take the broker's keepalive interval to appear, while health entities expire
independently.

## Entities and controls

| Entity | Meaning |
| --- | --- |
| Monitoring | Local capture is active |
| Microphone samples | Capture is active and samples arrived within 10 seconds |
| Sound detector | Enabled, initialized and a classification window arrived within 10 seconds |
| Battery / Charging | Last reported Android battery state |
| Monitoring mode | `guardian`, `live` or `off` |
| House mode | User-selected `home`, `away` or `night` context |
| Sound event | `crying`, `barking`, `knocking`, `loud_sound` or explicit `test` |

Health state is published approximately every 20 seconds while the app's health
timer is running. Health entities expire after 45 seconds without fresh state,
so a connected broker does not hide a stalled phone. Last Will describes a lost
MQTT session; it is not proof that the microphone or detector works. The event
entity's availability tracks the MQTT connection; its state represents the last
sound event, not current capture health.

**Allow household controls** is off by default. Enabling it adds a **Set house
mode** select and a **Stop monitoring** button. They can change automation
context or stop capture; there is no remote Start command. The transport
preserves MQTT 5's retained flag and rejects retained commands during both a
live connection and replay. Use `retain=false` for controls. Give the broker
account command-topic read permissions only if you enable these controls.

House mode is automation context. It does not change the sound classifier,
quiet-hours schedule or recording permissions. The phone's existing selected
categories, per-category rules and quiet hours apply before sound publication;
quiet hours are checked again before a queued event is sent. **Send test event**
is an explicit test and can run during quiet hours. Include `test` in an
automation only while testing it.

## Install the automations

Copy both YAML files from
[integrations/home_assistant/blueprints](../integrations/home_assistant/blueprints)
into your hub's `/config/blueprints/automation/homelisten/` directory. Reload
automations, then select the blueprint under **Settings → Automations & scenes
→ Blueprints**. If this GitHub repository is private, Home Assistant's public URL
import cannot read it; copy the files using your hub's file editor instead.

For **Home Listen - fresh sound response**:

1. Create a dedicated **Text** helper with maximum length **255**. Use a separate
   helper for every sound-response automation and leave it empty initially.
2. Select the Home Listen **Sound event** entity, sounds and House modes.
3. Select the helper and choose the response actions. For example, possible
   crying in Night can turn on a dim hallway light; knocking in Away can send a
   phone notification. Actions can target a Home Assistant scene or Matter light.
4. Select `test` temporarily and tap **Send test event**. Confirm the automation
   trace and actual response, then remove `test` if you do not need it.

The blueprint evaluates event age when its queued action runs. It discards
events older than 60 seconds, more than 30 seconds in the future, quiet events,
unselected modes/categories and IDs already in the helper. It remembers the
latest eight generated IDs across Home Assistant restarts. MQTT QoS 1 can
duplicate messages; this bounded deduplication is not an exactly-once guarantee.
The ID is recorded before household actions, so a failed action is not retried
automatically as a duplicate. Prefer repeat-safe lights, scenes and notifications.

For **Home Listen - monitoring health warning**, select the same device's
Monitoring, Microphone samples and Sound detector entities and a notification
action. Keep sound detection enabled. It warns after 45 seconds if an active
monitor becomes unavailable, or if monitoring remains on while samples or
classification stop arriving. An intentional local or remote Stop publishes
Monitoring off and does not itself trigger a failure warning. Home Assistant's
`for` timers reset when automations reload or Home Assistant restarts.

## Matter

Pair supported devices through Home Assistant's
[Matter integration](https://www.home-assistant.io/integrations/matter/) and
companion app, then select their entities in the sound-response actions.
Matter-over-Thread devices also require a Thread border router; Matter-over-Wi-Fi
devices do not require one. Check your network supports the IPv6/mDNS requirements
in Home Assistant's Matter setup guide.

Home Listen does not commission Matter devices itself and is not a certified
Matter device or Matter bridge. Home Assistant supplies the Matter controller;
MQTT sound events become inputs to its normal automations.

## MQTT contract

For identifier `DEVICE_ID`, topics are:

| Topic | Payload / retention |
| --- | --- |
| `homelisten/DEVICE_ID/availability` | `online` / `offline`, retained, QoS 1 |
| `homelisten/DEVICE_ID/state` | Health JSON, retained, QoS 1 |
| `homelisten/DEVICE_ID/events` | Fresh sound-event JSON, **never retained**, QoS 1 |
| `homelisten/DEVICE_ID/command` | Optional `stop`, non-retained |
| `homelisten/DEVICE_ID/profile/set` | Optional `home`, `away`, `night`, non-retained |
| `homeassistant/COMPONENT/hl_DEVICE_ID_ENTITY/config` | Discovery JSON, retained, QoS 1 |
| `homeassistant/status` | Home Assistant birth `online` triggers discovery/health resync |

An event contains `event_type`, `event_id`, `observed_at_ms`, `room`, `title`,
`profile`, `quiet`, `model_score`, `detector_version` and `duration_ms`. Model
scores are model outputs, not measured probabilities. Existing cloud push retry
behavior is separate; the smart-home queue is limited to 50 events, kept only in
memory, and expires at 60 seconds. Stop, clearing local activity or changing the
broker discards unsent MQTT events. Previously sent household actions cannot be
undone by Stop. A restart never restores the MQTT action queue. Home Assistant
or your broker may retain its own logs/history under your hub's retention policy.

## Verify on your hardware

Start Guardian locally, confirm microphone/detector health turns on, and test each
selected sound using real examples from the room. Verify screen-off operation,
Wi-Fi loss/recovery, Home Assistant restart, Stop, quiet hours and a controlled
Matter light response. The CI checks cover authenticated MQTT 5, retained
discovery, non-retained events and commands; they do not measure real-room
classification accuracy or replace physical Android/Matter testing.
