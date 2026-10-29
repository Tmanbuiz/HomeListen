export class RecordingSubscription {
  constructor({ send, isOpen, onChanged = () => {} }) {
    Object.assign(this, { send, isOpen, onChanged });
    this.enabled = this.closed = this.ready = this.exhausted = false;
    this.generation = 0;
  }
  request(enabled) {
    if (this.closed) return;
    clearTimeout(this.retry);
    const generation = ++this.generation;
    this.enabled = enabled; this.ready = this.exhausted = false; this.attempts = 0;
    if (enabled) this.attempt(generation);
    else if (this.isOpen()) this.transmit('unsubscribe');
    this.onChanged();
  }
  transmit(message) {
    try { Promise.resolve(this.send(message)).catch(() => {}); } catch { /* retry while open */ }
  }
  opened() { this.request(this.enabled); }
  attempt(generation) {
    if (this.closed || !this.enabled || this.ready || generation !== this.generation || !this.isOpen()) return;
    if (this.attempts >= 5) { this.exhausted = true; this.onChanged(); return; }
    this.attempts++; this.transmit('subscribe');
    this.retry = setTimeout(() => this.attempt(generation), 1000);
  }
  acknowledge() {
    if (this.closed || !this.enabled) return;
    if (this.ready && !this.exhausted) return;
    this.ready = true; this.exhausted = false; clearTimeout(this.retry); this.onChanged();
  }
  close() { this.closed = true; this.generation++; clearTimeout(this.retry); }
}
