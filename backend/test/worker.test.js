import test from "node:test";
import assert from "node:assert/strict";
import { createWorker, validateSubscription } from "../src/worker.js";
import { HttpError } from "../src/security.js";

class MemoryStore {
  docs = new Map(); counter = 0;
  async get(path) { return structuredClone(this.docs.get(path) ?? null); }
  async put(path, data, version) {
    const old = this.docs.get(path);
    if ((version === null && old) || (version && old?.version !== version)) throw new HttpError(409, "conflict");
    this.docs.set(path, { data: structuredClone(data), version: String(++this.counter) });
  }
  async delete(path) { this.docs.delete(path); }
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
function setup() {
  const store = new MemoryStore(); let time = 100000000;
  const pushes = [];
  const env = { FIREBASE_PROJECT_ID: "demo-home", FIREBASE_API_KEY: "public-key",
    FIREBASE_WEB_APP_ID: "public-web-id", FIREBASE_ANDROID_APP_ID: "public-android-id",
    FIREBASE_SERVICE_ACCOUNT: "private-secret", VAPID_PUBLIC_KEY: "public-vapid", VAPID_PRIVATE_KEY: "private-vapid" };
  const worker = createWorker({
    storeFor: () => store, now: () => time,
    authenticate: async (request) => {
      const uid = request.headers.get("authorization")?.replace("Bearer ", "");
      if (!uid) throw new HttpError(401, "auth required");
      return { uid };
    },
    sendPush: async (device, payload) => { pushes.push({ device, payload }); return { sent: true }; },
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
  return { store, api, home, join, pushes, advance: (ms) => time += ms };
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
