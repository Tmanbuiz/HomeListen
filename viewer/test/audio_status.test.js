import test from "node:test";
import assert from "node:assert/strict";
import { audioStatus, connectionLabel, STILL_TRYING } from "../src/audio-status.js";
import { AudioSession, UNREACHABLE } from "../src/audio-session.js";
import { MultiRoomSessions } from "../src/multi-room-sessions.js";
import { RoomRegistry } from "../src/room-registry.js";

const settle = () => new Promise(resolve => setImmediate(resolve));
function storage() {
  const map = new Map();
  return { getItem: key => map.get(key) ?? null, setItem: (key, value) => map.set(key, value), removeItem: key => map.delete(key) };
}

test("status text follows the real connection state", () => {
  const session = {};
  assert.equal(audioStatus(null, true), "");
  assert.equal(audioStatus({ state: "idle", attempts: 0 }, true), "Ready when you are.");
  assert.equal(audioStatus({ session, state: "connecting", attempts: 0 }, true), "Connecting to this room…");
  // Muted rooms that have not connected must not claim to be connected.
  assert.equal(audioStatus({ session, state: "connecting", attempts: 0 }, false), "Connecting to this room…");
  assert.equal(audioStatus({ session, state: "connecting", attempts: 2 }, true), STILL_TRYING);
  assert.equal(audioStatus({ session, state: "disconnected", attempts: 0 }, true), "Connection interrupted. Reconnecting…");
  assert.equal(audioStatus({ session, state: "connected", attempts: 0 }, true), "You’re listening to this room.");
  assert.equal(audioStatus({ session, state: "connected", attempts: 0 }, false), "Connected · tap to hear this room.");
  assert.equal(audioStatus({ session, state: "connected", attempts: 0, blocked: true }, true), "Connected · tap to hear this room.");
  assert.equal(audioStatus({ state: "reconnecting", problem: UNREACHABLE, retry: 1, attempts: 1 }, true), UNREACHABLE + " Trying again…");
  assert.equal(audioStatus({ state: "unavailable", problem: "Audio connection lost.", retry: null, attempts: 1 }, true), "Audio connection lost.");
  assert.equal(connectionLabel({ session, state: "connecting", attempts: 0 }), "Connecting");
  assert.equal(connectionLabel({ session, state: "connecting", attempts: 1 }), "Retrying");
  assert.equal(connectionLabel({ session, state: "disconnected", attempts: 0 }), "Reconnecting");
  assert.equal(connectionLabel({ session, state: "connected", attempts: 0 }), "Connected");
});

test("an unreachable room says so while retrying, and Connect starts a fresh try", async t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const registry = new RoomRegistry(storage()); registry.add("room_a", "Bedroom");
  const made = [];
  const sessions = new MultiRoomSessions({ registry, allowed: room => room?.authorized === true,
    createAudio: () => ({ muted: true, volume: 0, srcObject: null, async play() {}, pause() {}, remove() {} }),
    createSession: (id, callbacks) => {
      const session = { callbacks, stopped: 0, async start() {}, async stop() { this.stopped++; } };
      made.push(session); return session;
    }
  });
  t.after(() => sessions.stopAll());
  const status = () => audioStatus(sessions.selected, sessions.audible);
  sessions.update("room_a", { authorized: true }); await sessions.startAll(); await settle();
  assert.equal(made.length, 1); assert.equal(status(), "Connecting to this room…");

  made[0].callbacks.onError(new Error(UNREACHABLE)); await settle();
  assert.equal(status(), UNREACHABLE + " Trying again…");
  t.mock.timers.tick(1000); await settle();
  assert.equal(made.length, 2); assert.equal(status(), STILL_TRYING);
  assert.equal(connectionLabel(sessions.selected), "Retrying");

  made[1].callbacks.onError(new Error(UNREACHABLE)); await settle();
  assert.equal(status(), UNREACHABLE + " Trying again…");
  // Tapping Connect during the wait retries now, as a fresh attempt.
  await sessions.startAll(); await settle();
  assert.equal(made.length, 3); assert.equal(status(), "Connecting to this room…");
  assert.equal(sessions.selected.attempts, 0);

  made[2].callbacks.onState("connected");
  assert.equal(status(), "You’re listening to this room.");
});

test("a stalled signaling write still times out instead of connecting forever", async t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const errors = [];
  const pc = { connectionState: "new", addTransceiver() {}, createOffer: async () => ({ sdp: "offer" }),
    setLocalDescription: async () => {}, close() {} };
  const audio = new AudioSession({ roomId: "room_a",
    api: async path => path.endsWith("/ice") ? { iceServers: [] } : { sessionId: "s", expiresAt: new Date(Date.now() + 3_600_000).toISOString() },
    rtc: () => pc, onError: error => errors.push(error.message), onState: () => {},
    firestore: { watchSession: () => () => {}, watchCandidates: () => () => {}, addCandidate: async () => {},
      setOffer: () => new Promise(() => {}), end: async () => {} }
  });
  void audio.start(); await settle();
  assert.deepEqual(errors, []);
  t.mock.timers.tick(35_000);
  assert.deepEqual(errors, [UNREACHABLE]);
  await audio.stop();
});
