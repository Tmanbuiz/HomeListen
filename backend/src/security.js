const encoder = new TextEncoder();
const keys = new Map();
const oauth = new Map();

export class HttpError extends Error {
  // [code] is a short machine-readable reason (for example "totp_required")
  // that clients use to decide what to ask the person, instead of matching text.
  constructor(status, message, code = undefined) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function base64url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

export function randomId(bytes = 18) {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

export async function digest(value) {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

export function constantTimeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

export function requireId(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(value)) {
    throw new HttpError(400, "Invalid identifier.");
  }
  return value;
}

export async function verifyFirebaseToken(token, projectId, options = {}) {
  const now = options.now ?? Date.now();
  const request = options.fetch ?? fetch;
  if (!projectId || typeof token !== "string" || token.length > 8192) {
    throw new HttpError(401, "Sign in to Home Listen first.");
  }
  try {
    const parts = token.split(".");
    if (parts.length !== 3) throw new Error("JWT");
    const header = JSON.parse(Buffer.from(parts[0], "base64url").toString());
    const claim = JSON.parse(Buffer.from(parts[1], "base64url").toString());
    const seconds = Math.floor(now / 1000);
    if (
      header.alg !== "RS256" || typeof header.kid !== "string" ||
      claim.aud !== projectId || claim.iss !== "https://securetoken.google.com/" + projectId ||
      typeof claim.sub !== "string" || claim.sub.length < 1 || claim.sub.length > 128 ||
      !Number.isInteger(claim.exp) || claim.exp <= seconds ||
      !Number.isInteger(claim.iat) || claim.iat > seconds + 30 ||
      !Number.isInteger(claim.auth_time) || claim.auth_time > seconds + 30
    ) throw new Error("claims");
    let cached = keys.get(header.kid);
    if (!cached || cached.expires <= now) {
      const response = await request(
        "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
      );
      if (!response.ok) throw new Error("keys");
      const body = await response.json();
      const jwk = body.keys.find((key) => key.kid === header.kid);
      if (!jwk) throw new Error("key");
      const key = await crypto.subtle.importKey(
        "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]
      );
      cached = { key, expires: now + 60 * 60 * 1000 };
      if (keys.size > 8) keys.clear();
      keys.set(header.kid, cached);
    }
    if (!await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", cached.key, Buffer.from(parts[2], "base64url"),
      encoder.encode(parts[0] + "." + parts[1])
    )) throw new Error("signature");
    return { uid: claim.sub };
  } catch {
    throw new HttpError(401, "Your sign-in has expired. Open Home Listen again.");
  }
}

export async function authenticate(request, env) {
  const match = /^Bearer ([^\s]+)$/.exec(request.headers.get("authorization") ?? "");
  if (!match) throw new HttpError(401, "Sign in to Home Listen first.");
  return verifyFirebaseToken(match[1], env.FIREBASE_PROJECT_ID);
}

export async function serviceToken(env, request = fetch) {
  if (!env.FIREBASE_SERVICE_ACCOUNT) throw new HttpError(503, "The cloud server needs its Firebase service account.");
  let account;
  try { account = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT); } catch {
    throw new HttpError(503, "The server's Firebase service account is invalid.");
  }
  if (account.project_id !== env.FIREBASE_PROJECT_ID || !account.client_email || !account.private_key) {
    throw new HttpError(503, "The server's Firebase project configuration does not match.");
  }
  const cached = oauth.get(account.client_email);
  if (cached && cached.expires > Date.now() + 60_000) return cached.token;
  const seconds = Math.floor(Date.now() / 1000);
  const header = base64url(encoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const payload = base64url(encoder.encode(JSON.stringify({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: seconds, exp: seconds + 3600
  })));
  const pem = account.private_key.replace(/-----[^-]+-----|\s/g, "");
  const key = await crypto.subtle.importKey(
    "pkcs8", Buffer.from(pem, "base64"),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(header + "." + payload));
  const response = await request("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: header + "." + payload + "." + base64url(new Uint8Array(signature))
    })
  });
  const body = await response.json();
  if (!response.ok || !body.access_token) throw new HttpError(503, "The cloud server could not authenticate with Firebase.");
  oauth.set(account.client_email, { token: body.access_token, expires: Date.now() + body.expires_in * 1000 });
  return body.access_token;
}

export function publicConfig(env) {
  if (!env.FIREBASE_PROJECT_ID || !env.FIREBASE_API_KEY || !env.FIREBASE_WEB_APP_ID) {
    throw new HttpError(503, "Home Listen cloud has not been configured yet.");
  }
  return {
    firebase: {
      apiKey: env.FIREBASE_API_KEY,
      projectId: env.FIREBASE_PROJECT_ID,
      appId: env.FIREBASE_WEB_APP_ID,
      androidAppId: env.FIREBASE_ANDROID_APP_ID ?? "",
      messagingSenderId: env.FIREBASE_MESSAGING_SENDER_ID ?? "",
      authDomain: env.FIREBASE_PROJECT_ID + ".firebaseapp.com"
    },
    vapidPublicKey: env.VAPID_PUBLIC_KEY ?? "",
    turnEnabled: env.ALLOW_TURN === "true" && Boolean(env.TURN_KEY_ID && env.TURN_API_TOKEN),
    maxViewers: 5
  };
}
