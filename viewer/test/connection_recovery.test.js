import test from "node:test";
import assert from "node:assert/strict";
import { recoveringWatch } from "../src/recovering-watch.js";
import { logoutViewer } from "../src/logout.js";
import { AudioSession } from "../src/audio-session.js";

test("terminal room-watch errors recover without accepting stale callbacks", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const watches = [], values = [], errors = [];
  const stop = recoveringWatch((next, error) => {
    const watch = { next, error, canceled: false }; watches.push(watch);
    return () => { watch.canceled = true; };
  }, (value) => values.push(value), (error) => errors.push(error));
  watches[0].next("first");
  watches[0].error(new Error("unavailable"));
  assert.equal(watches[0].canceled, true);
  watches[0].next("stale");
  t.mock.timers.tick(2000);
  watches[1].next("restored");
  assert.deepEqual(values, ["first", "restored"]);
  assert.equal(errors.length, 1);
  watches[1].error(new Error("offline"));
  stop(); t.mock.timers.tick(120000);
  assert.equal(watches.length, 2);
});

test("room-watch retries back off when the server stays unavailable", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let attempts = 0;
  const stop = recoveringWatch(() => { attempts++; throw new Error("offline"); }, () => {}, () => {});
  t.mock.timers.tick(2000); assert.equal(attempts, 2);
  t.mock.timers.tick(3000); assert.equal(attempts, 2);
  t.mock.timers.tick(1000); assert.equal(attempts, 3);
  stop();
});

for (const offline of [false, true]) test("logout stops audio, clears pairing and signs out" + (offline ? " while offline" : ""), async () => {
  const calls = [];
  await logoutViewer({
    stop: async () => calls.push("stop"),
    leave: async () => { calls.push("leave"); if (offline) throw new Error("offline"); },
    clear: () => calls.push("clear"),
    signOut: async () => calls.push("signOut")
  });
  assert.deepEqual(calls, ["stop", "leave", "clear", "signOut"]);
});

async function listener(onError) {
  const pc = {
    connectionState: "new", addTransceiver() {}, close() {},
    createOffer: async () => ({ sdp: "offer" }), setLocalDescription: async () => {}
  };
  const audio = new AudioSession({
    roomId: "room", rtc: () => pc, onError, onState() {},
    api: async (path) => path.endsWith("/ice") ? { iceServers: [] } :
      { sessionId: "session", expiresAt: new Date(Date.now() + 7200000).toISOString() },
    firestore: { watchSession: () => () => {}, watchCandidates: () => () => {},
      setOffer: async () => {}, end: () => new Promise(() => {}) }
  });
  await audio.start();
  const state = (value) => { pc.connectionState = value; pc.onconnectionstatechange(); };
  return { audio, state };
}

test("disconnected web audio has a recovery deadline after being connected", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const errors = [];
  const { audio, state } = await listener((error) => errors.push(error));
  state("connected"); state("disconnected");
  t.mock.timers.tick(11000); assert.equal(errors.length, 0);
  state("connected"); t.mock.timers.tick(2000); assert.equal(errors.length, 0);
  state("disconnected"); t.mock.timers.tick(12000); assert.equal(errors.length, 1);
  await audio.stop();
});

test("web Stop cancels recovery and completes even when Firestore is offline", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const errors = [];
  const { audio, state } = await listener((error) => errors.push(error));
  state("connected"); state("disconnected");
  await audio.stop();
  t.mock.timers.tick(120000); assert.equal(errors.length, 0);
});
