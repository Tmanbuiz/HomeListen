# Android Guardian, version 2.1.0

## What this version adds

- **Guardian:** a local microphone tap runs the bundled YAMNet detector without creating a live WebRTC microphone track. Remote live-listening requests are disabled. Starting capture always requires a tap on the home phone.
- **Live + Guardian:** the existing encrypted live-listening path with local selected-sound detection. Switching modes stops monitoring; the user must start again locally.
- Individual rules for crying, dog sounds, knocks/doorbells and loud sounds: minimum score/loudness threshold, minimum elapsed detection duration, cooldown and quiet-hours bypass. Model scores are not calibrated probabilities.
- Quiet hours in the home phone's local time. Suppressed events remain in history; queued sound retries pause during quiet hours and still expire after 15 minutes. Explicit test alerts bypass quiet hours. Equal start/end times create no quiet interval.
- Local activity with stable event IDs, category, detector score/version when available, observed analysis-window span and delivery state. Search, filters, pagination, daily counts, 1/7/30-day retention and a 500-event limit.
- JSON metadata export through Android's document picker, with no audio samples or recordings.
- An Android background-notification inbox that merges into Activity after reopening, deduplicated by event ID.
- An alert outbox capped at 50 events and 15 minutes. Retries preserve the original ID; the backend serializes concurrent attempts and retries only recipients whose provider request failed.
- Capture/detector health, recent cloud publication status and queued-alert visibility. Guardian stops if its detector fails or microphone samples stop arriving.
- Home-owned device access: caregiver, alerts only, and temporary guest (one hour, one day or seven days). The Worker and Firestore rules enforce audio restrictions and expiry; Android and browser listeners reflect them.
- An explicit **Open Oralyvo** action for a separate browser speech session. It stops monitoring on this phone first. This is a browser entry point, not a shared-auth or streaming integration.

“Accepted by push provider” does not prove the recipient displayed or read a notification. Android/iPhone notification settings and connectivity still affect delivery. Receipt retries can encounter an ambiguous provider timeout; stable notification tags reduce repeated display, but exactly-once delivery cannot be guaranteed across the push service boundary.

## Upgrade order

1. Review this branch and its automated checks.
2. Deploy `firestore.rules` and the updated Worker/viewer together using [SETUP.md](../SETUP.md). The app checks the Worker's Guardian capability flag before advertising Guardian remote alerts. An older backend leaves local Guardian running and reports the update required.
3. Install the Android APK from the successful Actions run. The first artifact targets ARM64 phones, Android 8.0 or newer. Older 32-bit phones need a separate build.
4. Choose **Home phone**, select **Guardian**, and tap **Start Guardian**. Grant microphone/notification permission and keep the ongoing notification visible.
5. Configure the same HTTPS server on both phones, pair from Devices and enable alerts on the away phone. Send a test alert from home and check Activity and the away phone separately.
6. Tune the selected sounds and quiet hours in Settings. Calibrate the room while monitoring.

Guardian defaults on for the home phone. Upgrading/relaunching does not start capture. Local detection works without a server; internet and a deployed backend are required for remote push. No new paid API, TURN relay, hosted classifier or speech provider is enabled by these changes. Oralyvo retains its own sign-in, settings, limits and provider costs.

Actions artifacts use the repository's existing preview/debug signing configuration. A different preview signing key may require uninstalling the previous build, which removes local pairing/history. Configure a persistent release signing key before distributing stable upgrades.

## Validation before unattended use

Automated API, listener, Firestore rules, Flutter model/settings/interface and Kotlin tests run in GitHub Actions. The workflow uploads the APK immediately after the ARM64 release build.

Physical-device validation is still required:

1. Run Guardian for 24–48 hours with the screen locked; inspect detector windows, microphone health, battery use and ongoing Stop action.
2. Play known crying, dog and knock/doorbell samples at several distances. Confirm alerts and document misses/false detections; this release does not claim measured detector accuracy.
3. Disconnect internet, make a selected sound, reconnect inside 15 minutes and verify a single event ID with an updated delivery status. Restart the app to verify queued metadata persists; capture must stay off until a local tap.
4. Confirm quiet hours save events without push, then test a category bypass.
5. From Android and the iPhone Home Screen app, verify Guardian and alerts-only access cannot start live audio. Expire/revoke a guest during listening; confirm the peer closes and future signaling/push fails.
6. Receive a notification while Android is backgrounded and reopen/tap it. Verify one Activity entry and export metadata without audio.
7. Switch to Live + Guardian and test the existing live-audio, Tailscale, pairing and revocation paths.

Force-stop, battery restrictions and permission removal can stop monitoring. HomeListen does not restart microphone capture after force-stop/reboot and is not an emergency alarm.
