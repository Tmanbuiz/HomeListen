# Store listings: TestFlight and Google Play

Copy-paste text for App Store Connect (TestFlight, later the App Store) and the
Google Play Console. Nothing here is submitted for you; each section says what
you must click. Character counts in brackets are against the stores' limits.

Sound detection is not an emergency alarm. Keep that wording in every listing.

## Read this first: what blocks each store

| Item | Status |
| --- | --- |
| Privacy policy page | Written: `viewer/public/privacy.html`, served at `https://homelisten.oralyvo.app/privacy` after the Worker is deployed. Have it reviewed before you rely on it; Claude is not a lawyer. |
| Support page | Written: `https://homelisten.oralyvo.app/support`, with `support@oralyvo.com` and `support@wiantribe.com`. Make sure both mailboxes exist and you read them, then deploy the Worker. The store consoles each take one support address; use `support@wiantribe.com` or `support@oralyvo.com`, whichever is the publisher's. |
| iPhone cloud mode | **Built and merged.** The iPhone listens in cloud mode and can be a Guardian-only home phone. Live sharing from an iPhone home phone is not built. Still needed before it works: add the iOS app in Firebase, upload the APNs key, set `FIREBASE_IOS_APP_ID` and deploy (README, iPhone app setup). The main App Store review risk is now a reviewer who cannot try it without a second phone (Guideline 2.1). |
| iOS signing | `ios-testflight` workflow added to `codemagic.yaml`. It needs the App Store Connect API key added in Codemagic as `homelisten-asc` and the app record created first (steps below). The older `ios-unsigned` workflow cannot go to TestFlight. |
| Android signing | Needs your permanent key (`docs/ANDROID_RELEASE.md`). Play also needs an `.aab`, which the signed workflow already makes. |
| Screenshots | Not in the repo. Needs real screenshots from your phones. |
| Android foreground service | Play requires a declaration and a short demo video for `FOREGROUND_SERVICE_MICROPHONE` (see below). |

## Identifiers

| | Android | iOS |
| --- | --- | --- |
| Bundle / application ID | `com.wiantribe.home_listen` | `com.wiantribe.homeListen` |
| Version | 2.2.1 (build 16) | set `MARKETING_VERSION` (currently 1.0) and build number before upload |
| Developer name | WianTribe Inc. | WianTribe Inc. |

Note the two IDs differ on purpose in spelling; each store only needs its own.

---

## Google Play Console

Console: https://play.google.com/console → **Create app**.

1. App name: `Home Listen` · Default language: English (Canada) · App (not game) · Free.
2. Accept the declarations.

### Main store listing

**App name** [11/30]
```
Home Listen
```

**Short description** [77/80]
```
Hear sound alerts from a phone left at home, on your own phone. Not an alarm.
```

**Full description** [2,295/4,000]
```
Home Listen turns a phone left at home into a quiet listening point, and sends sound alerts to your own phone.

HOW IT WORKS
• Leave a phone at home and switch Home Listen on: an Android phone, or an iPhone in Guardian mode. A visible microphone indicator and a Stop control stay on the whole time (on Android, a notification with a Stop button).
• Pair your own phone with a QR code or a link. Pairing links expire after 10 minutes.
• Choose Guardian mode for sound alerts only, or, on an Android home phone, Live + Guardian to also let an allowed listener hear the room live.

WHAT YOU GET
• Sound alerts on your phone when the home phone hears something you chose to be told about, such as barking, crying, loud noises or a doorbell.
• An event history of recent alerts.
• Optional live listening, only when an Android home phone is in Live + Guardian mode and your access allows it.
• Optional recording: tick the sounds you want, and your listening phone saves short clips to its own storage. Off by default.
• Up to five listening phones, each with its own access: caregiver, alerts only, or guest.
• Works on Android and iPhone, and in the iPhone Home Screen web app.
• Optional Tailscale mode and Home Assistant / MQTT integration for people who want them.

PRIVACY BY DESIGN
• Listening starts only on the home phone itself. It can never be started from a notification, a restart or a remote request.
• In Guardian mode no live audio is created at all.
• Nothing is recorded unless you turn it on. Optional clips are saved only on the listening phone you choose, never on the home phone, and are never uploaded to our servers. You can export or delete them at any time.
• Only small alert details, such as the type of sound and the time, reach the service.
• Sound recognition runs on your phones, not on our servers.
• You can remove a listening phone at any time and its access ends.

IMPORTANT
Home Listen is a convenience, not a safety device. Sound detection can miss sounds and can raise false alerts. Do not rely on it for emergencies, medical monitoring, or the care of a person who needs supervision. Phones can lose power, signal or notifications.

Use it only in a home you are entitled to listen in, and tell the people who live there that it is on.

Built by WianTribe Inc.
```

**Graphics needed:** app icon 512×512 PNG (use `viewer/public/icon-512.png` only if it matches the final app icon), feature graphic 1024×500, at least 2 phone screenshots. These are not in the repo.

**Contact details:** email (required, public), website (optional), phone (optional; do not use a personal number you want private).

**Privacy policy URL:** required. See the blockers table.

### App content declarations

| Form | Answer |
| --- | --- |
| Ads | No ads |
| App access | Needs a second phone to try. Give reviewers instructions and, if possible, a demo pairing link or a short video. Without this, review can fail. |
| Content rating (IARF) | Utility / communication tool; no violence, no user-generated public content. Answer the questionnaire truthfully; it also asks about location and communication features. |
| Target audience | 18 and over. Do not select children. |
| News app / COVID / government | No |
| Data safety | See below |
| Financial features / health | None |

### Data safety (answer on the form)

| Question | Answer |
| --- | --- |
| Collects or shares data | Yes, collects. Does not share with third parties for their own use. |
| Audio | **Not collected by the developer.** Live audio goes over WebRTC to a paired listener, only while the home owner has Live mode on, and is not stored by the service. Optional clips (off by default) are saved only in the listening device's own storage and never reach our servers. Declare "Voice or sound recordings: not collected". If Play's review disagrees, the safe wording is "processed ephemerally", plus an on-device-only note. |
| Device or other IDs | Yes: Firebase anonymous ID and push token. Purpose: app functionality. |
| App activity / other | Yes: alert type and time (event history). Purpose: app functionality. |
| Encrypted in transit | Yes |
| Users can request deletion | Yes (remove phone / reset in the app). State how in the privacy policy. |

### Permissions that need a declaration

| Permission | Why (use in the declaration) |
| --- | --- |
| `RECORD_AUDIO`, `FOREGROUND_SERVICE_MICROPHONE` | The home phone listens for sounds and, only if the owner turns Live mode on, streams them. A persistent notification with a Stop action is shown for as long as the microphone is on. Capture never starts remotely. |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Keeps live audio playing on a listener phone with the screen off. |
| `CAMERA` | Only on the pairing screen, to scan the pairing QR code. |
| `POST_NOTIFICATIONS` | Sound alerts. |

Play asks for a **short video** of the foreground service in use. Record the home
phone: start listening, show the notification and Stop button, then stop.

### Release

1. **Testing → Internal testing** first. Upload the signed `.aab` from the
   *Build signed Android release* workflow.
2. A new personal developer account must run **closed testing with at least 12
   testers for 14 days** before production access. If the account is an
   organisation account (WianTribe Inc.), this does not apply. Check which you have.
3. Production after review.

---

## TestFlight and App Store Connect

Console: https://appstoreconnect.apple.com → **Apps → + → New App**.

1. Platform iOS · Name `Home Listen` · Primary language English (Canada) ·
   Bundle ID `com.wiantribe.homeListen` (register it first under
   Certificates, Identifiers & Profiles → Identifiers, if it is not listed) ·
   SKU `homelisten-ios`.
2. **Capabilities** on the App ID: Push Notifications (needed for alerts
   in cloud mode). Background modes `audio` is already in `Info.plist`.
3. In App Store Connect: Users and Access → Integrations → App Store Connect
   API → generate a key (role App Manager) and download it once.
4. In Codemagic: Teams → Integrations → App Store Connect → add that key and
   name it exactly `homelisten-asc`. Then run the **iOS signed build to
   TestFlight** workflow. Codemagic creates the certificate and profile, builds
   a signed `.ipa` and uploads it. After Apple finishes processing (about 15
   minutes), add yourself under TestFlight → Internal Testing.
5. App Store Connect may ask the export-compliance question. Home Listen uses
   standard encryption only (HTTPS and WebRTC); answer that it uses encryption
   exempt from export documentation.

### TestFlight (internal testing)

**Test information**

Beta app description [342/4,000]
```
Home Listen lets this iPhone listen to a paired home phone in cloud mode: it receives sound alerts and, when allowed, live sound. The iPhone can also be a Guardian home phone that sends sound alerts only. You need a second phone with Home Listen, or a pairing link from the tester. Live sharing from an iPhone home phone is not in this build.
```

What to test [459/4,000]
```
1. Pair with the home phone using a QR code or link.
2. Enable alerts; make a sound at the home phone and check the push arrives with the app closed.
3. Start live listening and check the sound is clear.
4. Lock the screen and check whether audio continues.
5. Stop listening and confirm the home phone shows it stopped.
6. Try Guardian on the iPhone as the home phone with the screen locked for an hour.
Report anything that crashes or shows the wrong state.
```

Feedback email: your support mailbox. Review contact: Tolulope Atoyeje.

Internal testers (up to 100 people on your App Store Connect team) need no
Apple review. External testers need a short **Beta App Review** and the
description above.

### App Store listing

Submit to the App Store only after TestFlight testing on real phones, the Firebase
iOS app and APNs key are set up, and a working demo route for reviewers exists.

**Name** [11/30]
```
Home Listen
```

**Subtitle** [27/30]
```
Sound alerts from your home
```

**Promotional text** [156/170]
```
Get sound alerts from the phone you left at home, and listen live when you choose to. Recording is optional and stays on your phone. Not an emergency alarm.
```

**Keywords** [90/100]
```
baby monitor,sound alert,home audio,listen,monitor,pet,nursery,intercom,guardian,caregiver
```
Avoid competitor names and "emergency", "security alarm", or medical claims.

**Description** [1,704/4,000]
```
Home Listen works with a phone left at home. This iPhone listens: it receives sound alerts and, when you allow it, lets you hear the room live. It can also be the home phone in Guardian mode, sending sound alerts only.

HOW IT WORKS
• Leave a phone at home running Home Listen. On Android it shows a visible microphone notification with a Stop button; on iPhone, iOS shows its own recording indicator and Stop is on the Home screen.
• Pair this iPhone by scanning a QR code or opening a link. Pairing links expire after 10 minutes.
• Get alerts on this iPhone. Optionally listen live when the home phone is in Live + Guardian mode.

WHAT YOU GET
• Sound alerts for sounds you choose, such as barking, crying, loud noises or a doorbell.
• A history of recent alerts.
• Live listening on request, only while the app is open.
• Access levels for each listener: caregiver, alerts only, or guest.
• Optional Tailscale mode.

PRIVACY
• Listening starts only on the home phone. It cannot be started from a notification, a restart or a remote request.
• Nothing is recorded unless you turn it on. Optional clips are saved only on your own phone, never on the home phone and never uploaded. Only alert details, such as the type of sound and the time, are stored by the service.
• Remove a listener at any time and its access ends.

IMPORTANT
Keep the app open for live listening; iOS pauses audio in the background. For alerts while the app is closed, use notifications.
Home Listen is not an emergency alarm or a medical or safety device. Sound detection can miss sounds and can raise false alerts. Use it only in a home you are entitled to listen in, and tell the people who live there.

Built by WianTribe Inc.
```

**URLs:** Support URL (required), Privacy Policy URL (required), Marketing URL (optional).

**Category:** Utilities. Secondary: Lifestyle. **Age rating:** answer the questionnaire; expect 4+.
**Price:** Free.

### App Privacy (nutrition label)

| Data type | Collected | Linked to user | Used for tracking |
| --- | --- | --- | --- |
| Audio data | **No.** Processed live and optional clips stay on the device only; nothing is transmitted to the developer's servers | n/a | No |
| Identifiers (device/user ID, push token) | Yes | Yes | No |
| Other usage data (alert type and time) | Yes | Yes | No |
| Everything else | No | | |

If Apple's reviewers treat live audio or the extra recording channel as collection, change Audio to collected,
not linked, not used for tracking, purpose App Functionality. State the choice
in the privacy policy to match.

### App Review notes (paste in the review information box)

```
Home Listen has two parts: a "home phone" (Android, or an iPhone in Guardian mode) and "listener" phones. This iPhone app can be either. To test without a second phone, use the pairing link below.
Demo pairing link: <ADD A WORKING DEMO LINK THAT STAYS VALID FOR REVIEW>
The microphone permission is requested only if the user chooses to use this phone as the home phone; iOS then shows its recording indicator. The camera permission is used only on the pairing screen to scan a QR code. Recording of sound clips is optional, off by default, saved only on the user's own device and never uploaded.
```

The pairing limits (10 minute links, five listeners) mean a normal link expires
during review. Plan a long-lived demo route before submitting; this is the most
likely cause of an "unable to test" rejection.

### Things Apple is likely to reject on

1. No usable function without owning the Android home phone (2.1) → demo route.
2. Recording audio: say plainly in the app and policy that clips are optional, on-device and deletable (5.1.1).
3. Missing privacy policy or support URL (5.1.1).
4. `UIBackgroundModes: audio` without background audio playing for the user (2.5.4). Keep it only if live listening plays in the background.
5. Any wording that sounds like an emergency or safety guarantee (1.4).
