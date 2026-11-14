# Home Listen 2.3.0 — saved rooms and local recording

Native source: **2.3.0+21**. Web: **2.3.0 · update 1**. These identifiers describe the update; installation, distribution and deployment must be verified separately.

## Away-phone rooms

Pair each home phone once from **Devices → Add another room**, using its link/QR code or secret answer plus authenticator code. Saved rooms such as Home 1, Home 2, Bedroom and Children’s room appear in the room selector. Existing single-room pairing is migrated without needing another invitation.

Each available room keeps its own authorized live connection. Selecting a room changes which one you hear; other rooms remain connected and muted. Alert subscriptions and connection recovery are maintained per room. Keeping several live streams connected uses more data and battery.

The room list belongs to the current configured Cloud server. Invitations and authenticator secrets are not saved in it. Existing Tailscale behavior is retained; this room switcher is for Cloud connections. An offline home, Guardian-only source, alerts-only role, expired guest or revoked membership cannot be made live by selecting it.

**Log out of this room** affects only this receiving device’s membership in that room. Other saved rooms and other listening devices stay connected. **Stop all live audio** closes local peers and cancels their reconnect attempts without forgetting saved rooms. Saved pairing survives normal app/page reopening; an operating system may still suspend or terminate background work.

## Record to this device

While the selected room has an authorized live connection, choose **Record room to this device** (native) or **Record this room** (web). Choose Stop to finish and save a local WAV. A manual recording does not require a sound detector verdict or a minimum cry/cough duration, and it excludes audio received before Record was pressed.

Recording is off until requested. Only the selected room is recorded; connected muted rooms are not silently saved. Switching rooms, logging out, Stop, disconnection, loss of live access or guest expiry finishes the current recording. Long recordings split into ten-minute files. Each clip retains its room identity; native export and web download filenames include the room label.

Automatic sound-episode recording remains available through its existing opt-in sound-rule checkboxes. Manual recording does not change those saved choices. Native clips stay in private app storage until Save / share audio is used; web clips stay in that browser’s IndexedDB until downloaded. Existing age, 100-clip and 200-MB retention limits still apply across rooms.

Cloud recording needs an updated Android home phone in **Live + Guardian**, because that source supplies the authorized recording data channel. An iPhone home phone in Guardian mode supplies alerts only. No home microphone is started remotely, no recording is written on the home phone, and no clip is uploaded to the HomeListen backend.

## Validation and rollout

- Validate backend room/session isolation, native coordinator and widget behavior, background inbox routing, clip attribution, manual WAV duration, web coordinator/storage/service-worker behavior, and real browser controls.
- Browser integration tests use isolated fake Firebase/WebRTC services; they do not connect to production households or prove physical audio behavior.
- Confirm the pinned Flutter analyzer/tests and Android preview build on the exact PR head. Preview signing is not permanent release signing or TestFlight publication.
- Build the web viewer before packaging the existing Worker assets. This feature uses existing room-scoped backend APIs and does not require a Firestore rules migration.
- Install the native update on receiving devices and verify selected-room audio, simultaneous muted peers, manual WAV playback/export, single-room logout, Stop, lock-screen behavior and network handover on physical phones.

Automated tests do not establish overnight reliability, detection accuracy, push delivery or iOS distribution. Record device evidence before marking those checks complete.
