import { canInviteAway } from './access.js';

// Secrets exist only in the open dialog's memory. Room membership stays owned
// by the normal pairing flow; this controller never touches audio or identity.
export class RoomInvite {
  constructor({ current, create, changed = () => {}, now = () => Date.now() }) {
    Object.assign(this, { current, create, changed, now });
    this.generation = 0; this.state = { phase: 'closed' };
  }
  eligible(context = this.current()) {
    return Boolean(context?.supported && canInviteAway(context.room, context.uid));
  }
  epoch(context) { return context?.room?.shareInviteEpochs?.[context.uid] ?? null; }
  matches(context, saved = this.state.context) {
    return Boolean(saved && this.eligible(context) && context.id === saved.id &&
      context.uid === saved.uid && context.origin === saved.origin &&
      context.room.generation === saved.roomGeneration &&
      (context.room.invitationEpoch ?? 0) === saved.invitationEpoch);
  }
  sync() {
    if (this.state.phase === 'closed') return;
    const current = this.current();
    if (!this.matches(current)) { this.close(); return; }
    const epoch = this.epoch(current), saved = this.state.context;
    // A legacy member gets its first nonce in the issuance transaction. Bind
    // that response below; every later membership/access rotation invalidates it.
    if (this.state.phase === 'loading' && saved.initialEpoch == null) {
      if (saved.establishingEpoch != null && epoch !== saved.establishingEpoch) { this.close(); return; }
      if (epoch != null) saved.establishingEpoch = epoch;
    }
    if (saved.issuerEpoch != null && epoch === saved.issuerEpoch) saved.epochConfirmed = true;
    if (saved.issuerEpoch != null && epoch !== saved.issuerEpoch && (epoch != null || saved.epochConfirmed)) this.close();
    else if (this.state.phase === 'loading' && saved.initialEpoch != null && epoch !== saved.initialEpoch) this.close();
    else this.tick();
  }
  async open() {
    this.close();
    const current = this.current();
    if (!this.eligible(current)) return;
    const token = this.generation;
    const context = { id: current.id, name: current.name, uid: current.uid, origin: current.origin,
      roomGeneration: current.room.generation, invitationEpoch: current.room.invitationEpoch ?? 0,
      initialEpoch: this.epoch(current), issuerEpoch: null };
    this.state = { phase: 'loading', context }; this.changed();
    try {
      const result = await this.create(context.id);
      if (token !== this.generation) return;
      if (!this.matches(this.current(), context)) { this.close(); return; }
      const expiresAt = Date.parse(result.expiresAt), epoch = this.epoch(this.current());
      if (result.roomId !== context.id || !/^[A-Za-z0-9_-]{43}$/.test(result.secret) ||
          typeof result.issuerEpoch !== 'string' || !result.issuerEpoch ||
          !Number.isFinite(expiresAt) || expiresAt <= this.now() ||
          result.generation !== context.roomGeneration) {
        throw new Error('A valid sharing code could not be created. Try again.');
      }
      if ((epoch != null && epoch !== result.issuerEpoch) ||
          (context.initialEpoch != null && context.initialEpoch !== result.issuerEpoch) ||
          (context.establishingEpoch != null && (context.establishingEpoch !== result.issuerEpoch || epoch !== context.establishingEpoch))) {
        this.close(); return;
      }
      context.issuerEpoch = result.issuerEpoch;
      context.epochConfirmed = epoch === result.issuerEpoch;
      this.state = { phase: 'ready', context, expiresAt,
        url: `${context.origin}/#pair=${context.id}.${result.secret}` };
      this.changed();
    } catch (error) {
      if (token !== this.generation) return;
      if (!this.matches(this.current(), context)) { this.close(); return; }
      this.state = { phase: 'error', context, message: error.message ?? 'The sharing code could not be created.' };
      this.changed();
    }
  }
  tick() {
    if (this.state.phase === 'ready' && this.state.expiresAt <= this.now()) {
      this.state = { phase: 'expired', context: this.state.context }; this.changed();
    }
  }
  close() {
    this.generation++;
    if (this.state.phase === 'closed') return;
    this.state = { phase: 'closed' }; this.changed();
  }
}

// Only the scanner's video stream is stopped. Remote room audio and recording
// streams are never passed here or to the QR decoder's global stream helpers.
export class PairingScanner {
  constructor({ media, decoder, createVideo, result, problem, changed = () => {} }) {
    Object.assign(this, { media, decoder, createVideo, result, problem, changed });
    this.generation = 0; this.active = false; this.stream = null; this.controls = null;
    this.video = null;
  }
  stop() {
    this.generation++;
    const active = this.active; this.active = false;
    this.controls?.stop(); this.controls = null;
    this.stream?.getTracks().forEach(track => track.stop()); this.stream = null;
    if (this.video) this.video.srcObject = null;
    this.video = null;
    if (active) this.changed(false);
  }
  async start() {
    this.stop(); const token = this.generation;
    this.active = true; this.changed(true);
    let stream;
    try {
      const video = this.createVideo(); this.video = video;
      const reader = await this.decoder();
      if (token !== this.generation) return;
      stream = await this.media({ video: { facingMode: { ideal: 'environment' } }, audio: false });
      if (token !== this.generation) { stream.getTracks().forEach(track => track.stop()); return; }
      this.stream = stream;
      const controls = await reader.decodeFromStream(stream, video, (value, _error, handle) => {
        if (token !== this.generation || !value) return;
        const text = value.getText(); handle?.stop(); this.stop(); this.result(text);
      });
      if (token !== this.generation) { controls.stop(); return; }
      this.controls = controls;
    } catch (error) {
      if (token !== this.generation) return;
      stream?.getTracks().forEach(track => track.stop()); this.stop();
      this.problem(error.name === 'NotAllowedError' ? 'Camera access was not allowed. You can paste the pairing link instead.' :
        'The camera could not scan a code. You can paste the pairing link instead.');
    }
  }
}
