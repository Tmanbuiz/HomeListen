import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { verifyFirebaseToken, authenticate } from "../src/security.js";
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: "jwk" }), kid: "test-home-key" };
const now = 1000000000000;
const claims = { sub: "away", aud: "demo-home", iss: "https://securetoken.google.com/demo-home",
  exp: now / 1000 + 3600, iat: now / 1000, auth_time: now / 1000 };
function token(value = claims, header = { alg: "RS256", kid: jwk.kid }) {
  const data = [header, value].map((v) => Buffer.from(JSON.stringify(v)).toString("base64url")).join(".");
  return data + "." + sign("RSA-SHA256", Buffer.from(data), privateKey).toString("base64url");
}
const options = { now, fetch: async () => Response.json({ keys: [jwk] }) };
test("verifies a correctly signed Firebase identity", async () => {
  assert.deepEqual(await verifyFirebaseToken(token(), "demo-home", options), { uid: "away" });
});
test("rejects forged, expired, wrong-project, wrong-issuer and future tokens", async () => {
  const values = [{ ...claims, exp: now / 1000 }, { ...claims, aud: "another-project" },
    { ...claims, iss: "https://evil.example" }, { ...claims, iat: now / 1000 + 100 },
    { ...claims, auth_time: now / 1000 + 100 }];
  for (const value of values) await assert.rejects(verifyFirebaseToken(token(value), "demo-home", options), { status: 401 });
  await assert.rejects(verifyFirebaseToken(token().slice(0, -30) + "AAAA", "demo-home", options), { status: 401 });
  await assert.rejects(verifyFirebaseToken(token(claims, { alg: "none", kid: jwk.kid }), "demo-home", options), { status: 401 });
});
test("requires a bearer token", async () => {
  await assert.rejects(authenticate(new Request("https://home.example"), { FIREBASE_PROJECT_ID: "demo-home" }), { status: 401 });
});
