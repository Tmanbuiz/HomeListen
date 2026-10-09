import test from "node:test";
import assert from "node:assert/strict";
import { base32Decode, base32Encode, counterAt, hotp, newSecret, otpauthUri, verifyTotp } from "../src/totp.js";

// RFC 6238 appendix B, SHA-1, shared secret "12345678901234567890". The RFC
// lists 8-digit codes; the last six digits are the 6-digit code.
const secret = new TextEncoder().encode("12345678901234567890");
const vectors = [
  [59, "287082"], [1111111109, "081804"], [1111111111, "050471"],
  [1234567890, "005924"], [2000000000, "279037"], [20000000000, "353130"]
];

test("matches the RFC 6238 test vectors", async () => {
  for (const [seconds, code] of vectors) {
    assert.equal(await hotp(secret, counterAt(seconds * 1000)), code, "time " + seconds);
  }
});

test("base32 round-trips and matches the RFC 4648 examples", () => {
  assert.equal(base32Encode(new TextEncoder().encode("foobar")), "MZXW6YTBOI");
  assert.deepEqual([...base32Decode("MZXW6YTBOI")], [...new TextEncoder().encode("foobar")]);
  assert.deepEqual([...base32Decode("mzxw 6ytb oi===")], [...new TextEncoder().encode("foobar")]);
  const random = crypto.getRandomValues(new Uint8Array(20));
  assert.deepEqual([...base32Decode(base32Encode(random))], [...random]);
  assert.throws(() => base32Decode("not base32!"));
});

test("new secrets are 160 bits and not repeated", () => {
  const a = newSecret(), b = newSecret();
  assert.equal(base32Decode(a).length, 20);
  assert.notEqual(a, b);
});

test("a code is accepted one step either side, not two", async () => {
  const now = 1111111111 * 1000;
  const here = await hotp(secret, counterAt(now));
  const before = await hotp(secret, counterAt(now) - 1);
  const after = await hotp(secret, counterAt(now) + 1);
  const farBefore = await hotp(secret, counterAt(now) - 2);
  assert.equal(await verifyTotp(secret, here, now), counterAt(now));
  assert.equal(await verifyTotp(secret, before, now), counterAt(now) - 1);
  assert.equal(await verifyTotp(secret, after, now), counterAt(now) + 1);
  assert.equal(await verifyTotp(secret, farBefore, now), null);
});

test("a spent step cannot be used again, and junk is refused", async () => {
  const now = 1111111111 * 1000;
  const code = await hotp(secret, counterAt(now));
  const counter = await verifyTotp(secret, code, now);
  assert.equal(await verifyTotp(secret, code, now, counter), null);
  for (const junk of ["", "12345", "1234567", "abcdef", "12 345", null, 123456]) {
    assert.equal(await verifyTotp(secret, junk, now), null);
  }
});

test("the authenticator address carries the secret and standard settings", () => {
  const uri = otpauthUri("JBSWY3DPEHPK3PXP", "Bedroom");
  assert.ok(uri.startsWith("otpauth://totp/Home%20Listen%3ABedroom?"));
  assert.ok(uri.includes("secret=JBSWY3DPEHPK3PXP"));
  assert.ok(uri.includes("issuer=Home%20Listen"));
  assert.ok(uri.includes("digits=6") && uri.includes("period=30") && uri.includes("algorithm=SHA1"));
});
