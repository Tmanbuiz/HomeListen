// Development-only platform check. Production entry remains src/worker.js.
import { createECDH } from "node:crypto";
import webpush from "web-push";
export default {
  async fetch() {
    const encryption = createECDH("prime256v1");
    const publicKey = encryption.generateKeys().toString("base64url");
    const vapid = webpush.generateVAPIDKeys();
    const result = webpush.generateRequestDetails({
      endpoint: "https://web.push.apple.com/test",
      keys: { p256dh: publicKey, auth: Buffer.alloc(16, 1).toString("base64url") }
    }, JSON.stringify({ title: "Test alert", room: "Bedroom" }), {
      TTL: 120, vapidDetails: { subject: "https://github.com/Tmanbuiz/HomeListen",
        publicKey: vapid.publicKey, privateKey: vapid.privateKey }
    });
    return Response.json({ ok: result.body.length > 0 && Boolean(result.headers.Authorization) });
  }
};
