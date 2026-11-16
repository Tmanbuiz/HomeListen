// Leave runs after already-started joins, while the UI disconnects immediately.
// Tickets remember which rooms were explicitly left during a request. They
// live only as long as that operation, so no permanent tombstone map is needed.
export class MembershipQueue {
  constructor() { this.tickets = new Set(); this.pending = new Set(); this.tail = Promise.resolve(); }
  begin() { const ticket = { left: new Set() }; this.tickets.add(ticket); return ticket; }
  finish(ticket) { this.tickets.delete(ticket); }
  logout(id) { for (const ticket of this.tickets) ticket.left.add(id); }
  cancelled(ticket, id) { return ticket.left.has(id); }
  async request(work) {
    // Capture already-queued leaves before registering this join. A later
    // flush may wait for this request, so it must not become our dependency.
    const before = this.tail;
    const request = before.catch(() => {}).then(work); this.pending.add(request);
    try { return await request; } finally { this.pending.delete(request); }
  }
  flush(work) {
    const joining = [...this.pending];
    this.tail = this.tail.catch(() => {}).then(async () => { await Promise.allSettled(joining); await work(); });
    return this.tail;
  }
}
