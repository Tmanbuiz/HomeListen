# Optional alert recordings

On the receiving Android phone, iPhone/iPad app, or web listener, select the sounds you want to record. Recording is off unless its checkbox is selected. Crying defaults to 30 seconds. Per-sound recording durations can extend to five minutes. Keep live listening connected before the episode starts.

The home phone's alert rules determine remote push timing. A receiver's recording duration determines which local clips it keeps; changing it does not remotely reconfigure the home phone. Set the crying rule to 30 seconds on the home phone for 30-second push alerts.

The home detector preserves the crying-alert timer through brief competing classifications, such as a knock, when matching crying detections resume within two seconds. Two seconds without matching crying starts a new timer. Coughing and dog-sound push alerts need two distinct detection runs within eight seconds; one continuous run of overlapping classifications does not count as two sounds. These push rules are separate from the receiver's recording-duration setting.

The receiver buffers the first analysis window and the detected episode while waiting for the selected duration. Short candidates are discarded. Qualifying episodes continue recording until roughly two seconds without a matching detection. Duration is an estimate from captured samples and classification windows, not a medical measurement. Brief pauses can belong to the same episode. The classifier currently selects one category per window, so overlapping sound types may split episodes.

Files use the receiving device's local date/time and sound name, for example `2026-10-22_01-30-00-000_crying_1.wav`. Milliseconds and a suffix prevent collisions. Open Activity on mobile to save/share or delete clips. The web listener includes playback, download and delete controls. Native clips remain in private app storage until exported; browser clips stay in that browser's IndexedDB. Audio never enters Firebase or the Worker backend and no clips are saved on the home phone. Opted-in mobile candidates use a private temporary file until they qualify; abandoned candidates are deleted on the next launch.

Cloud recording audio travels through an additional encrypted WebRTC datachannel inside the same authorized live session. The channel subscribes only when a receiving device selects recording. This adds about 32 KB/s per subscribed receiver, in addition to the ordinary live audio; TURN relay usage may therefore increase. Expired guests, alerts-only members, stopped sharing and revocation retain the same session access restrictions. In Tailscale mode the native receiver records the PCM already arriving for playback.

Cloud receivers need an updated Android home app in **Live + Guardian**, with sound detection and the desired category enabled there. An iPhone home phone in cloud Guardian mode sends alerts only; it cannot provide live or recording audio. Both native receivers and the web listener can receive from a supported home source. An older home app can still play live audio but does not send the recording channel.

Stop, disconnection, loss of live access or recording-setting changes finish qualified clips and discard short candidates. Lost audio splits episodes rather than silently joining disconnected sessions. Long clips split at ten minutes. Native retention follows the selected 1/7/30-day setting; the web keeps seven days. Both cap storage at 100 clips or 200 MB. Browser storage may be evicted; download important clips. Clearing event history and deleting audio are separate actions.

Keep the receiving app/page active. Browsers and iOS may suspend background work, and force-stop ends receiving. An alerts-only or disconnected receiver cannot record audio, and a later push cannot recover earlier sound. Test locked-screen behavior on actual devices. Possible coughing and crying are sound classifications, not diagnoses or emergency alarms.

## Validation before release

- With recording unchecked, verify that no temporary PCM or WAV clip is created.
- Start receiving before a known cry sample; verify no clip is kept below 30 seconds and the full detected episode is saved above the threshold.
- Confirm each selected recording duration is honored and brief pauses behave consistently. Separately, verify that two distinct coughs trigger a home alert and one sustained detection does not.
- Check filenames, correct WAV duration, native export and browser playback/download/delete.
- Disconnect/reconnect, Stop, switch to alerts-only, revoke access and expire a guest while recording; no clip may join separate sessions.
- Test Android, iPhone, iPad and Safari/Chrome web listeners with physical audio and background/locked-screen transitions.
