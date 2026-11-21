import test from "node:test";
import assert from "node:assert/strict";
import { generateIceServers } from "../src/worker.js";

const STUN = [{ urls: ["stun:stun.cloudflare.com:3478"] }];
const relayEnv = { ALLOW_TURN: "true", TURN_KEY_ID: "key-id", TURN_API_TOKEN: "relay-token" };

function recorder() {
  const warnings = [], requests = [];
  return { warnings, requests, warn: (message) => warnings.push(message) };
}

test("relay off offers direct connections without calling Cloudflare", async () => {
  const r = recorder();
  const servers = await generateIceServers({ ALLOW_TURN: "false", TURN_KEY_ID: "k", TURN_API_TOKEN: "t" }, {
    request: async () => assert.fail("no relay request expected"), warn: r.warn
  });
  assert.deepEqual(servers, STUN);
  assert.deepEqual(r.warnings, []);
});

test("relay on without secrets falls back to direct connections and warns", async () => {
  for (const env of [{ ALLOW_TURN: "true" }, { ALLOW_TURN: "true", TURN_KEY_ID: "k" }, { ALLOW_TURN: "true", TURN_API_TOKEN: "t" }]) {
    const r = recorder();
    const servers = await generateIceServers(env, { request: async () => assert.fail("no relay request expected"), warn: r.warn });
    assert.deepEqual(servers, STUN);
    assert.equal(r.warnings.length, 1);
    assert.match(r.warnings[0], /TURN_KEY_ID and TURN_API_TOKEN/);
  }
});

test("a rejected, malformed or unreachable relay falls back without leaking the token", async () => {
  const failures = [
    async () => new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 }),
    async () => new Response(JSON.stringify({}), { status: 201 }),
    async () => new Response("<html>bad gateway</html>", { status: 502 }),
    async () => { throw new TypeError("network down"); },
    async () => { throw new DOMException("The operation timed out.", "TimeoutError"); }
  ];
  for (const request of failures) {
    const r = recorder();
    const servers = await generateIceServers(relayEnv, { request, warn: r.warn });
    assert.deepEqual(servers, STUN);
    assert.equal(r.warnings.length, 1);
    assert.match(r.warnings[0], /Offering direct connections only/);
    assert.ok(!r.warnings[0].includes("relay-token"));
  }
});

test("a working relay adds its servers after STUN and drops port 53", async () => {
  const r = recorder();
  const servers = await generateIceServers(relayEnv, {
    request: async (url, init) => {
      r.requests.push({ url, init });
      return new Response(JSON.stringify({ iceServers: [{
        urls: ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:3478?transport=udp",
          "turn:turn.cloudflare.com:53?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp", "http://bad"],
        username: "user", credential: "secret"
      }] }), { status: 201 });
    },
    warn: r.warn
  });
  assert.deepEqual(r.warnings, []);
  assert.equal(r.requests.length, 1);
  assert.equal(r.requests[0].url, "https://rtc.live.cloudflare.com/v1/turn/keys/key-id/credentials/generate-ice-servers");
  assert.equal(r.requests[0].init.headers.authorization, "Bearer relay-token");
  assert.deepEqual(JSON.parse(r.requests[0].init.body), { ttl: 7200 });
  assert.ok(r.requests[0].init.signal instanceof AbortSignal);
  assert.deepEqual(servers, [...STUN, {
    urls: ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"],
    username: "user", credential: "secret"
  }]);
});
