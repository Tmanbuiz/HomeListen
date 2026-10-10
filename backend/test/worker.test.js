import test from "node:test";
import assert from "node:assert/strict";
import { createWorker, validateSubscription } from "../src/worker.js";
import { HttpError } from "../src/security.js";
import { base32Decode, counterAt, hotp } from "../src/totp.js";

class MemoryStore {
  docs = new Map(); counter = 0;
  async get(path) { return structuredClone(this.docs.get(path) ?? null); }
  async put(path, data, version) {
    const old = this.docs.get(path);
    if ((version === null && old) || (version && old?.version !== version)) throw new HttpError(409, "conflict");
    this.docs.set(path, { data: structuredClone(data), version: String(++this.counter) });
  }
  async delete(path) { this.docs.delete(path); }
  async expireDevice(id, uid, version) {
    const path = `rooms/${id}/devices/${uid}`;
    if (this.docs.get(path)?.version !== version) return false;
    const room = this.docs.get(`rooms/${id}`);
    if (!room) return false;
    this.docs.delete(path);
    delete room.data.watchers[uid];
    room.version = String(++this.counter);
    return true;
  }
  async createHome(uid, id, room) {
    if (this.docs.has("owners/" + uid)) throw new HttpError(409, "conflict");
    await this.put("owners/" + uid, { roomId: id }, null);
    await this.put("rooms/" + id, room, null);
  }
  async openSession(id, room, sid, session) {
    if (this.docs.get("rooms/" + id)?.version !== room.version) throw new HttpError(409, "conflict");
    const old = room.data.activeSessions?.[session.viewerUid];
    const activeSessions = { ...room.data.activeSessions, [session.viewerUid]: sid };
    // Synchronous assignments model Firestore's atomic commit, including CAS.
    this.docs.set("rooms/" + id, { data: { ...room.data, activeSessions }, version: String(++this.counter) });
    this.docs.set("rooms/" + id + "/sessions/" + sid, { data: structuredClone(session), version: String(++this.counter) });
    if (old) {
      const previous = this.docs.get("rooms/" + id + "/sessions/" + old);
      if (previous) previous.data.ended = true;
    }
  }
}
function setup({ sendPush, ...extraEnv } = {}) {
  const store = new MemoryStore(); let time = 100000000;
  const pushes = [];
  const env = { FIREBASE_PROJECT_ID: "demo-home", FIREBASE_API_KEY: "public-key",
    FIREBASE_WEB_APP_ID: "public-web-id", FIREBASE_ANDROID_APP_ID: "public-android-id",
    FIREBASE_SERVICE_ACCOUNT: "private-secret", VAPID_PUBLIC_KEY: "public-vapid", VAPID_PRIVATE_KEY: "private-vapid", ...extraEnv };
  const worker = createWorker({
    storeFor: () => store, now: () => time,
    authenticate: async (request) => {
      const uid = request.headers.get("authorization")?.replace("Bearer ", "");
      if (!uid) throw new HttpError(401, "auth required");
      return { uid };
    },
    sendPush: async (device, payload) => {
      pushes.push({ device, payload });
      return sendPush ? sendPush(device, payload) : { sent: true };
    },
    iceServers: async () => [{ urls: ["stun:stun.cloudflare.com:3478"] }]
  });
  async function api(path, uid = "home", data = {}, method = "POST", headers = {}) {
    const response = await worker.fetch(new Request("https://home.example/api" + path, {
      method, headers: { ...(uid ? { authorization: "Bearer " + uid } : {}),
        "content-type": "application/json", ...headers },
      ...(["GET", "DELETE"].includes(method) ? {} : { body: JSON.stringify(data) })
    }), env);
    return { status: response.status, body: await response.json() };
  }
  async function home() {
    const created = await api("/rooms", "home", { roomName: "Bedroom" });
    const id = created.body.roomId;
    const invite = await api("/rooms/" + id + "/invite");
    return { id, secret: invite.body.secret };
  }
  const join = (id, secret, uid = "away") => api("/rooms/" + id + "/join", uid, { secret });
  return { store, api, home, join, pushes, advance: (ms) => time += ms, now: () => time, env };
}

test("anonymous identity alone cannot read, join, or operate another home", async () => {
  const s = setup(); const { id } = await s.home();
  assert.equal((await s.api("/rooms/" + id, "stranger", {}, "GET")).status, 404);
  assert.equal((await s.api("/rooms/" + id + "/join", "stranger", { secret: "A".repeat(43) })).status, 403);
  assert.equal((await s.api("/rooms/" + id + "/state", "stranger", { sharing: true })).status, 404);
  assert.equal((await s.api("/rooms", null)).status, 401);
});
test("home creation is idempotent for the same identity", async () => {
  const s = setup(); const { id } = await s.home();
  assert.equal((await s.api("/rooms")).body.roomId, id);
  assert.equal([...s.store.docs.keys()].filter((p) => /^rooms\/[^/]+$/.test(p)).length, 1);
});
test("five-phone limit holds under six parallel joins", async () => {
  const s = setup(); const { id, secret } = await s.home();
  const results = await Promise.all(Array.from({ length: 6 }, (_, i) => s.join(id, secret, "phone" + i)));
  assert.equal(results.filter((r) => r.status === 200).length, 5);
  assert.equal(results.filter((r) => r.status === 409).length, 1);
  assert.equal(Object.keys((await s.store.get("rooms/" + id)).data.members).length, 5);
});
test("invitation expires after ten minutes and is stored only as a hash", async () => {
  const s = setup(); const { id, secret } = await s.home();
  assert.ok(!JSON.stringify((await s.store.get("roomInvites/" + id)).data).includes(secret));
  s.advance(600000);
  assert.equal((await s.join(id, secret)).status, 403);
});
test("revoke removes membership and invalidates the old invitation", async () => {
  const s = setup(); const { id, secret } = await s.home();
  await s.join(id, secret);
  await s.api("/rooms/" + id + "/revoke");
  assert.equal((await s.api("/rooms/" + id, "away", {}, "GET")).status, 404);
  assert.equal((await s.join(id, secret)).status, 403);
});
test("listeners cannot turn on a home microphone or issue invitations", async () => {
  const s = setup(); const { id, secret } = await s.home(); await s.join(id, secret);
  for (const action of ["state", "invite", "revoke", "alerts"]) {
    assert.equal((await s.api("/rooms/" + id + "/" + action, "away", { sharing: true })).status, 403);
  }
});
test("sessions require current sharing; one session per viewer replaces the previous one", async () => {
  const s = setup(); const { id, secret } = await s.home(); await s.join(id, secret);
  assert.equal((await s.api("/rooms/" + id + "/sessions", "away")).status, 409);
  await s.api("/rooms/" + id + "/state", "home", { sharing: true });
  const first = (await s.api("/rooms/" + id + "/sessions", "away")).body.sessionId;
  const second = (await s.api("/rooms/" + id + "/sessions", "away")).body.sessionId;
  assert.notEqual(first, second);
  assert.equal((await s.store.get("rooms/" + id)).data.activeSessions.away, second);
  assert.equal((await s.store.get("rooms/" + id + "/sessions/" + first)).data.ended, true);
  s.advance(120001);
  assert.equal((await s.api("/rooms/" + id + "/sessions", "away")).status, 409);
  assert.equal((await s.api("/rooms/" + id + "/ice", "away")).status, 409);
});
test("stopping sharing invalidates every active session", async () => {
  const s = setup(); const { id, secret } = await s.home(); await s.join(id, secret);
  await s.api("/rooms/" + id + "/state", "home", { sharing: true });
  await s.api("/rooms/" + id + "/sessions", "away");
  await s.api("/rooms/" + id + "/state", "home", { sharing: false });
  assert.deepEqual((await s.store.get("rooms/" + id)).data.activeSessions, {});
});
test("push is private, deduplicated, and can continue without an audio session", async () => {
  const s = setup(); const { id, secret } = await s.home(); await s.join(id, secret);
  await s.api("/rooms/" + id + "/device", "away", { kind: "fcm", token: "a".repeat(80) });
  await s.api("/rooms/" + id + "/state", "home", { sharing: true });
  const data = { id: "e".repeat(20), kind: "test" };
  assert.equal((await s.api("/rooms/" + id + "/alerts", "home", data)).body.sent, 1);
  assert.equal((await s.api("/rooms/" + id + "/alerts", "home", data)).body.duplicate, true);
  assert.equal(s.pushes.length, 1);
  assert.ok(!JSON.stringify((await s.api("/rooms/" + id, "away", {}, "GET")).body).includes("a".repeat(80)));
  await s.api("/rooms/" + id + "/device", "away", {}, "DELETE");
  s.advance(5001);
  assert.equal((await s.api("/rooms/" + id + "/alerts", "home", { ...data, id: "f".repeat(20) })).body.sent, 0);
});
test("leaving unregisters push and active sessions", async () => {
  const s = setup(); const { id, secret } = await s.home(); await s.join(id, secret);
  await s.api("/rooms/" + id + "/device", "away", { kind: "fcm", token: "a".repeat(80) });
  await s.api("/rooms/" + id + "/leave", "away");
  assert.equal(await s.store.get("rooms/" + id + "/devices/away"), null);
  assert.equal((await s.api("/rooms/" + id, "away", {}, "GET")).status, 404);
});
test("config excludes private keys and unexpected origins are rejected", async () => {
  const s = setup();
  const config = await s.api("/config", null, {}, "GET");
  assert.equal(config.status, 200);
  assert.ok(!JSON.stringify(config.body).includes("private"));
  assert.equal((await s.api("/rooms", "home", {}, "POST", { origin: "https://evil.example" })).status, 403);
});
test("web push cannot target private addresses or misleading Apple hostnames", () => {
  const keys = { p256dh: Buffer.concat([Buffer.from([4]), Buffer.alloc(64)]).toString("base64url"),
    auth: Buffer.alloc(16).toString("base64url") };
  for (const endpoint of ["https://127.0.0.1/push", "http://fcm.googleapis.com/push",
    "https://push.apple.com.evil.example/push", "https://fcm.googleapis.com:8443/push",
    "https://user:pass@fcm.googleapis.com/push"]) {
    assert.throws(() => validateSubscription({ endpoint, keys }), { status: 400 });
  }
  assert.equal(validateSubscription({ endpoint: "https://web.push.apple.com/Q", keys }).endpoint,
    "https://web.push.apple.com/Q");
});

// --- Authenticator (TOTP) protection --------------------------------------
// Either way in works: a pairing link, or the secret answer plus a current code.
const QA = { question: "Name of my first pet?", answer: "Rex the Dog" };
async function codeNow(s, secret, stepsAhead = 0) {
  return hotp(base32Decode(secret), counterAt(s.now()) + stepsAhead);
}
async function protectedHome(s, qa = QA) {
  const { id } = await s.home();
  const started = await s.api("/rooms/" + id + "/totp-start");
  const code = await codeNow(s, started.body.secret);
  const confirmed = await s.api("/rooms/" + id + "/totp-confirm", "home", { code });
  if (qa) assert.equal((await s.api("/rooms/" + id + "/answer-set", "home", qa)).status, 200);
  return { id, secret: started.body.secret, started, confirmed };
}
const freshInvite = async (s, id) => (await s.api("/rooms/" + id + "/invite")).body.secret;
const byCode = (s, answer, code, uid = "away") => s.api("/join-code", uid, { answer, code });

test("setup is for the owner only and needs no answer", async () => {
  const s = setup(); const { id, secret } = await s.home(); await s.join(id, secret);
  const started = await s.api("/rooms/" + id + "/totp-start");
  assert.equal(started.status, 200);
  assert.match(started.body.secret, /^[A-Z2-7]{32}$/);
  assert.ok(started.body.uri.startsWith("otpauth://totp/Home%20Listen%3ABedroom?secret="));
  assert.equal((await s.api("/rooms/" + id + "/totp-start", "away", QA)).status, 403);
  assert.equal((await s.api("/rooms/" + id + "/totp-start", "stranger", QA)).status, 404);
});

test("protection is not active until the owner proves the app shows matching codes", async () => {
  const s = setup(); const { id } = await s.home();
  const started = await s.api("/rooms/" + id + "/totp-start");
  assert.equal((await s.api("/rooms/" + id + "/answer-set", "home", QA)).status, 409);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, started.body.secret))).status, 403);
  assert.equal((await s.api("/rooms/" + id + "/totp-confirm", "home", { code: "000000" })).status, 403);
  assert.notEqual((await s.store.get("rooms/" + id)).data.totp, true);
});

test("a pairing link alone still joins when protection is on", async () => {
  const s = setup(); const { id, confirmed } = await protectedHome(s);
  assert.equal(confirmed.status, 200);
  assert.equal((await s.store.get("rooms/" + id)).data.totp, true);
  assert.equal((await s.join(id, await freshInvite(s, id))).status, 200);
});

test("the secret answer and a current code join without any link", async () => {
  const s = setup(); const { id, secret } = await protectedHome(s);
  s.advance(31000);
  const joined = await byCode(s, "  rex THE dog ", await codeNow(s, secret));
  assert.equal(joined.status, 200);
  assert.equal(joined.body.roomId, id);
  assert.equal((await s.store.get("rooms/" + id)).data.members.away, true);
  s.advance(30000);
  const code = await codeNow(s, secret);
  assert.equal((await byCode(s, "Rex the Dog", code.slice(0, 3) + " " + code.slice(3), "second")).status, 200);
});

test("a wrong answer, an unknown answer, or no code gets nothing", async () => {
  const s = setup(); const { id, secret } = await protectedHome(s);
  s.advance(31000);
  const code = await codeNow(s, secret);
  const unknown = await byCode(s, "Fluffy", code);
  assert.equal(unknown.status, 403);
  assert.equal(unknown.body.code, "totp_invalid");
  assert.equal((await byCode(s, "", code)).status, 403);
  const missing = await byCode(s, QA.answer, "");
  assert.equal(missing.body.code, "totp_required");
  assert.equal((await byCode(s, QA.answer, "000000")).body.code, "totp_invalid");
  assert.equal(Object.keys((await s.store.get("rooms/" + id)).data.members).length, 0);
});

test("a code can be used once, and the next one works", async () => {
  const s = setup(); const { secret } = await protectedHome(s);
  s.advance(31000);
  const code = await codeNow(s, secret);
  assert.equal((await byCode(s, QA.answer, code)).status, 200);
  const replay = await byCode(s, QA.answer, code, "second");
  assert.equal(replay.status, 403);
  assert.equal(replay.body.code, "totp_invalid");
  s.advance(30000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret), "second")).status, 200);
});

test("repeated wrong codes lock guessing, even for the right code, until the lock passes", async () => {
  const s = setup(); const { secret } = await protectedHome(s);
  s.advance(31000);
  for (let i = 0; i < 4; i++) assert.equal((await byCode(s, QA.answer, "000000")).body.code, "totp_invalid");
  const fifth = await byCode(s, QA.answer, "000000");
  assert.equal(fifth.status, 403);
  assert.equal(fifth.body.code, "totp_locked");
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret))).status, 429);
  s.advance(10 * 60000 + 1000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret))).status, 200);
});

test("two homes cannot share the same secret answer", async () => {
  const s = setup(); await protectedHome(s);
  const other = await protectedHome({ ...s, home: async () => {
    const made = await s.api("/rooms", "otherhome", { roomName: "Kitchen" });
    return { id: made.body.roomId };
  }, api: (path, uid = "otherhome", ...rest) => s.api(path, uid === "home" ? "otherhome" : uid, ...rest) }, null);
  const clash = await s.api("/rooms/" + other.id + "/answer-set", "otherhome", { question: "Different?", answer: "rex the dog" });
  assert.equal(clash.status, 409);
});

test("the secret, question and answer never appear in the room or the invitation", async () => {
  const s = setup(); const { id, secret } = await protectedHome(s);
  const visible = JSON.stringify((await s.store.get("rooms/" + id)).data) +
    JSON.stringify((await s.store.get("roomInvites/" + id)).data);
  for (const hidden of [secret, QA.answer.toLowerCase(), QA.question]) assert.ok(!visible.toLowerCase().includes(hidden.toLowerCase()));
});

test("turning protection off needs a code, then the answer stops working", async () => {
  const s = setup(); const { id, secret } = await protectedHome(s);
  assert.equal((await s.api("/rooms/" + id + "/totp-off", "home", {})).body.code, "totp_required");
  s.advance(31000);
  await s.join(id, await freshInvite(s, id));
  assert.equal((await s.api("/rooms/" + id + "/totp-off", "away", { code: await codeNow(s, secret) })).status, 403);
  const off = await s.api("/rooms/" + id + "/totp-off", "home", { code: await codeNow(s, secret) });
  assert.equal(off.status, 200);
  assert.equal((await s.store.get("rooms/" + id)).data.totp, false);
  assert.equal(await s.store.get("roomTotp/" + id), null);
  s.advance(30000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret), "second")).status, 403);
});

test("setup cannot be restarted while on, which would swap the secret under the owner", async () => {
  const s = setup(); const { id } = await protectedHome(s);
  assert.equal((await s.api("/rooms/" + id + "/totp-start", "home", QA)).status, 409);
});

test("the answer can be changed any time without touching the authenticator", async () => {
  const s = setup(); const { id, secret } = await protectedHome(s);
  const info = await s.api("/rooms/" + id + "/answer-info", "home", {});
  assert.deepEqual(info.body, { enabled: true, question: QA.question, hasAnswer: true });
  assert.equal((await s.api("/rooms/" + id + "/answer-set", "away", { question: "Q?x", answer: "zzz zzz" })).status, 404);
  const changed = await s.api("/rooms/" + id + "/answer-set", "home", { question: "Favourite street?", answer: "Maple Road" });
  assert.equal(changed.status, 200);
  s.advance(31000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret))).status, 403);
  s.advance(30000);
  assert.equal((await byCode(s, "maple road", await codeNow(s, secret))).status, 200);
  assert.equal((await s.store.get("roomTotp/" + id)).data.secret, secret);
});

test("clearing the answer closes the no-link way in but keeps the authenticator", async () => {
  const s = setup(); const { id, secret } = await protectedHome(s);
  assert.equal((await s.api("/rooms/" + id + "/answer-set", "home", { answer: "" })).body.hasAnswer, false);
  s.advance(31000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret))).status, 403);
  assert.equal((await s.api("/rooms/" + id + "/answer-info", "home", {})).body.enabled, true);
});

test("the home lists connected phones and can revoke just one", async () => {
  const s = setup(); const { id } = await s.home();
  await s.api("/rooms/" + id + "/join", "phoneA", { secret: await freshInvite(s, id), label: "Galaxy S24" });
  await s.api("/rooms/" + id + "/join", "phoneB", { secret: await freshInvite(s, id), label: "Web browser" });
  const list = await s.api("/rooms/" + id + "/members", "home", {});
  assert.deepEqual(list.body.members.map((m) => m.label).sort(), ["Galaxy S24", "Web browser"]);
  assert.equal((await s.api("/rooms/" + id + "/members", "phoneA", {})).status, 403);
  assert.equal((await s.api("/rooms/" + id + "/revoke-member", "phoneA", { uid: "phoneB" })).status, 403);
  assert.equal((await s.api("/rooms/" + id + "/revoke-member", "home", { uid: "nobody" })).status, 404);
  assert.equal((await s.api("/rooms/" + id + "/revoke-member", "home", { uid: "phoneB" })).status, 200);
  const after = await s.api("/rooms/" + id + "/members", "home", {});
  assert.deepEqual(after.body.members.map((m) => m.uid), ["phoneA"]);
  assert.equal((await s.api("/rooms/" + id, "phoneB", {}, "GET")).status, 404);
  assert.equal((await s.api("/rooms/" + id, "phoneA", {}, "GET")).status, 200);
});

test("a phone that joined with an answer and code shows up with its name", async () => {
  const s = setup(); const { secret } = await protectedHome(s);
  s.advance(31000);
  const joined = await s.api("/join-code", "phoneC", { answer: QA.answer, code: await codeNow(s, secret), label: "Pixel 8" });
  assert.equal(joined.status, 200);
  const list = await s.api("/rooms/" + joined.body.roomId + "/members", "home", {});
  assert.equal(list.body.members[0].label, "Pixel 8");
});

async function alertHome(options = {}) {
  const s = setup(options); const { id, secret } = await s.home();
  await s.join(id, secret);
  await s.api(`/rooms/${id}/device`, 'away', { kind: 'fcm', token: 'a'.repeat(80) });
  await s.api(`/rooms/${id}/state`, 'home', { sharing: true });
  return { ...s, id, secret, alert: (eventId = 'event_retry_123456789') =>
    s.api(`/rooms/${id}/alerts`, 'home', { id: eventId, kind: 'crying' }) };
}

test('expired token response cannot erase a refreshed registration', async () => {
  let s;
  s = await alertHome({ sendPush: async (device) => {
    if (device.token.startsWith('a')) {
      const refreshed = await s.api(`/rooms/${s.id}/device`, 'away', { kind: 'fcm', token: 'n'.repeat(80) });
      assert.equal(refreshed.status, 200);
      return { expired: true };
    }
    return { sent: true };
  } });
  assert.equal((await s.alert()).body.retryable, true);
  assert.equal((await s.store.get(`rooms/${s.id}/devices/away`)).data.token, 'n'.repeat(80));
  assert.equal((await s.store.get(`rooms/${s.id}`)).data.watchers.away, true);
  assert.equal((await s.alert()).body.sent, 1);
});

test('an unchanged expired registration clears its watcher without revoking membership', async () => {
  const s = await alertHome({ sendPush: async () => ({ expired: true }) });
  assert.equal((await s.alert()).body.retryable, false);
  assert.equal(await s.store.get(`rooms/${s.id}/devices/away`), null);
  const room = (await s.store.get(`rooms/${s.id}`)).data;
  assert.equal(room.watchers.away, undefined);
  assert.equal(room.members.away, true);
});

test('a failed push can retry the same event ID successfully', async () => {
  let attempts = 0;
  const s = await alertHome({ sendPush: async () => {
    if (++attempts === 1) throw new Error('provider unavailable');
    return { sent: true };
  } });
  const first = await s.alert();
  assert.equal(first.body.sent, 0); assert.equal(first.body.retryable, true);
  const second = await s.alert();
  assert.equal(second.body.sent, 1); assert.equal(second.body.retryable, false);
  assert.equal((await s.alert()).body.duplicate, true);
  assert.equal(s.pushes.length, 2);
  assert.equal(s.pushes[0].payload.id, s.pushes[1].payload.id);
});

test('partial delivery retries only failed recipients', async () => {
  let failures = 0;
  const s = await alertHome({ sendPush: async (device) => {
    if (device.token.startsWith('b') && failures++ === 0) return { sent: false };
    return { sent: true };
  } });
  await s.join(s.id, s.secret, 'second');
  await s.api(`/rooms/${s.id}/device`, 'second', { kind: 'fcm', token: 'b'.repeat(80) });
  assert.equal((await s.alert()).body.retryable, true);
  const retried = await s.alert();
  assert.equal(retried.body.sent, 2); assert.equal(retried.body.retryable, false);
  assert.equal(s.pushes.filter((p) => p.device.token.startsWith('a')).length, 1);
  assert.equal(s.pushes.filter((p) => p.device.token.startsWith('b')).length, 2);
});

test('concurrent retries cannot send the same pending alert twice', async () => {
  let release;
  const waiting = new Promise((resolve) => { release = resolve; });
  const s = await alertHome({ sendPush: async () => { await waiting; return { sent: true }; } });
  const first = s.alert();
  while (!s.pushes.length) await new Promise((resolve) => setTimeout(resolve, 1));
  const second = await s.alert();
  assert.equal(second.body.inProgress, true);
  assert.equal(s.pushes.length, 1);
  release();
  assert.equal((await first).body.retryable, false);
});

test('expired retries and revoked recipients are never pushed', async () => {
  const s = await alertHome({ sendPush: async () => ({ sent: false }) });
  await s.alert();
  await s.api(`/rooms/${s.id}/revoke-member`, 'home', { uid: 'away' });
  assert.equal((await s.alert()).body.retryable, false);
  assert.equal(s.pushes.length, 1);
  const other = await alertHome({ sendPush: async () => ({ sent: false }) });
  await other.alert(); other.advance(15 * 60_000);
  await other.api(`/rooms/${other.id}/state`, 'home', { sharing: true });
  assert.equal((await other.alert()).body.expired, true);
  assert.equal(other.pushes.length, 1);
});

test('Guardian allows alerts while blocking live audio and clearing sessions', async () => {
  const s = await alertHome();
  await s.api(`/rooms/${s.id}/sessions`, 'away');
  assert.equal((await s.api(`/rooms/${s.id}/state`, 'home', { sharing: true, audioAvailable: false })).status, 200);
  assert.equal((await s.api(`/rooms/${s.id}/sessions`, 'away')).body.code, 'guardian_only');
  assert.equal((await s.api(`/rooms/${s.id}/ice`, 'away')).status, 409);
  assert.deepEqual((await s.store.get(`rooms/${s.id}`)).data.activeSessions, {});
  assert.equal((await s.alert()).body.sent, 1);
});

test('alerts-only permissions are enforced even when a client requests audio', async () => {
  const s = await alertHome();
  await s.api(`/rooms/${s.id}/sessions`, 'away');
  assert.equal((await s.api(`/rooms/${s.id}/member-access`, 'away', { uid: 'away', role: 'caregiver' })).status, 403);
  assert.equal((await s.api(`/rooms/${s.id}/member-access`, 'home', { uid: 'away', role: 'alerts' })).status, 200);
  assert.equal((await s.api(`/rooms/${s.id}/sessions`, 'away')).body.code, 'alerts_only');
  assert.equal((await s.api(`/rooms/${s.id}/ice`, 'away')).status, 403);
  assert.equal((await s.alert()).body.sent, 1);
});

test('temporary guests need a bounded expiry and lose access when it passes', async () => {
  const s = await alertHome();
  const path = `/rooms/${s.id}/member-access`;
  assert.equal((await s.api(path, 'home', { uid: 'away', role: 'guest' })).status, 400);
  assert.equal((await s.api(path, 'home', { uid: 'away', role: 'guest', expiresAtMs: 100060000 })).status, 200);
  assert.equal((await s.api(`/rooms/${s.id}/sessions`, 'away')).status, 201);
  s.advance(60001);
  assert.equal((await s.api(`/rooms/${s.id}`, 'away', {}, 'GET')).status, 404);
  assert.equal((await s.api(`/rooms/${s.id}/sessions`, 'away')).status, 404);
  assert.equal((await s.alert()).body.sent, 0);
});

test("revoking everyone or leaving also forgets the stored device names", async () => {
  const s = setup(); const { id } = await s.home();
  await s.api("/rooms/" + id + "/join", "phoneA", { secret: await freshInvite(s, id), label: "Galaxy S24" });
  await s.api("/rooms/" + id + "/join", "phoneB", { secret: await freshInvite(s, id), label: "Web" });
  assert.equal((await s.api("/rooms/" + id + "/leave", "phoneB", {})).status, 200);
  assert.deepEqual(Object.keys((await s.store.get("roomMembers/" + id)).data), ["phoneA"]);
  assert.equal((await s.api("/rooms/" + id + "/revoke", "home", {})).status, 200);
  assert.equal(await s.store.get("roomMembers/" + id), null);
});

test("guessing at the no-link way in is limited per phone and per address", async () => {
  const s = setup(); await protectedHome(s);
  const ip = { "cf-connecting-ip": "203.0.113.9" };
  let last;
  for (let i = 0; i < 10; i++) last = await s.api("/join-code", "phone1", { answer: "nope" + i, code: "000000" }, "POST", ip);
  assert.equal(last.status, 403);
  const blocked = await s.api("/join-code", "phone1", { answer: "nope", code: "000000" }, "POST", ip);
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.code, "throttled");
  // New anonymous phones from the same address run into the address limit.
  let status = 0;
  for (let i = 0; i < 12; i++) status = (await s.api("/join-code", "burner" + i, { answer: "x" + i, code: "000000" }, "POST", ip)).status;
  assert.equal(status, 429);
  // Another address, and the window passing, are fine.
  assert.equal((await s.api("/join-code", "phone2", { answer: "nope", code: "000000" }, "POST", { "cf-connecting-ip": "198.51.100.4" })).status, 403);
  s.advance(10 * 60000 + 1000);
  assert.equal((await s.api("/join-code", "phone1", { answer: "nope", code: "000000" }, "POST", ip)).status, 403);
});

test("with TOTP_KEY the authenticator secret is stored encrypted and still works", async () => {
  const s = setup({ TOTP_KEY: "test-key-123" });
  const { id, secret } = await protectedHome(s);
  const stored = (await s.store.get("roomTotp/" + id)).data;
  assert.equal(stored.secret, undefined);
  assert.ok(typeof stored.secretEnc === "string" && !stored.secretEnc.includes(secret));
  s.advance(31000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret))).status, 200);
});

test("with ANSWER_PEPPER the stored answer key is not the plain hash", async () => {
  const plain = setup(); const peppered = setup({ ANSWER_PEPPER: "pepper-abc" });
  const a = await protectedHome(plain); const b = await protectedHome(peppered);
  assert.notEqual((await plain.store.get("roomTotp/" + a.id)).data.answerHash,
    (await peppered.store.get("roomTotp/" + b.id)).data.answerHash);
  peppered.advance(31000);
  assert.equal((await byCode(peppered, QA.answer, await codeNow(peppered, b.secret))).status, 200);
});

test("an answer saved before the pepper was set still works once, then is re-saved keyed", async () => {
  const s = setup();
  const { id, secret } = await protectedHome(s);
  const before = (await s.store.get("roomTotp/" + id)).data.answerHash;
  s.env.ANSWER_PEPPER = "added-later";
  s.advance(31000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret))).status, 200);
  const after = (await s.store.get("roomTotp/" + id)).data.answerHash;
  assert.notEqual(after, before);
  assert.equal(await s.store.get("answerIndex/" + before), null);
  s.advance(30000);
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret), "second")).status, 200);
});

test("a stranger locking the join path does not lock the owner out of their own settings", async () => {
  const s = setup(); const { id, secret } = await protectedHome(s);
  s.advance(31000);
  for (let i = 0; i < 5; i++) await byCode(s, QA.answer, "000000", "stranger");
  assert.equal((await byCode(s, QA.answer, await codeNow(s, secret), "stranger2")).status, 429);
  const off = await s.api("/rooms/" + id + "/totp-off", "home", { code: await codeNow(s, secret) });
  assert.equal(off.status, 200);
});
