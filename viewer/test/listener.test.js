import test from "node:test";
import assert from "node:assert/strict";
import { AudioSession } from "../src/audio-session.js";
import { parsePairing } from "../src/pairing.js";
import { canListen, memberAccess } from "../src/access.js";
const roomId = "a".repeat(24), secret = "B".repeat(43);
test('Guardian, alerts-only access and guest expiry disable listening', () => {
  const now = Date.now();
  const room = { members: { away: true }, sharing: true, lastSeenMs: now };
  assert.equal(canListen(room, 'away', now), true);
  assert.equal(canListen({ ...room, audioAvailable: false }, 'away', now), false);
  const alerts = { ...room, memberAccess: { away: { role: 'alerts' } } };
  assert.equal(memberAccess(alerts, 'away', now), true);
  assert.equal(canListen(alerts, 'away', now), false);
  const guest = { ...room, memberAccess: { away: { role: 'guest', expiresAtMs: now + 1000 } } };
  assert.equal(canListen(guest, 'away', now), true);
  assert.equal(memberAccess(guest, 'away', now + 1000), false);
  assert.equal(canListen(guest, 'away', now + 1000), false);
  assert.equal(canListen(room, 'stranger', now), false);
  assert.equal(canListen({ ...room, lastSeenMs: now - 120_000 }, 'away', now), false);
});
test("invitation accepts only this server and keeps the secret in the fragment", () => {
  const good = "https://home.example/#pair=" + roomId + "." + secret;
  assert.deepEqual(parsePairing(good, "https://home.example"), { roomId, secret });
  for (const value of [good.replace("home.example", "other.example"), good.replace("https:", "http:"),
    good.replace("/#pair=", "/?pair="), good.replace(secret, "short"),
    good.replace("home.example", "user:pass@home.example")]) assert.equal(parsePairing(value, "https://home.example"), null);
});
test("stop during session creation never opens a peer and ends the orphaned session", async () => {
  let resolve, peers = 0, ended = [];
  const pending = new Promise((r) => resolve = r);
  const audio = new AudioSession({
    api: () => pending, roomId, firestore: { end: async (id) => ended.push(id) },
    rtc: () => { peers++; }, onError: assert.fail
  });
  const start = audio.start();
  await audio.stop();
  resolve({ sessionId: "session", expiresAt: new Date(Date.now() + 10000).toISOString() });
  await start;
  assert.equal(peers, 0); assert.deepEqual(ended, ["session"]);
});
test("audio is receive-only; early ICE is queued and stopping removes listeners before ending", async () => {
  let sessionHandler, candidatesHandler; const calls = [], received = [];
  const pc = {
    connectionState: "new", remoteDescription: null,
    addTransceiver: (kind, options) => calls.push([kind, options.direction]),
    createOffer: async () => ({ sdp: "offer" }), setLocalDescription: async () => {},
    setRemoteDescription: async (answer) => { pc.remoteDescription = answer; },
    addIceCandidate: async (candidate) => received.push(candidate),
    close: () => calls.push("close")
  };
  const audio = new AudioSession({
    roomId, api: async (path) => path.endsWith("/ice") ? { iceServers: [] } :
      { sessionId: "session", expiresAt: new Date(Date.now() + 100000).toISOString() },
    rtc: () => pc, onError: assert.fail, onState: () => {},
    firestore: {
      watchSession: (_, next) => { sessionHandler = next; return () => calls.push("unsub-session"); },
      watchCandidates: (_, next) => { candidatesHandler = next; return () => calls.push("unsub-candidates"); },
      setOffer: async () => {}, addCandidate: async () => {},
      end: async () => calls.push("end")
    }
  });
  await audio.start();
  const candidate = { id: "one", side: "home", candidate: "candidate", sdpMid: "0", sdpMLineIndex: 0 };
  candidatesHandler([candidate, candidate, { ...candidate, id: "away", side: "away" }]);
  assert.equal(received.length, 0);
  await sessionHandler({ answer: "answer" });
  assert.equal(received.length, 1);
  assert.deepEqual(calls[0], ["audio", "recvonly"]);
  await audio.stop(); await audio.stop();
  assert.deepEqual(calls.slice(1), ["unsub-session", "unsub-candidates", "close", "end"]);
});
