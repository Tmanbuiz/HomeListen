# Home Listen 2.3.1 — share a room from an away phone

Native source **2.3.1+22**; web **2.3.1 · update 1**; API **2.3.1**. Build and deployment status must be verified separately.

## Android, iPhone and web

On an already-paired away phone, select the room and choose **Share this room**. Native apps show an **Invite another phone** dialog; choose **Create pairing code**. The web listener creates its code when the dialog opens. Show the QR to the new phone, copy the pairing link, or use the device's share sheet where supported.

The new phone scans in Home Listen's Devices screen, scans in the web listener's **Add a room** screen, or opens/pastes the link. The link contains the server address and a fresh invitation; it does not copy a Firebase sign-in, authenticator secret, secret answer or any recording. Older 2.3.0 receivers can redeem these links against an updated server.

The invitation adds one phone to the selected room. It expires after ten minutes and can be used by one new device. A retry from the same accepted device is safe. Creating another code replaces only that sender's previous unused code; the home phone's pairing code and other senders' codes are retained.

Each phone has its own room membership and sessions. Sharing a code does not stop the sender's audio, change the audible room, or alter recording. The added phone keeps its membership if the sender later logs out. Other saved rooms remain unchanged.

## Access limits

Only a current permanent caregiver can create an away invitation. Alerts-only, guest and expiring memberships cannot forward access. Existing caregiver memberships with no access-role field retain the original caregiver default. The home phone owner remains responsible for changing roles, removing phones, authenticator settings and sharing controls.

The five-listening-phone limit still applies to each room. The home phone need not be physically nearby or actively sharing to pair another listener. Joining never starts its microphone; live listening still requires locally enabled sharing and suitable access.

Unused codes stop working if the sender leaves, loses caregiver permission, or the owner revokes access/pairing codes. Leaving and rejoining cannot revive an old code. A used code cannot restore a recipient after logout/removal or replace a restricted role. These rules are enforced by atomic backend operations, not just disabled UI controls.

## Privacy and camera behavior

QR codes are generated and decoded locally. Secrets are kept only in the open dialog's memory and are not added to saved-room preferences or sent to a QR image service. Closing, expiry or a room/access change clears the displayed code. Copying or sharing a link is an explicit action.

The web scanner requests video only after **Scan pairing code** is pressed. Stop camera, closing the scanner, hiding the page, success or a failure releases its own camera stream, including a permission response that arrives after cancellation. Room audio and recording streams are separate. If camera access is unavailable, paste the link instead.

This feature is for Cloud rooms. Existing Tailscale pairing remains unchanged. Native Android and iPhone use their system share sheets; browsers without Web Share still support QR and copy/paste.

## Verification

Validate role/expiry/replay boundaries, issuer and receiver membership changes, concurrent redemption/capacity, renewal and cleanup races, stale UI responses, camera cancellation, correct QR decoding and uninterrupted room peers. Firestore rules are unchanged: invitations remain private and server-managed. No rules migration or new paid service is required.

Automated builds do not prove physical QR scanning, iPad share-sheet behavior, push delivery or locked-screen/background reliability. Test those on real devices before treating them as verified.
