import { RoomInvite, PairingScanner } from './room-invites.js';

// QR encoding/decoding happens locally and is loaded only after an explicit
// Share/Scan action. No pairing secret is sent to an image service.
let qrModule;
const qr = () => qrModule ??= import('./qr-codec.js');

export function roomSharingUI({ current, api, pair, validPairing, notice, document: doc = document }) {
  const byId = id => doc.getElementById(id);
  const dialog = byId('room-share-dialog'), scanDialog = byId('room-scan-dialog');
  let shown = null, feedback = '';
  const invite = new RoomInvite({ current, create: id => api(`/rooms/${id}/share-invite`, {}), changed: render });
  const scanner = new PairingScanner({
    media: constraints => navigator.mediaDevices.getUserMedia(constraints),
    decoder: async () => (await qr()).createReader(),
    createVideo: () => {
      // ZXing may finish attaching an old stream after cancellation. Its
      // finalizer must only ever clear that attempt's detached preview.
      const previous = byId('scan-video'), video = previous.cloneNode(false);
      video.muted = true; video.playsInline = true;
      previous.replaceWith(video); return video;
    },
    changed: active => { if (!active && scanDialog.open) scanDialog.close(); },
    result: value => {
      if (!validPairing(value)) { notice('Scan a Home Listen pairing code from this server.', true); return; }
      void pair(value).catch(() => notice('This code could not add a room. It may have expired or already been used.', true));
    },
    problem: text => notice(text, true)
  });
  function ready() { invite.sync(); return invite.state.phase === 'ready' ? invite.state : null; }
  async function renderQr(state) {
    try {
      const module = await qr();
      if (invite.state !== state || state.expiresAt <= Date.now()) return;
      const svg = module.createCode(state.url);
      const white = doc.createElementNS('http://www.w3.org/2000/svg', 'rect');
      white.setAttribute('width', '100%'); white.setAttribute('height', '100%'); white.setAttribute('fill', '#fff');
      svg.prepend(white); svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', `Pairing code for ${state.context.name}`);
      byId('share-qr').replaceChildren(svg);
    } catch {
      if (invite.state === state) byId('share-feedback').textContent = 'The QR code could not be drawn. You can copy the link below.';
    }
  }
  function render() {
    const state = invite.state;
    if (state.phase === 'closed') {
      shown = null; feedback = ''; byId('share-link').value = ''; byId('share-qr').replaceChildren();
      if (dialog.open) dialog.close(); return;
    }
    if (!dialog.open) dialog.showModal();
    byId('share-room-name').textContent = `Share ${state.context.name}`;
    const available = state.phase === 'ready';
    byId('share-link').hidden = !available; byId('share-link-label').hidden = !available;
    byId('share-link').value = available ? state.url : '';
    byId('copy-room-link').disabled = !available;
    byId('send-room-link').hidden = typeof navigator.share !== 'function';
    byId('send-room-link').disabled = !available;
    byId('renew-room-link').disabled = state.phase === 'loading';
    byId('share-feedback').textContent = feedback;
    if (state.phase === 'loading') byId('share-expiry').textContent = 'Creating a private pairing code…';
    else if (state.phase === 'error') byId('share-expiry').textContent = state.message;
    else if (state.phase === 'expired') byId('share-expiry').textContent = 'This code has expired. Create a new code to add a phone.';
    else {
      const seconds = Math.max(0, Math.ceil((state.expiresAt - Date.now()) / 1000));
      byId('share-expiry').textContent = `One new phone can use this code. Expires in ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}.`;
    }
    if (shown !== state) {
      shown = state; feedback = ''; byId('share-qr').replaceChildren();
      if (available) void renderQr(state);
    }
  }
  byId('share-room-button').addEventListener('click', () => { void invite.open(); });
  byId('renew-room-link').addEventListener('click', () => { void invite.open(); });
  byId('close-room-share').addEventListener('click', () => invite.close());
  dialog.addEventListener('cancel', () => invite.close());
  dialog.addEventListener('close', () => { if (!dialog.open) invite.close(); });
  byId('copy-room-link').addEventListener('click', async () => {
    const state = ready(); if (!state) return;
    try { await navigator.clipboard.writeText(state.url); feedback = 'Pairing link copied.'; }
    catch { feedback = 'Select the link below and copy it using your browser.'; }
    if (invite.state === state) render();
  });
  byId('send-room-link').addEventListener('click', async () => {
    const state = ready(); if (!state) return;
    try { await navigator.share({ title: `Home Listen · ${state.context.name}`, url: state.url }); }
    catch (error) { if (error.name !== 'AbortError' && invite.state === state) { feedback = 'Use Copy link to share this code.'; render(); } }
  });
  byId('scan-room-button').addEventListener('click', () => {
    if (!navigator.mediaDevices?.getUserMedia) { notice('Camera scanning is unavailable here. Paste the pairing link instead.', true); return; }
    scanDialog.showModal(); void scanner.start();
  });
  byId('close-room-scan').addEventListener('click', () => scanner.stop());
  scanDialog.addEventListener('cancel', () => scanner.stop());
  scanDialog.addEventListener('close', () => { if (!scanDialog.open) scanner.stop(); });
  doc.addEventListener('visibilitychange', () => { if (doc.hidden) { invite.close(); scanner.stop(); } });
  window.addEventListener('pagehide', () => { invite.close(); scanner.stop(); });
  setInterval(() => { invite.sync(); if (invite.state.phase === 'ready') render(); }, 1000);
  return {
    sync() {
      invite.sync();
      byId('share-room-button').disabled = !invite.eligible();
      const context = current();
      byId('share-room-hint').textContent = !context?.supported ? 'Sharing from an away phone needs an updated Home Listen server.' :
        invite.eligible(context) ? 'Add another listening phone with a QR code or link. This phone stays connected.' :
          'This phone’s access does not allow adding another listener. Ask the home phone owner for a pairing code.';
    },
    close() { invite.close(); scanner.stop(); }
  };
}
