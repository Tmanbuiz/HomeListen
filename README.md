# Home Listen

Guardian sound alerts and optional live sound from the Android phone you leave at home. Listen on another Android phone, the Home Listen iPhone app, or the iPhone Home Screen web app. Built by WianTribe.

This new repository builds on the owner's [PhoneListen](https://github.com/Tmanbuiz/PhoneListen) app, retaining its Tailscale mode and local YAMNet sound detector.

## Included

- Android **Guardian** mode with local sound detection and live listening disabled; **Live + Guardian** retains live audio. Capture starts locally, with a visible microphone notification and **Stop** action.
- Encrypted WebRTC live audio, anonymous Firebase identity and private Firestore signaling.
- QR/link invitations expiring after 10 minutes, up to five paired listening phones, and revocation at home.
- Optional second way in: a pairing link joins, or so does the home secret answer plus a 6-digit code from an authenticator app (Google/Microsoft Authenticator, Authy), with no link. The answer finds the home, the code proves it is you. Codes are single-use, and five wrong codes lock that way in for 10 minutes. Turn it on in Devices on the home phone; turning it off needs a code. A leaked link alone still joins, so keep links private.
- Local detection of possible crying, dog sounds, knocks/doorbells and loud sounds, with per-category rules, quiet hours and cooldowns. Only alert metadata reaches the backend; no audio recordings are saved.
- Searchable event history, daily counts, configurable retention, JSON export and retry status. A bounded outbox retries failed push requests using stable event IDs.
- Caregiver, alerts-only and expiring guest access, enforced by the API and Firestore rules.
- Android FCM and iPhone Home Screen Web Push, including alerts without a live audio connection.
- Cloudflare Worker API and web listener on one HTTPS address.
- Optional Tailscale mode for native Android/iOS listening.
- Optional Home Assistant integration through MQTT 5/Mosquitto, with sound events, separate capture/detector health, House modes and an opt-in remote Stop. Matter devices respond through Home Assistant automations; setup and ready-to-copy blueprints are in [Smart home](docs/SMART_HOME.md).
- Automated API, listener, rules, Flutter interface and protocol checks; GitHub Actions produces Android APK artifacts.

Credentials are blank. Follow [SETUP.md](SETUP.md) to deploy your server and enter its address in the app.

See [Android Guardian](docs/ANDROID_GUARDIAN.md) for the 2.1.0 upgrade order, feature details, Oralyvo browser entry point and physical-device checks.

## Can it run for free?

Personal use can fit these current free quotas. Relay usage has an optional paid tier:

| Service | Verified allowance | Purpose |
| --- | --- | --- |
| Firebase Spark | Firestore 50,000 reads/day, 20,000 writes/day, 20,000 deletes/day, 1 GiB stored, 10 GiB/month outbound | Pairing, status and short-lived signaling |
| Firebase FCM | No charge | Android alerts |
| Cloudflare Workers Free | 100,000 requests/day, 10 ms CPU/request | API and cleanup |
| Cloudflare static assets | Free, unlimited asset requests | Web listener |
| Cloudflare STUN | Free | Direct WebRTC |
| Optional Cloudflare TURN | First 1,000 GB/month shared with SFU; then $0.05/GB egress | Relay across restrictive networks |
| iPhone Web Push | iOS 16.4+; no Apple Developer membership | Home Screen alerts |

The home phone sends one heartbeat per minute while sharing: approximately 1,440 writes per 24 hours. Open apps read status changes. Signaling, security-rule reads, reconnects, alerts and cleanup add usage. Monitor Firebase and Cloudflare dashboards; this does not promise unlimited free service.

**TURN is off by default.** Direct audio can fail across mobile networks or restrictive Wi-Fi. Review relay billing before enabling it, or choose Tailscale mode.

No Cloud Functions, Cloud Run, hosted classifier or paid Firestore TTL is required. Worker cron cleanup uses ordinary deletes.

Primary sources, checked 8 October 2026:

- [Firebase quotas](https://firebase.google.com/docs/firestore/quotas) and [Spark/FCM](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/) and [assets](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)
- [Realtime pricing](https://developers.cloudflare.com/realtime/sfu/platform/pricing/) and [TURN credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/)
- [WebKit: iPhone Web Push](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)

## Use

1. Deploy using [SETUP.md](SETUP.md).
2. Install the Android APK on the home phone. Choose **This phone stays at home**.
3. In **Settings → Configure connection**, choose Cloud and enter the HTTPS Worker address.
4. In Devices, show the pairing code. Choose Guardian or Live + Guardian and start monitoring locally.
5. On Android away, configure the same server and scan the code. Choose listening or alerts only.
6. On iPhone, add the server page to the Home Screen first. Open its icon, paste a fresh pairing link, then choose **Enable alerts**. **Listen live** is available when the home phone is in Live + Guardian and your access permits it.
7. Select sound categories and rules at home, then send a test alert there.

Sharing never starts from a push, restart or remote request. Stop at home closes capture and peers. Revocation removes access to signaling and future alerts.

## Development

Use Flutter **3.47.6**, Node **24**, Java **17** for Android and Java **21** for the Firestore emulator.

~~~sh
python3 tool/fetch_sound_model.py
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi
~~~

~~~sh
npm ci
npm run test:rules
npm --prefix backend ci
npm --prefix backend run check
npm --prefix backend test
npm --prefix viewer ci
npm --prefix viewer run check
npm --prefix viewer test
npm --prefix viewer run build
npm --prefix backend run build
~~~

The final backend command is a deployment dry run. For local preview, build viewer, then run **npm --prefix backend run dev**. It shows a setup error until Firebase is configured.

## Audio and access

Guardian captures mono 16 kHz PCM locally with the Android recorder and creates no WebRTC microphone track. Live + Guardian opens one WebRTC microphone track; a Kotlin sample tap feeds its mono 16 kHz PCM to the local classifier. A muted peer pair inside the home phone keeps this live-mode capture active with no listeners. It has no ICE servers and never plays audio.

Each viewer has one current session, replaced on reconnect and expiring after two hours. Native Android reconnects while listening remains enabled; Stop cancels recovery. The web app asks for another tap after a failed or expired session.

Private documents hold hashed invitations and push destinations. Clients cannot enroll themselves, edit membership, start sharing, read push tokens or access another viewer's session. Only current participants write SDP/ICE. Membership, generation and current-session checks invalidate access after revocation.

## Device testing and limits

Automated checks do not replace testing on your phones. Check Android capture with the screen closed, alerts with no live listeners, iPhone push with its app closed, mobile handover, revocation and Stop.

iOS can suspend browser WebRTC/background audio. Keep the iPhone app open for live listening; use push for unattended alerts. Hardware volume buttons may replace the page slider. The native iPhone app listens in cloud mode on the same server and API as Android (alerts through Apple push, live listening, QR or link pairing). An iPhone can also be the home phone in Guardian mode (sound alerts only, no live audio). Live + Guardian from the home phone still needs Android. On an iPhone home phone iOS shows its own orange recording indicator while the microphone is open, and Stop is on the Home screen; iOS has no persistent notification with a Stop action. Keep the app open or in the background with the phone charging, and test with the screen locked before relying on it. Tailscale mode is still available.

### iPhone app setup (one time)

1. Firebase console → Project settings → Add app → iOS, bundle ID `com.wiantribe.homeListen`. Copy its App ID (looks like `1:…:ios:…`).
2. Firebase console → Project settings → Cloud Messaging → Apple app configuration → upload an APNs Auth Key (.p8) from Apple Developer → Certificates, Identifiers & Profiles → Keys (enable Apple Push Notifications service). Enter the Key ID and Team ID.
3. In `backend/wrangler.jsonc` set `FIREBASE_IOS_APP_ID` to that App ID, then deploy the Worker. The App ID is public; the .p8 key stays in Firebase and is never committed.
4. In Apple Developer → Identifiers → `com.wiantribe.homeListen`, enable Push Notifications. Build with the `ios-testflight` Codemagic workflow.

The app asks for notification permission when you press Enable alerts. The push entitlement means the free-Apple-ID sideload workflow (`ios-unsigned`) no longer installs; use TestFlight.

Battery restrictions, force-stop, internet loss or denied notifications can interrupt monitoring. Force-stop does not restart capture. Sound detection can miss or mistake sounds; this is not an emergency alarm.

Ordinary Actions APKs use preview/debug signing. [Permanent release signing](docs/ANDROID_RELEASE.md) includes local configuration and a manual signed-release workflow for your own key. Never commit service-account JSON, VAPID private keys, TURN keys or signing keys.

YAMNet provenance/license are in [assets/models](assets/models). The download helper verifies the model checksum.
