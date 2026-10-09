import webpush from "web-push";
import { HttpError, authenticate, constantTimeEqual, digest, publicConfig, randomId, requireId, serviceToken } from "./security.js";
import { FirestoreStore } from "./store.js";
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
  barking: "Possible barking",
  knocking: "Possible knocking",
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
async function spendTotp(store, id, doc, code, nowMs) {
  const data = doc.data;
  if ((data.lockedUntilMs ?? 0) > nowMs) {
    throw new HttpError(429, "Too many wrong codes. Wait a few minutes and try again.", "totp_locked");
  }
  const clean = typeof code === "string" ? code.replace(/\s+/g, "") : "";
  if (!clean) {
    throw new HttpError(403, "Enter the 6-digit code from your authenticator app.", "totp_required");
  }
  const counter = await verifyTotp(base32Decode(data.secret), clean, nowMs, data.lastCounter ?? -1);
  const path = "roomTotp/" + id;
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
        version: "2.0.0"
      });
    }
    if (request.method === "GET" && path === "/api/config") return json(publicConfig(env));
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
      // With authenticator protection on, a valid invitation is not enough: the
      // person joining must also give the current code from the owner's
      // authenticator app. The invitation is checked first, so the code cannot
      // be guessed without one.
      const totp = await store.get("roomTotp/" + id);
      if (totp?.data.enabled) await spendTotp(store, id, totp, input.code, now());
      // The invitation authorizes this first membership; an authenticated token
      // alone does not. Use compare-and-swap so parallel joins cannot exceed five.
      for (let attempt = 0; attempt < 5; attempt++) {
        const room = await store.get("rooms/" + id);
        if (!room || room.data.generation !== invite.data.generation) {
          throw new HttpError(403, "This pairing code was revoked.");
        }
        if (room.data.ownerUid === uid) throw new HttpError(400, "Use a different phone to listen.");
        if (!room.data.members[uid] && Object.keys(room.data.members).length >= 5) {
          throw new HttpError(409, "Five listening phones are already paired. Revoke a phone at home first.");
        }
        const data = { ...room.data, members: { ...room.data.members, [uid]: true } };
        try {
          await store.put("rooms/" + id, data, room.version);
          return json({ roomId: id, room: data });
        } catch (error) { if (error.status !== 409 || attempt === 4) throw error; }
      }
    }

    const ownerOnly = ["invite", "state", "revoke", "alerts", "totp-start", "totp-confirm", "totp-off"]
      .includes(action);
    const room = await readRoom(store, id, uid, ownerOnly);

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
      await store.put("roomTotp/" + id, { secret, enabled: false, lastCounter: -1, failures: 0, lockedUntilMs: 0 });
      return json({ secret, uri: otpauthUri(secret, room.data.roomName) });
    }
    if (action === "totp-confirm" && request.method === "POST") {
      const input = await body(request);
      const doc = await store.get("roomTotp/" + id);
      if (!doc) throw new HttpError(409, "Start authenticator setup first.");
      if (doc.data.enabled) return json({ enabled: true });
      await spendTotp(store, id, doc, input.code, now());
      const fresh = await store.get("roomTotp/" + id);
      await store.put("roomTotp/" + id, { ...fresh.data, enabled: true }, fresh.version);
      await mutateRoom(store, id, uid, true, (data) => ({ ...data, totp: true }));
      return json({ enabled: true });
    }
    if (action === "totp-off" && request.method === "POST") {
      const input = await body(request);
      const doc = await store.get("roomTotp/" + id);
      if (!doc?.data.enabled) return json({ enabled: false });
      await spendTotp(store, id, doc, input.code, now());
      await store.delete("roomTotp/" + id);
      await mutateRoom(store, id, uid, true, (data) => ({ ...data, totp: false }));
      return json({ enabled: false });
    }
    if (action === "revoke" && request.method === "POST") {
      await mutateRoom(store, id, uid, true, (data) => ({
        ...data, members: {}, watchers: {}, activeSessions: {}, generation: data.generation + 1
      }));
      await store.delete("roomInvites/" + id);
      return json({ revoked: true });
    }
    if (action === "leave" && request.method === "POST") {
      if (room.data.ownerUid === uid) throw new HttpError(400, "The home phone cannot leave its own room.");
      await mutateRoom(store, id, uid, false, (data) => {
        delete data.members[uid]; delete data.watchers[uid]; delete data.activeSessions[uid]; return data;
      });
      await store.delete("rooms/" + id + "/devices/" + uid);
      return json({ left: true });
    }
    if (action === "state" && request.method === "POST") {
      const input = await body(request);
      if (typeof input.sharing !== "boolean") throw new HttpError(400, "Set sharing to true or false.");
      const name = input.roomName == null ? room.data.roomName : roomName(input.roomName);
      const battery = Number.isInteger(input.battery) && input.battery >= 0 && input.battery <= 100 ? input.battery : null;
      await mutateRoom(store, id, uid, true, (data) => ({
        ...data, sharing: input.sharing, roomName: name, battery,
        activeSessions: input.sharing ? data.activeSessions : {},
        charging: typeof input.charging === "boolean" ? input.charging : null,
        lastSeenMs: now()
      }));
      return json({ sharing: input.sharing });
    }
    if (action === "ice" && request.method === "POST") {
      requireSharing(room.data, now());
      return json({ iceServers: await ice(env), refreshAfterSeconds: 1800 });
    }
    if (action === "sessions" && request.method === "POST") {
      if (room.data.ownerUid === uid) throw new HttpError(400, "Listen using another phone.");
      requireSharing(room.data, now());
      for (let attempt = 0; attempt < 5; attempt++) {
        const current = await readRoom(store, id, uid);
        requireSharing(current.data, now());
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
      const receiptPath = "rooms/" + id + "/alertReceipts/" + eventId;
      const previous = await store.get(receiptPath);
      if (previous) return json({ duplicate: true, sent: 0 });
      await mutateRoom(store, id, uid, true, (data) => {
        if (now() - (data.lastAlertMs ?? 0) < 5000) throw new HttpError(429, "Sounds are being grouped. Try again in a few seconds.");
        return { ...data, lastAlertMs: now() };
      });
      await store.put(receiptPath, { expiresAt: new Date(now() + 60 * 60_000) }, null);
      const payload = {
        id: eventId, title: titles[input.kind], room: room.data.roomName,
        roomId: id, kind: input.kind, sentAt: now()
      };
      const outcomes = await Promise.all(Object.keys(room.data.members).map(async (viewerUid) => {
        const path = "rooms/" + id + "/devices/" + viewerUid;
        const device = await store.get(path);
        if (!device) return { sent: false, registered: false };
        try {
          const result = await push(device.data, payload, env);
          if (result.expired) {
            await store.delete(path);
            await mutateRoom(store, id, uid, true, (data) => {
              delete data.watchers[viewerUid]; return data;
            });
          }
          return { ...result, registered: true };
        } catch { return { sent: false, registered: true }; }
      }));
      return json({
        sent: outcomes.filter((result) => result.sent).length,
        registered: outcomes.filter((result) => result.registered).length
      });
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
