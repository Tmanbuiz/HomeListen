# Set up Home Listen

Use your own Firebase and Cloudflare accounts. Keep Firebase on **Spark** and Workers on **Free** for their no-cost quotas. No credentials are included in this repository.

## Firebase

1. Create a project in [Firebase Console](https://console.firebase.google.com/). Analytics is optional and not used here.
2. Enable **Anonymous** sign-in under Authentication.
3. Create a **Firestore Standard** database named **(default)** with production/locked rules. Keep Spark; do not enable paid TTL deletion.
4. Register Web and Android apps in the same project. Android package: **com.wiantribe.home_listen**.
5. Copy Web config apiKey, projectId, appId and messagingSenderId. Copy Android mobilesdk_app_id from google-services.json. Public options come from the Worker; no google-services.json needs committing.
6. Confirm Firebase Cloud Messaging API v1 is enabled.
7. Create a dedicated service account in the project's IAM console. Grant **Cloud Datastore User** and **Firebase Cloud Messaging API Admin**. Generate its JSON key and keep it outside the checkout.

The service account is used by the Worker. Phones use anonymous identity tokens with limited client permissions.

From the repository root:

~~~sh
npm ci
npx firebase login
npx firebase deploy --only firestore --project YOUR_FIREBASE_PROJECT_ID
~~~

This deploys rules and cleanup indexes, with no functions. Wait for indexes to finish building before checking cron cleanup.

This implementation shares the Web API key with Android. HTTP-referrer-only restrictions will block Android; use compatible key restrictions that allow Identity Toolkit, Secure Token and Firestore. The key identifies the project; tokens and rules authorize access.

## Cloudflare

~~~sh
npm --prefix backend ci
npm --prefix viewer ci
npm --prefix viewer run build
cd backend
npx wrangler login
~~~

Fill public values in **backend/wrangler.jsonc**:

| Field | Fill with |
| --- | --- |
| FIREBASE_PROJECT_ID | Firebase project ID |
| FIREBASE_API_KEY | Web config apiKey |
| FIREBASE_WEB_APP_ID | Web appId containing :web: |
| FIREBASE_ANDROID_APP_ID | Android mobilesdk_app_id containing :android: |
| FIREBASE_MESSAGING_SENDER_ID | Web config messagingSenderId |
| VAPID_PUBLIC_KEY | Public push key generated below |
| VAPID_SUBJECT | Your contact mailto: address or valid HTTPS URL |
| PUBLIC_ORIGIN | Actual Worker HTTPS origin after deployment |
| ALLOW_TURN | false initially |

From backend, generate the Web Push keys:

~~~sh
npx web-push generate-vapid-keys --json
~~~

Put only the public key into configuration. Store secrets with these commands, which prompt for their values:

~~~sh
npx wrangler secret put FIREBASE_SERVICE_ACCOUNT
npx wrangler secret put VAPID_PRIVATE_KEY
~~~

Paste the account's complete JSON as one line for FIREBASE_SERVICE_ACCOUNT. Minify it locally, preserving escaped newlines in private_key. Keep all private values out of the repository and pairing links.

~~~sh
npm run deploy
~~~

Wrangler prints **https://homelisten.YOUR_SUBDOMAIN.workers.dev**. Set PUBLIC_ORIGIN to that exact origin and deploy again. Add the hostname to Authentication's authorized domains if the project requires it.

Open **/api/health**: configured should be true. The root page should show the pairing card. Enable anonymous sign-in if the page reports that it is disabled.

For local development, place values in ignored **backend/.dev.vars**, with the service-account JSON as a single quoted string. Build viewer, then run npm run dev from backend.

## Optional TURN relay

Direct STUN connections cannot traverse every network. Configure TURN when both phones are online and sharing is on but audio times out, or choose Tailscale.

1. Review [Realtime pricing](https://developers.cloudflare.com/realtime/sfu/platform/pricing/) and account billing. TURN and SFU share the first 1,000 GB/month; additional egress is $0.05/GB.
2. Create a TURN key in Cloudflare Realtime. Save its key ID and associated TURN key API token.
3. From backend:

~~~sh
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_API_TOKEN
~~~

4. Set ALLOW_TURN to true and deploy.

Paired authenticated phones receive two-hour credentials only while the home is sharing. Credentials refresh during sessions; the master key stays on the Worker. Monitor usage: there is no automated billing cap in this app.

## Android installation

Open **Actions → Build and check Home Listen** in GitHub. From a successful run, download **homelisten-android-apks**, extract it, and install the arm64 APK on a modern Android phone.

Or build locally:

~~~sh
python3 tool/fetch_sound_model.py
flutter pub get
flutter build apk --release --split-per-abi
~~~

Choose the phone's role, configure Cloud in Settings with the Worker HTTPS address, then pair in Devices. The home phone must be Android. It requires microphone permission and a visible foreground notification before sharing.

Android away **Listen** registers push alerts too. **Alerts only** registers push without live audio. Stop disables push when online. If offline, audio stops and the app explains that you must disable alerts after internet returns.

Keep the home phone charging and exempt it from restrictive battery settings. Sharing is not restored automatically after process death.

## iPhone installation

1. On iOS 16.4+, open the Worker root in Safari.
2. Tap **Share → Add to Home Screen**, then open the installed icon.
3. Show a fresh pairing link at home and paste it into the installed app. Install before pairing because a separate browser/install can create another phone identity.
4. Tap **Listen live**, then **Tap to play sound** if autoplay is blocked.
5. Tap **Enable alerts** and allow notifications. Enable Sound Watch and send a test alert at home.

No App Store, Apple Developer membership or seven-day signing is needed. Background push and background live audio differ: test lock-screen push and keep the app open for live listening.

## Test before use

- Sharing off: no audio session can start.
- Sharing on with no live listener: local sound detection and test push still work.
- Away on mobile data: audio connects directly or through TURN.
- iPhone app closed: push appears on its lock screen.
- Home Stop: microphone indicator/foreground service end and viewers disconnect.
- Revoke: viewers disconnect and old invitations no longer pair.
- Stop listening: Android does not reconnect until you ask or enable automatic connection again.
- Force-stop/reboot: sharing stays off until another local tap.

Check Firebase quotas and Worker CPU/errors. For push failures, check Android Play services, iPhone Home Screen installation, permissions, VAPID keys and Sound Watch.
