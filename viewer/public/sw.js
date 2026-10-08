// Live audio and pairing secrets are never cached or recorded by this worker.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("push", (event) => {
  let data;
  try { data = event.data?.json(); } catch { return; }
  if (!data || typeof data.title !== "string") return;
  const sent = Number(data.sentAt);
  if (!Number.isFinite(sent) || Date.now() - sent > 120000) return;
  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of clients) client.postMessage({ type: "sound-alert", data });
    await self.registration.showNotification("Home Listen", {
      body: data.title.slice(0, 80) + " · " + String(data.room ?? "Home").slice(0, 32),
      icon: "/icon-192.png",
      badge: "/icon-192.png",
      tag: String(data.id ?? "home-listen"),
      data: { roomId: String(data.roomId ?? "") }
    });
  })());
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const client = windows.find((item) => new URL(item.url).origin === self.location.origin);
    if (client) {
      await client.focus();
      client.postMessage({ type: "open-alert" });
    } else await self.clients.openWindow("/");
    // Opening an alert never opens any microphone or starts playback.
  })());
});
