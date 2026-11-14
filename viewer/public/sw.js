// Live audio and pairing secrets are never cached or recorded by this worker.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

function roomAllowed(roomId) {
  return new Promise(resolve => {
    const request = indexedDB.open("home-listen-room-access", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("access", { keyPath: "id" });
    request.onerror = () => resolve(false);
    request.onsuccess = () => {
      const db = request.result, tx = db.transaction("access", "readonly");
      const row = tx.objectStore("access").get("rooms");
      let allowed = false;
      row.onsuccess = () => {
        // No saved snapshot means a legacy installation. An explicit empty
        // snapshot is a logout and must suppress notifications immediately.
        allowed = row.result == null || (Array.isArray(row.result.roomIds) && row.result.roomIds.includes(roomId));
      };
      tx.oncomplete = () => { db.close(); resolve(allowed); };
      tx.onerror = tx.onabort = () => { db.close(); resolve(false); };
    };
  });
}
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
      const roomId = String(data.roomId ?? ""), sourceId = String(data.id ?? Date.now());
      store.put({
        id: roomId ? `${roomId}|${sourceId}` : sourceId, sourceId, title: String(data.title).slice(0, 80), room: String(data.room ?? "Home").slice(0, 32),
        roomId, kind: String(data.kind ?? ""), sentAt: Number(data.sentAt)
      });
      // Prune in this same transaction, including when no page is open.
      const request = store.getAll();
      request.onsuccess = () => {
        const now = Date.now();
        const seen = new Set();
        let count = 0;
        const rows = request.result.sort((a, b) => b.sentAt - a.sentAt);
        for (const row of rows) {
          const identity = `${row.roomId ?? ""}|${row.sourceId ?? row.id}`;
          const valid = row.id && !seen.has(identity) && Number.isFinite(row.sentAt) &&
            row.sentAt >= now - 30 * 86_400_000 && row.sentAt <= now + 30_000 && count < 500;
          if (valid) { seen.add(identity); count++; } else store.delete(row.id);
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
    if (!await roomAllowed(data.roomId)) return;
    await saveAlert(data);
    const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of clients) client.postMessage({ type: "sound-alert", data });
    await self.registration.showNotification("Home Listen", {
      body: data.title.slice(0, 80) + " · " + String(data.room ?? "Home").slice(0, 32),
      icon: "/icon-192.png",
      badge: "/icon-192.png",
      tag: String(data.roomId ?? "") + ":" + String(data.id ?? "home-listen"),
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
      client.postMessage({ type: "open-alert", roomId: event.notification.data?.roomId });
    } else {
      const id = event.notification.data?.roomId;
      const path = typeof id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(id) ? "/?room=" + encodeURIComponent(id) : "/";
      await self.clients.openWindow(path);
    }
    // Opening an alert never opens any microphone or starts playback.
  })());
});
