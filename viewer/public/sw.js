// Live audio and pairing secrets are never cached or recorded by this worker.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
// Alerts are saved here as well as shown, so the app's history is complete even
// when it was closed. Metadata only; the same database the page reads.
function saveAlert(data) {
  return new Promise((resolve) => {
    const open = indexedDB.open("home-listen-history", 1);
    open.onupgradeneeded = () => open.result.createObjectStore("events", { keyPath: "id" });
    open.onerror = () => resolve();
    open.onsuccess = () => {
      const db = open.result;
      const tx = db.transaction("events", "readwrite");
      const store = tx.objectStore("events");
      store.put({
        id: String(data.id ?? Date.now()), title: String(data.title).slice(0, 80), room: String(data.room ?? "Home").slice(0, 32),
        roomId: String(data.roomId ?? ""), kind: String(data.kind ?? ""), sentAt: Number(data.sentAt)
      });
      // Prune in this same transaction, including when no page is open.
      const request = store.getAll();
      request.onsuccess = () => {
        const now = Date.now();
        const seen = new Set();
        let count = 0;
        const rows = request.result.sort((a, b) => b.sentAt - a.sentAt);
        for (const row of rows) {
          const valid = row.id && !seen.has(row.id) && Number.isFinite(row.sentAt) &&
            row.sentAt >= now - 30 * 86_400_000 && row.sentAt <= now + 30_000 && count < 500;
          if (valid) { seen.add(row.id); count++; } else store.delete(row.id);
        }
      };
      tx.oncomplete = () => { db.close(); resolve(); };
      tx.onerror = () => { db.close(); resolve(); };
      tx.onabort = () => { db.close(); resolve(); };
    };
  });
}
self.addEventListener("push", (event) => {
  let data;
  try { data = event.data?.json(); } catch { return; }
  if (!data || typeof data.title !== "string") return;
  const sent = Number(data.sentAt);
  if (!Number.isFinite(sent) || Date.now() - sent > 120000 || sent > Date.now() + 30_000) return;
  event.waitUntil((async () => {
    await saveAlert(data);
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
