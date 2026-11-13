// Saved membership references only. Invitation secrets and identity tokens never
// belong in the room switcher's storage.
export const ROOM_STORAGE_KEY = "homelisten-rooms-v1";
export const LEGACY_ROOM_KEY = "homelisten-room-v2";
const validId = (id) => typeof id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(id);
const cleanName = (name) => typeof name === "string" ? name.trim().slice(0, 64) || "Your room" : "Your room";

export class RoomRegistry {
  constructor(storage, onError = () => {}) {
    Object.assign(this, { storage, onError });
    this.rooms = new Map(); this.pendingLeaves = new Set(); this.selected = null;
    try {
      const raw = storage.getItem(ROOM_STORAGE_KEY);
      if (raw != null) {
        const saved = JSON.parse(raw);
        for (const row of Array.isArray(saved.rooms) ? saved.rooms.slice(0, 100) : []) {
          if (validId(row?.id)) this.rooms.set(row.id, { id: row.id, name: cleanName(row.name), listen: row.listen === true, alerts: row.alerts === true });
        }
        for (const id of Array.isArray(saved.pendingLeaves) ? saved.pendingLeaves : []) if (validId(id)) this.pendingLeaves.add(id);
        if (this.rooms.has(saved.selected)) this.selected = saved.selected;
      } else {
        const legacy = storage.getItem(LEGACY_ROOM_KEY);
        if (validId(legacy)) { this.rooms.set(legacy, { id: legacy, name: "Your room", listen: true, alerts: false }); this.selected = legacy; }
      }
    } catch (error) { onError(error); }
    this.selected ??= this.rooms.keys().next().value ?? null;
  }
  save() {
    try {
      this.storage.setItem(ROOM_STORAGE_KEY, JSON.stringify({ version: 1, selected: this.selected, rooms: [...this.rooms.values()], pendingLeaves: [...this.pendingLeaves] }));
      // Keep only the currently selected reference for older installed pages.
      if (this.selected) this.storage.setItem(LEGACY_ROOM_KEY, this.selected);
      else this.storage.removeItem(LEGACY_ROOM_KEY);
      return true;
    } catch (error) { this.onError(error); return false; }
  }
  add(id, name = "Your room") {
    if (!validId(id)) throw new Error("Invalid room reference.");
    const row = this.rooms.get(id) ?? { id, name: cleanName(name), listen: true, alerts: false };
    this.rooms.set(id, { ...row, name: cleanName(name) }); this.pendingLeaves.delete(id);
    this.selected = id; this.save(); return this.rooms.get(id);
  }
  update(id, changes) {
    const row = this.rooms.get(id); if (!row) return;
    const next = { ...row };
    if (typeof changes.name === "string") next.name = cleanName(changes.name);
    if (typeof changes.listen === "boolean") next.listen = changes.listen;
    if (typeof changes.alerts === "boolean") next.alerts = changes.alerts;
    this.rooms.set(id, next); this.save();
  }
  select(id) { if (!this.rooms.has(id)) return false; this.selected = id; this.save(); return true; }
  remove(id, { pendingLeave = false } = {}) {
    this.rooms.delete(id); if (pendingLeave) this.pendingLeaves.add(id);
    if (this.selected === id) this.selected = this.rooms.keys().next().value ?? null;
    this.save();
  }
  async flushLeaves(leave) {
    // A caller awaits this before pairing, so a delayed logout cannot revoke a
    // newly granted membership to the same room.
    for (const id of [...this.pendingLeaves]) {
      try { await leave(id); this.pendingLeaves.delete(id); this.save(); } catch { /* retry when online */ }
    }
  }
}

// Shared with the service worker through IndexedDB. An explicit empty list
// suppresses late notifications after the last room was logged out.
export async function savePushRooms(ids, factory = globalThis.indexedDB) {
  if (!factory) return;
  await new Promise((resolve, reject) => {
    const request = factory.open("home-listen-room-access", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("access", { keyPath: "id" });
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result, tx = db.transaction("access", "readwrite");
      tx.objectStore("access").put({ id: "rooms", roomIds: ids.filter(validId) });
      tx.oncomplete = () => { db.close(); resolve(); };
      tx.onerror = tx.onabort = () => { db.close(); reject(tx.error); };
    };
  });
}
