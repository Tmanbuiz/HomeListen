// Sound-alert history kept on this phone only. The server does not store it.
// Each alert is metadata (what, when, which home): no audio, ever. The service
// worker saves alerts while the page is closed; this module reads them back.
export const MAX_EVENTS = 500;
export const MAX_DAYS = 30;
const DAY = 86_400_000;
const DB = "home-listen-history";
const STORE = "events";

/** Newest first, deduplicated by event id, within 30 days and 500 events. */
export function trim(list, now = Date.now()) {
  const cutoff = now - MAX_DAYS * DAY;
  const seen = new Set();
  const out = [];
  for (const event of [...list].sort((a, b) => b.sentAt - a.sentAt)) {
    if (!event?.id || seen.has(event.id) || !Number.isFinite(event.sentAt) ||
        event.sentAt > now + 30_000 || !(event.sentAt >= cutoff)) continue;
    seen.add(event.id);
    out.push(event);
    if (out.length >= MAX_EVENTS) break;
  }
  return out;
}

export function roomEvents(list, roomId) {
  return roomId ? list.filter((event) => event.roomId === roomId) : [];
}

export function filterEvents(list, { query = "", kind = "", days = 7, now = Date.now() } = {}) {
  const needle = query.trim().toLowerCase();
  const cutoff = now - days * DAY;
  return list.filter((event) =>
    event.sentAt >= cutoff &&
    (!kind || event.kind === kind) &&
    (!needle || `${event.title} ${event.kind} ${event.room}`.toLowerCase().includes(needle)));
}

const dayKey = (ms) => {
  const d = new Date(ms);
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
};

/** One entry per local day, oldest first, including days with no alerts. */
export function dailyCounts(list, days, now = Date.now()) {
  const counts = new Map();
  for (const event of list) counts.set(dayKey(event.sentAt), (counts.get(dayKey(event.sentAt)) ?? 0) + 1);
  const out = [];
  for (let i = days - 1; i >= 0; i--) {
    const key = dayKey(now - i * DAY);
    out.push({ day: key, count: counts.get(key) ?? 0 });
  }
  return out;
}

export function exportJson(list, now = Date.now()) {
  return JSON.stringify({
    exportedAt: new Date(now).toISOString(),
    note: "Alert metadata only. No audio is stored or exported.",
    events: list.map(({ id, title, room, kind, sentAt }) => ({ id, title, room, kind, at: new Date(sentAt).toISOString() }))
  }, null, 2);
}

function open() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE, { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
function run(mode, work) {
  return open().then((db) => new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const result = work(tx.objectStore(STORE));
    tx.oncomplete = () => { db.close(); resolve(result?.result); };
    tx.onerror = () => { db.close(); reject(tx.error); };
    tx.onabort = () => { db.close(); reject(tx.error); };
  }));
}

export async function loadAll() {
  try {
    return await open().then((db) => new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      const store = tx.objectStore(STORE);
      const request = store.getAll();
      let list = [];
      request.onsuccess = () => {
        list = trim(request.result);
        const keep = new Set(list.map((event) => event.id));
        for (const event of request.result) if (!keep.has(event.id)) store.delete(event.id);
      };
      tx.oncomplete = () => { db.close(); resolve(list); };
      tx.onerror = () => { db.close(); reject(tx.error); };
      tx.onabort = () => { db.close(); reject(tx.error); };
    }));
  } catch { return []; }
}
export async function saveEvent(event) {
  if (!event?.id) return;
  try {
    await run("readwrite", (store) => store.put({
      id: String(event.id), title: String(event.title ?? "").slice(0, 80), room: String(event.room ?? "Home").slice(0, 32),
      roomId: String(event.roomId ?? ""), kind: String(event.kind ?? ""), sentAt: Number(event.sentAt) || Date.now()
    }));
    await loadAll();
  } catch { /* history is a convenience; alerts still show */ }
}
export async function clearAll() {
  try { await run("readwrite", (store) => store.clear()); } catch { /* ignore */ }
}
