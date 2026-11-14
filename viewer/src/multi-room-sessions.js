// Owns receiver peers independently of the selected room. Switching changes
// audibility, never authorization or peer lifetime.
export class MultiRoomSessions {
  constructor({ registry, createSession, createAudio, allowed, onChanged = () => {}, onPeer = () => {}, onSelected = () => {}, onInterrupted = () => {} }) {
    Object.assign(this, { registry, createSession, createAudio, allowed, onChanged, onPeer, onSelected, onInterrupted });
    this.entries = new Map(); this.volume = 1; this.audible = false; this.suspended = false;
    for (const row of registry.rooms.values()) this.ensure(row.id);
  }
  ensure(id) {
    if (this.entries.has(id)) return this.entries.get(id);
    const audio = this.createAudio(); audio.muted = true; audio.volume = 0;
    const entry = { id, audio, room: null, session: null, pc: null, channel: null, state: "idle", problem: null, blocked: false, attempts: 0, generation: 0 };
    this.entries.set(id, entry); return entry;
  }
  get selected() { return this.entries.get(this.registry.selected) ?? null; }
  current(entry, session) { return this.entries.get(entry.id) === entry && entry.session === session; }
  notify() { this.onChanged(); }
  applyAudibility() {
    // Mute every element before unmuting the selected one: no overlap while
    // switching, even when browsers reserve the volume property for hardware.
    for (const entry of this.entries.values()) { entry.audio.muted = true; entry.audio.volume = 0; }
    const entry = this.selected;
    if (entry && this.audible && !this.suspended) { entry.audio.volume = this.volume; entry.audio.muted = this.volume === 0; }
  }
  async select(id, { play = true } = {}) {
    if (!this.registry.select(id)) return;
    this.audible = play; this.applyAudibility(); this.onSelected(this.selected); this.notify();
    if (play) await this.playSelected();
  }
  async playSelected() {
    const entry = this.selected; if (!entry) return;
    this.audible = true; this.applyAudibility();
    if (entry.audio.srcObject) {
      try { await entry.audio.play(); if (this.entries.get(entry.id) === entry) entry.blocked = false; }
      catch { if (this.entries.get(entry.id) === entry) entry.blocked = true; }
    }
    this.notify();
  }
  setVolume(value) { this.volume = Math.max(0, Math.min(1, Number(value) || 0)); this.applyAudibility(); this.notify(); }
  update(id, room, { reconcile = true } = {}) {
    const entry = this.entries.get(id); if (!entry) return;
    entry.room = room;
    if (room?.roomName) this.registry.update(id, { name: room.roomName });
    if (!this.allowed(room)) void this.stop(id, { remember: false, reason: "unavailable" });
    else if (reconcile) void this.start(id, { remember: false });
    this.notify();
  }
  async start(id, { remember = true } = {}) {
    const entry = this.entries.get(id);
    if (!entry) return;
    if (remember) this.registry.update(id, { listen: true });
    if (!this.registry.rooms.get(id)?.listen || this.suspended || !this.allowed(entry.room) || entry.session || (!remember && entry.retry)) return;
    clearTimeout(entry.retry); entry.retry = null; entry.problem = null;
    const generation = ++entry.generation;
    const session = this.createSession(id, {
      onPeer: (pc) => { if (this.current(entry, session)) { entry.pc = pc; this.onPeer(entry, pc); } },
      onTrack: async (stream) => {
        if (!this.current(entry, session)) return;
        entry.audio.srcObject = stream; this.applyAudibility();
        try { await entry.audio.play(); if (this.current(entry, session)) entry.blocked = false; }
        catch { if (this.current(entry, session)) entry.blocked = true; }
        this.notify();
      },
      onState: (state) => {
        if (!this.current(entry, session)) return;
        entry.state = state;
        if (state === "disconnected" && this.registry.selected === entry.id) this.onInterrupted(entry);
        if (state === "connected") entry.attempts = 0;
        this.notify();
      },
      onError: (error) => { if (this.current(entry, session)) void this.failed(entry, session, error); }
    });
    entry.session = session; entry.state = "connecting"; this.notify();
    try { await session.start(); }
    catch (error) { if (this.current(entry, session) && generation === entry.generation) await this.failed(entry, session, error); }
  }
  async failed(entry, session, error) {
    if (!this.current(entry, session)) return;
    entry.problem = error.message ?? "Connection lost.";
    await this.stop(entry.id, { remember: false, reason: "reconnecting" });
    if (this.entries.get(entry.id) !== entry || entry.session || this.suspended || !this.registry.rooms.get(entry.id)?.listen || !this.allowed(entry.room)) return;
    const generation = entry.generation;
    const delay = Math.min(30_000, 1000 * 2 ** Math.min(entry.attempts++, 5));
    entry.retry = setTimeout(() => {
      entry.retry = null;
      if (this.entries.get(entry.id) === entry && generation === entry.generation) void this.start(entry.id, { remember: false });
    }, delay);
    this.notify();
  }
  async stop(id, { remember = true, reason = "stopped" } = {}) {
    const entry = this.entries.get(id); if (!entry) return;
    if (remember) this.registry.update(id, { listen: false });
    entry.generation++; clearTimeout(entry.retry); entry.retry = null;
    const old = entry.session; entry.session = null; entry.pc = null; entry.channel = null; entry.state = reason; entry.blocked = false;
    entry.audio.muted = true; entry.audio.pause(); entry.audio.srcObject = null;
    if (this.registry.selected === id) this.onSelected(entry);
    this.notify(); await old?.stop();
  }
  async startAll({ audible = true } = {}) {
    this.suspended = false; this.audible = audible; this.applyAudibility();
    await Promise.all([...this.entries.keys()].map(id => this.start(id)));
  }
  async stopAll({ remember = true } = {}) { this.audible = false; await Promise.all([...this.entries.keys()].map(id => this.stop(id, { remember }))); }
  async suspend() { this.suspended = true; await this.stopAll({ remember: false }); }
  async resume() { this.suspended = false; this.audible = false; this.applyAudibility(); await Promise.all([...this.entries.keys()].map(id => this.start(id, { remember: false }))); }
  async remove(id, { pendingLeave = false } = {}) {
    const entry = this.entries.get(id); if (!entry) return;
    // Remove from the registry before any asynchronous teardown, so late peer
    // callbacks and pending reconnects cannot reauthorize it.
    this.registry.remove(id, { pendingLeave }); this.entries.delete(id);
    entry.generation++; clearTimeout(entry.retry); entry.audio.muted = true; entry.audio.pause(); entry.audio.srcObject = null;
    const old = entry.session; entry.session = null;
    this.applyAudibility(); this.onSelected(this.selected); this.notify(); await old?.stop(); entry.audio.remove?.();
  }
}
