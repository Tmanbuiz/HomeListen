# Home Listen 2.2.5

Native source version: **2.2.5+20**. Web: **2.2.5 · update 1**. API: **2.2.5**. These identifiers describe this source revision; they do not establish installation or production deployment.

## Corrected behavior

- Removing one phone invalidates outstanding invitation links, including a join already racing with removal. Other paired phones retain their live sessions. Fresh link or authenticator pairing remains possible.
- Invitation creation is guarded by the same room revision as its authorization, so a delayed request cannot overwrite a fresh link after removal.
- Alert duration and receiver recording duration are independent. Fresh recording defaults now match on native and web: crying 30 seconds, coughing 8 seconds; recording remains opt-in.
- Saved eight-second cough alert settings are flagged for review instead of silently treating an intentional setting as an obsolete default. **Use two-cough alerts** applies the recommended rule; **Keep 8-second rule** confirms a custom choice. Both preserve recording duration and consent.

## Upgrade order

1. Validate the branch's CI and preview APK before rollout.
2. Deploy the Worker/web update through the existing deployment process. The revocation correction requires the updated Worker; installing mobile alone does not change server authorization.
3. Install the updated native build on home and receiving phones. In Guardian rules on the home phone, resolve any cough timing review prompt.
4. Complete the device checks below before marking background operation verified.

Existing room/invitation documents without an invitation epoch are accepted as epoch zero. The first individual removal invalidates those old links. No Firestore rules or household-data migration is required. Existing paired phones stay paired. An intentionally shared authenticator remains an alternate pairing authority.

## Real-device validation

These checks require physical phones and are not completed by unit tests. Record phone/OS, home build, receiver build, connection type, test date, actual result, and any logs for each run. Do not mark a row passed without evidence.

| Check | Expected behavior | Device evidence |
| --- | --- | --- |
| Android home Guardian overnight, screen locked and charging | Local detection continues; selected push alerts reach enabled receivers; no live audio track | Pending |
| Android Live + Guardian with zero, one and multiple listeners | Capture/detection continue; authorized listeners hear audio | Pending |
| iPhone home Guardian locked/backgrounded | Verify actual capture and alerts on the tested OS/build; record interruptions | Pending |
| Receiving Android/iPhone/web background transitions | Record whether live audio/recordings continue or are suspended; later push cannot reconstruct missing audio | Pending |
| Known cry/cough/knock samples plus speech/TV controls | Record misses, false alerts and delay; confirm cough review choice and selected durations | Pending |
| Receiver recordings shorter/longer than thresholds | Short episodes discarded; qualified WAV includes detected episode and correct duration/name | Pending |
| Wi-Fi to mobile data and back | Capture is never silently restarted; recovery stays authorized; gaps split recordings | Pending |
| Restrictive network while TURN is disabled | Record direct-connection outcome; investigate relay need if audio fails | Pending |
| Remove one phone while listening/recording | That phone loses access; old link fails; other phones remain connected | Pending |
| Stop, guest expiry and global revocation | Audio stops, recordings finish/discard correctly, no unauthorized reconnect | Pending |
| Incoming call, microphone denial and battery restrictions | State reflects interruption; recovery requires valid authorization and local start where necessary | Pending |
| Force-stop/process death/reboot | Capture stays off until the home user starts it locally | Pending |

This update does not claim to prove sound accuracy, overnight reliability, APNs/FCM delivery, or iOS distribution from automated checks alone.
