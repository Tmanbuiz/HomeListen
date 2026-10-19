import webpush from "web-push";
import { HttpError, authenticate, constantTimeEqual, digest, publicConfig, randomId, requireId, serviceToken } from "./security.js";
import { FirestoreStore } from "./store.js";
import { deliverAlert } from "./alert-delivery.js";
import { base32Decode, newSecret, otpauthUri, verifyTotp } from "./totp.js";

const LEASE_MS = 120_000;
const INVITE_MS = 10 * 60_000;
const SESSION_MS = 2 * 60 * 60_000;
// Wrong authenticator codes allowed before a room pauses guessing, and how
// long it pauses. Six digits is only a million guesses, so this is what stops
// someone holding a leaked invitation from simply trying them all.
const TOTP_MAX_FAILURES = 5;
const TOTP_LOCK_MS = 10 * 60_000;
const titles = {
  crying: "Possible crying",
  barking: "Possible dog sound",
  knocking: "Possible knock or doorbell",
  loud: "Possible loud sound",
  test: "Test alert"
};

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
}

async function body(request) {
  if (!request.headers.get("content-type")?.startsWith("application/json")) {
    throw new HttpError(415, "Send a JSON request.");
  }
  const length = Number(request.headers.get("content-length") ?? 0);
  if (length > 16_384) throw new HttpError(413, "This request is too large.");
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "This request has no body.");
  let size = 0;
  const chunks = [];
  while (true) {
    const result = await reader.read();
    if (result.done) break;
    size += result.value.byteLength;
    if (size > 16_384) {
      await reader.cancel();
      throw new HttpError(413, "This request is too large.");
    }
    chunks.push(result.value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (!value || Array.isArray(value) || typeof value !== "object") throw new Error("object");
    return value;
  } catch { throw new HttpError(400, "Invalid JSON request."); }
}

function roomName(value) {
  if (typeof value !== "string" || !value.trim() || value.trim().length > 32) {
    throw new HttpError(400, "Use a room name of 1 to 32 characters.");
  }
  return value.trim();
}

/**
 * Accepts [code] against a room's authenticator secret, or throws.
 *
 * A missing code is not a failure (the client simply has not asked yet), but a
 * wrong one counts toward the lock. A good code is spent: it cannot be used
 * again, and two requests racing with the same code cannot both win because
 * the update is compare-and-swap.
 */
const THROTTLE_WINDOW_MS = 10 * 60_000;
const THROTTLE_PER_IP = 20;
const THROTTLE_PER_PHONE = 10;

/**
 * Counts an attempt against [key] and refuses once [limit] is passed inside the
 * window. Anonymous sign-ins are free to create, so the address is limited as
 * well as the phone. The counters expire by themselves.
 */
async function throttle(store, key, limit, nowMs) {
  const path = "joinThrottle/" + await digest("throttle:" + key);
  for (let attempt = 0; attempt < 5; attempt++) {
    const doc = await store.get(path);
    const fresh = !doc || nowMs - doc.data.windowStartMs >= THROTTLE_WINDOW_MS;
    const count = fresh ? 1 : doc.data.count + 1;
    if (count > limit) {
      throw new HttpError(429, "Too many attempts. Wait a few minutes and try again.", "throttled");
    }
    const next = {
      count, windowStartMs: fresh ? nowMs : doc.data.windowStartMs,
      expiresAt: new Date(nowMs + THROTTLE_WINDOW_MS)
    };
    try { await store.put(path, next, doc ? doc.version : null); return; }
    catch (error) { if (error.status !== 409 || attempt === 4) throw error; }
  }
}

const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
const unb64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
async function sealKey(env) {
  if (!env.TOTP_KEY) return null;
  const raw = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("home-listen-totp:" + env.TOTP_KEY));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}
/** With TOTP_KEY set the authenticator secret is stored encrypted, never in the clear. */
async function sealSecret(env, secret) {
  const key = await sealKey(env);
  if (!key) return { secret };
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(secret)));
  return { secretEnc: b64([...iv, ...sealed]) };
}
async function openSecret(env, data) {
  if (!data.secretEnc) return data.secret;
  const key = await sealKey(env);
  if (!key) throw new HttpError(503, "The authenticator key is not configured on the server.");
  const bytes = unb64(data.secretEnc);
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  return new TextDecoder().decode(clear);
}

async function spendTotp(store, id, doc, code, nowMs, env = {}, { owner = false } = {}) {
  const data = doc.data;
  // The lock exists to stop strangers guessing. The signed-in owner is not
  // locked out of their own settings by someone else's wrong tries.
  if (!owner && (data.lockedUntilMs ?? 0) > nowMs) {
    throw new HttpError(429, "Too many wrong codes. Wait a few minutes and try again.", "totp_locked");
  }
  const clean = typeof code === "string" ? code.replace(/\s+/g, "") : "";
  if (!clean) {
    throw new HttpError(403, "Enter the 6-digit code from your authenticator app.", "totp_required");
  }
  const counter = await verifyTotp(base32Decode(await openSecret(env, data)), clean, nowMs, data.lastCounter ?? -1);
  const path = "roomTotp/" + id;
  if (counter == null && owner) {
    throw new HttpError(403, "That code is not right. Check the code in your authenticator app.", "totp_invalid");
  }
  if (counter == null) {
    const failures = (data.failures ?? 0) + 1;
    const locked = failures >= TOTP_MAX_FAILURES;
    try {
      await store.put(path, {
        ...data, failures: locked ? 0 : failures, lockedUntilMs: locked ? nowMs + TOTP_LOCK_MS : 0
      }, doc.version);
    } catch (error) { if (error.status !== 409) throw error; }
    throw new HttpError(403, locked
      ? "Too many wrong codes. Wait a few minutes and try again."
      : "That code is not right. Check the code in your authenticator app.",
    locked ? "totp_locked" : "totp_invalid");
  }
  try {
    await store.put(path, { ...data, lastCounter: counter, failures: 0, lockedUntilMs: 0 }, doc.version);
  } catch (error) {
    if (error.status !== 409) throw error;
    throw new HttpError(403, "That code was already used. Wait for the next one.", "totp_invalid");
  }
}

/** Lower-cased, trimmed, single-spaced, so "  Rex the DOG " matches "rex the dog". */
function normalizeAnswer(value) {
  if (typeof value !== "string") return "";
  return value.normalize("NFKC").toLowerCase().trim().split(/\s+/).join(" ");
}
const legacyAnswerKey = (answer) => digest("home-listen-answer:" + normalizeAnswer(answer));
/** With ANSWER_PEPPER set the stored key is an HMAC, so leaked records cannot be guessed offline. */
async function answerKey(env, answer) {
  if (!env.ANSWER_PEPPER) return legacyAnswerKey(answer);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.ANSWER_PEPPER),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(normalizeAnswer(answer))));
  return b64(mac).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Adds [uid] as a listener. The caller has already proved the right to join
 * (a valid invitation, or the secret answer plus an authenticator code).
 * Compare-and-swap keeps parallel joins from exceeding five phones.
 */
function deviceLabel(value) {
  const text = typeof value === "string" ? value.replace(/[\u0000-\u001f]/g, " ").trim().slice(0, 40) : "";
  return text || "Listening phone";
}

/** Remembers a name and time for the home phone's list of connected devices. */
async function rememberMember(store, id, uid, label, nowMs) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const doc = await store.get("roomMembers/" + id);
    const next = { ...(doc?.data ?? {}), [uid]: { label, joinedAtMs: nowMs } };
    try {
      await store.put("roomMembers/" + id, next, doc ? doc.version : null);
      return;
    } catch (error) { if (error.status !== 409 || attempt === 4) throw error; }
  }
}

async function addMember(store, id, uid, generation = null) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const room = await store.get("rooms/" + id);
    if (!room || (generation !== null && room.data.generation !== generation)) {
      throw new HttpError(403, "This pairing code was revoked.");
    }
    if (room.data.ownerUid === uid) throw new HttpError(400, "Use a different phone to listen.");
    if (!room.data.members[uid] && Object.keys(room.data.members).length >= 5) {
      throw new HttpError(409, "Five listening phones are already paired. Revoke a phone at home first.");
    }
    const data = { ...room.data, members: { ...room.data.members, [uid]: true } };
    try {
      await store.put("rooms/" + id, data, room.version);
      return data;
    } catch (error) { if (error.status !== 409 || attempt === 4) throw error; }
  }
}

async function readRoom(store, id, uid, ownerOnly = false) {
  const room = await store.get("rooms/" + id);
  if (!room || !(room.data.ownerUid === uid || room.data.members?.[uid] === true)) {
    throw new HttpError(404, "This home is not paired with your phone.");
  }
  if (ownerOnly && room.data.ownerUid !== uid) throw new HttpError(403, "Only the home phone can do this.");
  return room;
}

function requireSharing(room, now) {
  if (!room.sharing || !Number.isFinite(room.lastSeenMs) || now - room.lastSeenMs > LEASE_MS) {
    throw new HttpError(409, "The home phone is not sharing. Turn sharing on at home first.");
  }
}

function requireLiveAudio(room, uid, nowMs) {
  requireSharing(room, nowMs);
  if (room.audioAvailable === false) {
    throw new HttpError(409, 'Guardian is active at home. Live listening is off.', 'guardian_only');
  }
  const access = room.memberAccess?.[uid];
  if (room.ownerUid !== uid && (access?.role === 'alerts' ||
      (access?.expiresAtMs != null && access.expiresAtMs <= nowMs))) {
    throw new HttpError(403, 'This phone has alerts-only access.', 'alerts_only');
  }
}

async function mutateRoom(store, id, uid, ownerOnly, update) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const room = await readRoom(store, id, uid, ownerOnly);
    const next = await update(structuredClone(room.data));
    try {
      await store.put("rooms/" + id, next, room.version);
      return next;
    } catch (error) {
      if (error.status !== 409 || attempt === 4) throw error;
    }
  }
}

export function validateSubscription(subscription) {
  if (!subscription || typeof subscription !== "object") throw new HttpError(400, "Invalid push subscription.");
  let url;
  try { url = new URL(subscription.endpoint); } catch { throw new HttpError(400, "Invalid push endpoint."); }
  const allowed = url.hostname === "fcm.googleapis.com" ||
    url.hostname === "updates.push.services.mozilla.com" ||
    url.hostname.endsWith(".push.apple.com");
  if (!allowed || url.protocol !== "https:" || url.username || url.password ||
      (url.port && url.port !== "443") || url.hash || url.href.length > 4096) {
    throw new HttpError(400, "This push service is not supported.");
  }
  const keys = subscription.keys;
  if (!keys || typeof keys.p256dh !== "string" || typeof keys.auth !== "string" ||
      !/^[A-Za-z0-9_-]+={0,2}$/.test(keys.p256dh) ||
      !/^[A-Za-z0-9_-]+={0,2}$/.test(keys.auth) ||
      Buffer.from(keys.p256dh, "base64url").length !== 65 ||
      Buffer.from(keys.p256dh, "base64url")[0] !== 4 ||
      Buffer.from(keys.auth, "base64url").length !== 16) {
    throw new HttpError(400, "Invalid push encryption keys.");
  }
  return { endpoint: url.href, keys: { p256dh: keys.p256dh, auth: keys.auth } };
}

export async function generateIceServers(env) {
  const servers = [{ urls: ["stun:stun.cloudflare.com:3478"] }];
  if (env.ALLOW_TURN !== "true") return servers;
  if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) throw new HttpError(503, "The TURN relay has not been configured.");
  // Credentials outlive the two-hour session even without ICE renegotiation.
  const ttl = 7200;
  const response = await fetch(
    "https://rtc.live.cloudflare.com/v1/turn/keys/" + encodeURIComponent(env.TURN_KEY_ID) + "/credentials/generate-ice-servers",
    {
      method: "POST",
      headers: { authorization: "Bearer " + env.TURN_API_TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ ttl })
    }
  );
  const result = await response.json();
  if (!response.ok || !result.iceServers) throw new HttpError(503, "The relay could not issue a connection credential.");
  const returned = Array.isArray(result.iceServers) ? result.iceServers : [result.iceServers];
  for (const item of returned) {
    const urls = (Array.isArray(item.urls) ? item.urls : [item.urls]).filter((url) =>
      typeof url === "string" && /^(stun|turn|turns):/.test(url) && !/:53(?:\?|$)/.test(url)
    );
    if (urls.length) servers.push({ ...item, urls });
  }
  return servers;
}

export async function sendDevicePush(device, payload, env) {
  if (device.kind === "fcm") {
    const token = await serviceToken(env);
    const response = await fetch(
      "https://fcm.googleapis.com/v1/projects/" + encodeURIComponent(env.FIREBASE_PROJECT_ID) + "/messages:send",
      {
        method: "POST",
        signal: AbortSignal.timeout(10_000),
        headers: { authorization: "Bearer " + token, "content-type": "application/json" },
        body: JSON.stringify({ message: {
          token: device.token,
          notification: { title: "Home Listen", body: payload.title + " · " + payload.room },
          data: { ...payload, sentAt: String(payload.sentAt) },
          android: {
            priority: "HIGH",
            ttl: "120s",
            notification: {
              channel_id: "sound_watch",
              tag: payload.id,
              sound: "default"
            }
          },
          apns: {
            headers: { "apns-priority": "10" },
            payload: { aps: { sound: "default", "thread-id": payload.roomId } }
          }
        } })
      }
    );
    if (response.ok) return { sent: true };
    const failure = await response.json();
    const invalid = failure.error?.details?.some((detail) => detail.errorCode === "UNREGISTERED");
    if (invalid || response.status === 404) return { sent: false, expired: true };
    return { sent: false };
  }
  if (device.kind === "webpush") {
    if (!env.VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY) throw new HttpError(503, "Web push has not been configured.");
    const options = webpush.generateRequestDetails(device.subscription, JSON.stringify(payload), {
      TTL: 120,
      urgency: "high",
      vapidDetails: {
        subject: env.VAPID_SUBJECT || "https://github.com/Tmanbuiz/HomeListen",
        publicKey: env.VAPID_PUBLIC_KEY,
        privateKey: env.VAPID_PRIVATE_KEY
      }
    });
    const response = await fetch(options.endpoint, {
      method: options.method,
      signal: AbortSignal.timeout(10_000),
      headers: options.headers,
      body: options.body
    });
    return { sent: response.ok, expired: [404, 410].includes(response.status) };
  }
  return { sent: false };
}

export function createWorker(overrides = {}) {
  const storeFor = overrides.storeFor ?? ((env) => new FirestoreStore(env));
  const auth = overrides.authenticate ?? authenticate;
  const now = overrides.now ?? (() => Date.now());
  const push = overrides.sendPush ?? sendDevicePush;
  const ice = overrides.iceServers ?? generateIceServers;

  async function api(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    if (request.method === "GET" && path === "/api/health") {
      return json({
        ok: true,
        configured: Boolean(env.FIREBASE_PROJECT_ID && env.FIREBASE_API_KEY &&
          env.FIREBASE_WEB_APP_ID && env.FIREBASE_ANDROID_APP_ID && env.FIREBASE_SERVICE_ACCOUNT),
        version: "2.1.1"
      });
    }
    if (request.method === "GET" && path === "/api/config") return json({
      ...publicConfig(env), features: { guardian: true, retryAlerts: true, memberAccess: true }
    });
    const { uid } = await auth(request, env);
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(uid)) throw new HttpError(401, "Invalid phone identity.");
    const store = storeFor(env);

    if (path === "/api/rooms" && request.method === "POST") {
      const input = await body(request);
      const name = roomName(input.roomName ?? "Bedroom");
      const owner = await store.get("owners/" + uid);
      if (owner) {
        const existing = await readRoom(store, owner.data.roomId, uid, true);
        return json({ roomId: owner.data.roomId, room: existing.data });
      }
      const id = randomId();
      const room = {
        ownerUid: uid, roomName: name, members: {}, watchers: {}, activeSessions: {}, generation: 1,
        sharing: false, lastSeenMs: 0, createdAt: new Date(now()),
        battery: null, charging: null
      };
      try { await store.createHome(uid, id, room); } catch (error) {
        if (error.status !== 409) throw error;
        const winner = await store.get("owners/" + uid);
        if (!winner) throw error;
        const existing = await readRoom(store, winner.data.roomId, uid, true);
        return json({ roomId: winner.data.roomId, room: existing.data });
      }
      return json({ roomId: id, room }, 201);
    }
    if (path === "/api/join-code" && request.method === "POST") {
      // The way in without a link: the secret answer finds the home, and a
      // current authenticator code proves it is really the owner's.
      const input = await body(request);
      const refused = () => new HttpError(403, "That answer or code is not right.", "totp_invalid");
      await throttle(store, "uid:" + uid, THROTTLE_PER_PHONE, now());
      await throttle(store, "ip:" + (request.headers.get("cf-connecting-ip") ?? "unknown"), THROTTLE_PER_IP, now());
      if (!normalizeAnswer(input.answer)) throw refused();
      const currentKey = await answerKey(env, input.answer);
      let index = await store.get("answerIndex/" + currentKey);
      let upgrade = false;
      if (!index && env.ANSWER_PEPPER) {
        // An answer saved before the key was set: accept it once, then re-save it keyed.
        index = await store.get("answerIndex/" + await legacyAnswerKey(input.answer));
        upgrade = Boolean(index);
      }
      if (!index) throw refused();
      const roomId = index.data.roomId;
      const totp = await store.get("roomTotp/" + roomId);
      if (!totp?.data.enabled) throw refused();
      await spendTotp(store, roomId, totp, input.code, now(), env);
      if (upgrade) {
        const fresh = await store.get("roomTotp/" + roomId);
        try { await store.put("answerIndex/" + currentKey, { roomId }, null); }
        catch (error) { if (error.status !== 409) throw error; }
        await store.put("roomTotp/" + roomId, { ...fresh.data, answerHash: currentKey }, fresh.version);
        await store.delete("answerIndex/" + await legacyAnswerKey(input.answer));
      }
      const data = await addMember(store, roomId, uid);
      await rememberMember(store, roomId, uid, deviceLabel(input.label), now());
      return json({ roomId, room: data });
    }
    const match = /^\/api\/rooms\/([A-Za-z0-9_-]+)(?:\/([a-z-]+))?$/.exec(path);
    if (!match) throw new HttpError(404, "This endpoint does not exist.");
    const id = requireId(match[1]);
    const action = match[2] ?? "";

    if (action === "join" && request.method === "POST") {
      const input = await body(request);
      if (typeof input.secret !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(input.secret)) {
        throw new HttpError(400, "Invalid pairing invitation.");
      }
      const invite = await store.get("roomInvites/" + id);
      const hashed = await digest(input.secret);
      if (!invite || invite.data.expiresAt.getTime() <= now() ||
          !constantTimeEqual(invite.data.secretHash, hashed)) {
        throw new HttpError(403, "This pairing code has expired. Show a new code on the home phone.");
      }
      // A valid invitation authorizes this first membership; an authenticated
      // token alone does not.
      const data = await addMember(store, id, uid, invite.data.generation);
      await rememberMember(store, id, uid, deviceLabel(input.label), now());
      return json({ roomId: id, room: data });
    }

    const ownerOnly = ["invite", "state", "revoke", "alerts", "totp-start", "totp-confirm", "totp-off", "answer-info", "answer-set", "members", "revoke-member", "member-access"]
      .includes(action);
    const room = await readRoom(store, id, uid, ownerOnly);
    const access = room.data.memberAccess?.[uid];
    if (room.data.ownerUid !== uid && access?.expiresAtMs != null && access.expiresAtMs <= now()) {
      throw new HttpError(404, 'Your temporary access has expired. Ask the home phone owner to renew it.', 'access_expired');
    }

    if (action === "" && request.method === "GET") return json({ roomId: id, room: room.data });
    if (action === "invite" && request.method === "POST") {
      const secret = randomId(32);
      const expiresAt = new Date(now() + INVITE_MS);
      await store.put("roomInvites/" + id, {
        secretHash: await digest(secret), generation: room.data.generation, expiresAt
      });
      return json({ roomId: id, secret, expiresAt, generation: room.data.generation });
    }
    if (action === "totp-start" && request.method === "POST") {
      const existing = await store.get("roomTotp/" + id);
      if (existing?.data.enabled) {
        throw new HttpError(409, "Authenticator protection is already on. Turn it off first to set it up again.");
      }
      const secret = newSecret();
      // Not active yet: it only starts to apply once the owner proves the app
      // shows matching codes (totp-confirm), so a typo cannot lock them out.
      await store.put("roomTotp/" + id, {
        ...await sealSecret(env, secret), enabled: false, lastCounter: -1, failures: 0, lockedUntilMs: 0
      });
      return json({ secret, uri: otpauthUri(secret, room.data.roomName) });
    }
    if (action === "totp-confirm" && request.method === "POST") {
      const input = await body(request);
      const doc = await store.get("roomTotp/" + id);
      if (!doc) throw new HttpError(409, "Start authenticator setup first.");
      if (doc.data.enabled) return json({ enabled: true });
      await spendTotp(store, id, doc, input.code, now(), env, { owner: true });
      const fresh = await store.get("roomTotp/" + id);
      await store.put("roomTotp/" + id, { ...fresh.data, enabled: true }, fresh.version);
      await mutateRoom(store, id, uid, true, (data) => ({ ...data, totp: true }));
      return json({ enabled: true });
    }
    if (action === "members" && request.method === "POST") {
      const known = (await store.get("roomMembers/" + id))?.data ?? {};
      const members = Object.keys(room.data.members ?? {}).filter((member) => room.data.members[member] === true)
        .map((member) => ({
          uid: member,
          label: known[member]?.label ?? "Listening phone",
          joinedAtMs: known[member]?.joinedAtMs ?? null,
          listening: room.data.activeSessions?.[member] != null,
          role: room.data.memberAccess?.[member]?.role ?? 'caregiver',
          expiresAtMs: room.data.memberAccess?.[member]?.expiresAtMs ?? null
        }));
      return json({ members });
    }
    if (action === 'member-access' && request.method === 'POST') {
      const input = await body(request);
      if (room.data.members?.[input.uid] !== true) throw new HttpError(404, 'That phone is not paired.');
      if (!['caregiver', 'alerts', 'guest'].includes(input.role)) throw new HttpError(400, 'Choose a supported access role.');
      const expiry = input.expiresAtMs ?? null;
      if ((input.role === 'guest' && expiry === null) || (expiry !== null &&
          (!Number.isSafeInteger(expiry) || expiry <= now() || expiry > now() + 7 * 24 * 60 * 60_000))) {
        throw new HttpError(400, 'Temporary access must end within seven days.');
      }
      await mutateRoom(store, id, uid, true, (data) => {
        data.memberAccess = { ...data.memberAccess, [input.uid]: { role: input.role, expiresAtMs: expiry } };
        if (input.role === 'alerts') delete data.activeSessions[input.uid];
        return data;
      });
      return json({ updated: true });
    }
    if (action === "revoke-member" && request.method === "POST") {
      // Removes one listening phone. The others, and the pairing codes, are
      // untouched; the removed phone must be given a new code to come back.
      const input = await body(request);
      if (typeof input.uid !== "string" || room.data.members?.[input.uid] !== true) {
        throw new HttpError(404, "That phone is not paired.");
      }
      await mutateRoom(store, id, uid, true, (data) => {
        delete data.members[input.uid]; delete data.watchers[input.uid]; delete data.activeSessions[input.uid];
        if (data.memberAccess) delete data.memberAccess[input.uid];
        return data;
      });
      await store.delete("rooms/" + id + "/devices/" + input.uid);
      const known = await store.get("roomMembers/" + id);
      if (known) {
        const { [input.uid]: _gone, ...rest } = known.data;
        await store.put("roomMembers/" + id, rest, known.version);
      }
      return json({ revoked: true });
    }
    if (action === "answer-info" && request.method === "POST") {
      const doc = await store.get("roomTotp/" + id);
      return json({ enabled: Boolean(doc?.data.enabled), question: doc?.data.question ?? null, hasAnswer: Boolean(doc?.data.answerHash) });
    }
    if (action === "answer-set" && request.method === "POST") {
      // Changing the answer is separate from the authenticator itself: the app
      // stays linked, so the answer can be changed as often as wanted.
      const input = await body(request);
      const doc = await store.get("roomTotp/" + id);
      if (!doc?.data.enabled) throw new HttpError(409, "Turn on the authenticator first.");
      if (input.answer === "" || input.answer == null) {
        if (doc.data.answerHash) await store.delete("answerIndex/" + doc.data.answerHash);
        const { question: _q, answerHash: _a, ...rest } = doc.data;
        await store.put("roomTotp/" + id, rest, doc.version);
        return json({ hasAnswer: false });
      }
      const question = typeof input.question === "string" ? input.question.trim() : "";
      if (question.length < 3 || question.length > 80) {
        throw new HttpError(400, "Write a secret question of 3 to 80 characters.");
      }
      if (normalizeAnswer(input.answer).length < 3 || String(input.answer).length > 80) {
        throw new HttpError(400, "Use a secret answer of 3 to 80 characters.");
      }
      const answerHash = await answerKey(env, input.answer);
      if (answerHash !== doc.data.answerHash) {
        try {
          await store.put("answerIndex/" + answerHash, { roomId: id }, null);
        } catch (error) {
          if (error.status !== 409) throw error;
          const holder = await store.get("answerIndex/" + answerHash);
          if (holder?.data.roomId !== id) throw new HttpError(409, "Choose a different secret answer.");
        }
      }
      await store.put("roomTotp/" + id, { ...doc.data, question, answerHash }, doc.version);
      // Only after the new one is saved, so the home is never left without a way in.
      if (doc.data.answerHash && doc.data.answerHash !== answerHash) {
        await store.delete("answerIndex/" + doc.data.answerHash);
      }
      return json({ hasAnswer: true, question });
    }
    if (action === "totp-off" && request.method === "POST") {
      const input = await body(request);
      const doc = await store.get("roomTotp/" + id);
      if (!doc?.data.enabled) return json({ enabled: false });
      await spendTotp(store, id, doc, input.code, now(), env, { owner: true });
      if (doc.data.answerHash) await store.delete("answerIndex/" + doc.data.answerHash);
      await store.delete("roomTotp/" + id);
      await mutateRoom(store, id, uid, true, (data) => ({ ...data, totp: false }));
      return json({ enabled: false });
    }
    if (action === "revoke" && request.method === "POST") {
      await mutateRoom(store, id, uid, true, (data) => ({
        ...data, members: {}, memberAccess: {}, watchers: {}, activeSessions: {}, generation: data.generation + 1
      }));
      await store.delete("roomInvites/" + id);
      await store.delete("roomMembers/" + id);
      return json({ revoked: true });
    }
    if (action === "leave" && request.method === "POST") {
      if (room.data.ownerUid === uid) throw new HttpError(400, "The home phone cannot leave its own room.");
      await mutateRoom(store, id, uid, false, (data) => {
        delete data.members[uid]; delete data.watchers[uid]; delete data.activeSessions[uid];
        if (data.memberAccess) delete data.memberAccess[uid];
        return data;
      });
      await store.delete("rooms/" + id + "/devices/" + uid);
      const known = await store.get("roomMembers/" + id);
      if (known && uid in known.data) {
        const { [uid]: _gone, ...rest } = known.data;
        await store.put("roomMembers/" + id, rest, known.version);
      }
      return json({ left: true });
    }
    if (action === "state" && request.method === "POST") {
      const input = await body(request);
      if (typeof input.sharing !== "boolean") throw new HttpError(400, "Set sharing to true or false.");
      const name = input.roomName == null ? room.data.roomName : roomName(input.roomName);
      const battery = Number.isInteger(input.battery) && input.battery >= 0 && input.battery <= 100 ? input.battery : null;
      if (input.audioAvailable != null && typeof input.audioAvailable !== 'boolean') throw new HttpError(400, 'Invalid live audio setting.');
      const audioAvailable = input.sharing && (input.audioAvailable ?? true);
      const detector = input.detector && typeof input.detector === 'object' ? {
        enabled: input.detector.enabled === true,
        ready: input.detector.ready === true,
        windows: Number.isSafeInteger(input.detector.windows) ? Math.max(0, input.detector.windows) : 0,
        lastAudioMs: Number.isSafeInteger(input.detector.lastAudioMs) ? Math.min(now(), input.detector.lastAudioMs) : null,
      } : null;
      await mutateRoom(store, id, uid, true, (data) => ({
        ...data, sharing: input.sharing, roomName: name, battery, audioAvailable, detector,
        activeSessions: audioAvailable ? data.activeSessions : {},
        charging: typeof input.charging === "boolean" ? input.charging : null,
        lastSeenMs: now()
      }));
      return json({ sharing: input.sharing });
    }
    if (action === "ice" && request.method === "POST") {
      requireLiveAudio(room.data, uid, now());
      return json({ iceServers: await ice(env), refreshAfterSeconds: 1800 });
    }
    if (action === "sessions" && request.method === "POST") {
      if (room.data.ownerUid === uid) throw new HttpError(400, "Listen using another phone.");
      requireLiveAudio(room.data, uid, now());
      for (let attempt = 0; attempt < 5; attempt++) {
        const current = await readRoom(store, id, uid);
        requireLiveAudio(current.data, uid, now());
        const sessionId = randomId();
        const expiresAt = new Date(now() + SESSION_MS);
        const data = {
          ownerUid: current.data.ownerUid, viewerUid: uid,
          generation: current.data.generation, createdAt: new Date(now()), expiresAt,
          offer: null, answer: null, ended: false
        };
        try {
          await store.openSession(id, current, sessionId, data);
          return json({ sessionId, expiresAt, generation: data.generation }, 201);
        } catch (error) { if (error.status !== 409 || attempt === 4) throw error; }
      }
    }
    if (action === "device" && request.method === "POST") {
      if (room.data.ownerUid === uid) throw new HttpError(400, "Register alerts on your listening phone.");
      const input = await body(request);
      let device;
      if (input.kind === "fcm" && typeof input.token === "string" && input.token.length >= 32 &&
          input.token.length <= 4096 && /^[\x21-\x7e]+$/.test(input.token)) {
        device = { kind: "fcm", token: input.token };
      } else if (input.kind === "webpush") {
        if (!env.VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY) {
          throw new HttpError(503, "Web alerts have not been configured on this server.");
        }
        device = { kind: "webpush", subscription: validateSubscription(input.subscription) };
      } else throw new HttpError(400, "Invalid listening phone registration.");
      await store.put("rooms/" + id + "/devices/" + uid, { ...device, updatedAt: new Date(now()) });
      await mutateRoom(store, id, uid, false, (data) => ({
        ...data, watchers: { ...data.watchers, [uid]: true }
      }));
      return json({ alertsEnabled: true });
    }
    if (action === "device" && request.method === "DELETE") {
      await store.delete("rooms/" + id + "/devices/" + uid);
      await mutateRoom(store, id, uid, false, (data) => {
        delete data.watchers[uid]; return data;
      });
      return json({ alertsEnabled: false });
    }
    if (action === "alerts" && request.method === "POST") {
      requireSharing(room.data, now());
      const input = await body(request);
      const eventId = requireId(input.id);
      if (!Object.hasOwn(titles, input.kind)) throw new HttpError(400, "Invalid sound alert category.");
      const delivery = await deliverAlert({ store, id, uid, room: room.data, eventId, kind: input.kind,
        title: titles[input.kind], now, push, env,
        rateLimit: () => mutateRoom(store, id, uid, true, (data) => {
          if (now() - (data.lastAlertMs ?? 0) < 5000) throw new HttpError(429, 'Sounds are being grouped. Try again in a few seconds.');
          return { ...data, lastAlertMs: now() };
        }) });
      return json(delivery);
    }
    throw new HttpError(405, "This action is not supported.");
  }

  return {
    async fetch(request, env) {
      const origin = request.headers.get("origin");
      const ownOrigin = new URL(request.url).origin;
      const allowed = !origin || origin === ownOrigin || origin === env.PUBLIC_ORIGIN;
      let response;
      try {
        if (!allowed) throw new HttpError(403, "This site cannot access Home Listen.");
        if (request.method === "OPTIONS") response = new Response(null, { status: 204 });
        else if (new URL(request.url).pathname.startsWith("/api/")) response = await api(request, env);
        else if (env.ASSETS) response = await env.ASSETS.fetch(request);
        else response = new Response("Build the Home Listen web viewer before deploying.", { status: 503 });
      } catch (error) {
        response = json({
          error: error instanceof HttpError ? error.message : "The cloud server could not complete this request.",
          ...(error instanceof HttpError && error.code ? { code: error.code } : {})
        }, error instanceof HttpError ? error.status : 500);
      }
      response = new Response(response.body, response);
      response.headers.set("x-content-type-options", "nosniff");
      response.headers.set("referrer-policy", "no-referrer");
      response.headers.set("permissions-policy", "microphone=(), camera=(), geolocation=()");
      if (!new URL(request.url).pathname.startsWith("/api/")) {
        response.headers.set("content-security-policy",
          "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
          "connect-src 'self' https://*.googleapis.com https://*.firebaseapp.com https://*.firebaseio.com " +
          "wss://*.firebaseio.com; media-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'");
      }
      if (origin && allowed) {
        response.headers.set("access-control-allow-origin", origin);
        response.headers.set("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
        response.headers.set("access-control-allow-headers", "authorization, content-type");
        response.headers.set("vary", "Origin");
      }
      return response;
    },
    async scheduled(_event, env, ctx) {
      if (env.FIREBASE_SERVICE_ACCOUNT) ctx.waitUntil(storeFor(env).cleanup(now()));
    }
  };
}

export default createWorker();

