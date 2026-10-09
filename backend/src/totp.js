// Time-based one-time passwords (RFC 6238), the 6-digit codes shown by Google
// Authenticator, Microsoft Authenticator, Authy and similar apps.
//
// Used as a second factor when a phone joins a home: the invitation link says
// "this phone may try to join", the code says "and the owner is the one who
// approved it". HMAC-SHA1, 30-second steps and 6 digits are what every
// authenticator app supports, so nothing here is configurable.

const STEP_SECONDS = 30;
const DIGITS = 6;
const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32Encode(bytes) {
  let bits = 0, value = 0, out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(text) {
  const clean = String(text).toUpperCase().replace(/=+$/, "").replace(/\s+/g, "");
  let bits = 0, value = 0;
  const out = [];
  for (const char of clean) {
    const index = ALPHABET.indexOf(char);
    if (index < 0) throw new Error("Invalid base32 text.");
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

/** A fresh 160-bit secret, the size RFC 4226 recommends. */
export function newSecret() {
  return base32Encode(crypto.getRandomValues(new Uint8Array(20)));
}

/** The code for one counter value. Exposed so tests can check the RFC vectors. */
export async function hotp(secretBytes, counter) {
  const key = await crypto.subtle.importKey(
    "raw", secretBytes, { name: "HMAC", hash: "SHA-1" }, false, ["sign"]
  );
  const message = new Uint8Array(8);
  // A counter beyond 2^32 steps is far past anything a clock produces.
  new DataView(message.buffer).setUint32(4, counter >>> 0);
  new DataView(message.buffer).setUint32(0, Math.floor(counter / 2 ** 32));
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
  const offset = mac[mac.length - 1] & 15;
  const binary = ((mac[offset] & 127) << 24) | (mac[offset + 1] << 16) |
    (mac[offset + 2] << 8) | mac[offset + 3];
  return String(binary % 10 ** DIGITS).padStart(DIGITS, "0");
}

export function counterAt(nowMs) {
  return Math.floor(nowMs / 1000 / STEP_SECONDS);
}

/**
 * Checks [code] against the current step and one step either side, which
 * covers a phone clock that is up to half a minute off. Returns the matching
 * counter, or null.
 *
 * [lastCounter] is the newest step already accepted for this secret. A code
 * is only valid for a step after it, so a code seen once (over a shoulder, or
 * in a captured request) cannot be used again.
 */
export async function verifyTotp(secretBytes, code, nowMs, lastCounter = -1) {
  if (typeof code !== "string" || !/^\d{6}$/.test(code)) return null;
  const now = counterAt(nowMs);
  for (const counter of [now, now - 1, now + 1]) {
    if (counter <= lastCounter) continue;
    if (await timingSafeEqual(await hotp(secretBytes, counter), code)) return counter;
  }
  return null;
}

async function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

/** The address an authenticator app turns into a QR code or a typed secret. */
export function otpauthUri(secret, roomName) {
  const label = encodeURIComponent("Home Listen:" + roomName);
  return "otpauth://totp/" + label + "?secret=" + secret +
    "&issuer=" + encodeURIComponent("Home Listen") + "&algorithm=SHA1&digits=" + DIGITS +
    "&period=" + STEP_SECONDS;
}
