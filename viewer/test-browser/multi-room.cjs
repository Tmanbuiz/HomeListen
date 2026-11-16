const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');

const ROOM_A = 'room_a_0123456789';
const ROOM_B = 'room_b_0123456789';
const SAVED_ROOMS = [
  { id: ROOM_A, name: 'Bedroom', listen: true, alerts: true },
  { id: ROOM_B, name: 'Children room', listen: true, alerts: true }
];
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};

// Each browser has its own identity, storage, peers and fake server. Block any
// request outside the exact loopback origin before handling a fixture response.
async function fixture(browser, base, { uid = 'away', savedRooms = SAVED_ROOMS } = {}) {
  const context = await browser.newContext({ viewport: { width: 1100, height: 900 }, serviceWorkers: 'block' });
  const page = await context.newPage();
  const errors = [], requests = [], leaves = [], invites = [], joins = [], blocked = [], failures = [], plans = [];
  let serial = 0;
  page.on('pageerror', error => errors.push(String(error)));
  const modules = {
    app: 'export function initializeApp(config){return {config}}',
    auth: `const user={uid:${JSON.stringify(uid)},getIdToken:async()=>${JSON.stringify('fake-token-' + uid)}};
      const auth={currentUser:user,authStateReady:async()=>{}};
      export function getAuth(){window.__auth=auth;return auth}
      export async function signInAnonymously(){auth.currentUser=user;return {user}}
      export async function signOut(){window.__signOuts++;auth.currentUser=null}`,
    firestore: `
      export function getFirestore(){return {database:true}}
      function path(args){const first=args.shift();return (first.path?first.path+'/':'')+args.join('/')}
      export function doc(...args){return {path:path(args)}}
      export function collection(...args){return {path:path(args)}}
      function snapshot(data){return {metadata:{fromCache:false},exists:()=>Boolean(data),data:()=>structuredClone(data),docChanges:()=>[]}}
      const listeners=new Map();
      window.__emitRoom=id=>{for(const next of listeners.get(id)??[])next(snapshot(window.__rooms[id]))};
      export function onSnapshot(ref,...args){
        const next=typeof args[0]==='function'?args[0]:args[1],parts=ref.path.split('/');let active=true;
        if(parts.length===2){if(!listeners.has(parts[1]))listeners.set(parts[1],new Set());listeners.get(parts[1]).add(next)}
        setTimeout(()=>{if(active)next(snapshot(parts.length===2?window.__rooms[parts[1]]:{answer:'test-answer',ended:false}))},10);
        return()=>{active=false;if(parts.length===2)listeners.get(parts[1]).delete(next)}
      }
      export async function updateDoc(){} export async function addDoc(){return {id:'candidate'}}
      export const Timestamp={fromDate:d=>d};`
  };
  await context.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.origin !== base && !['blob:', 'data:'].includes(url.protocol)) {
      blocked.push(url.origin); return route.abort();
    }
    const module = /\/node_modules\/\.vite\/deps\/firebase_(app|auth|firestore)\.js$/.exec(url.pathname)?.[1];
    if (module) return route.fulfill({ contentType: 'text/javascript', body: modules[module] });
    if (!url.pathname.startsWith('/api/')) return route.continue();
    const requestPath = url.pathname;
    requests.push({ path: requestPath, method: request.method(), authorization: request.headers().authorization });
    try {
      let body;
      if (requestPath === '/api/config') {
        body = { firebase: { projectId: 'demo-homelisten', appId: 'test', apiKey: 'public-test' }, vapidPublicKey: '', features: { awayInvites: true } };
      } else {
        assert.equal(request.headers().authorization, 'Bearer fake-token-' + uid);
        const [, id, action] = /^\/api\/rooms\/([A-Za-z0-9_-]+)(?:\/([a-z-]+))?$/.exec(requestPath) ?? [];
        assert.ok(SAVED_ROOMS.some(room => room.id === id), 'Unexpected fixture room');
        if (action === 'share-invite') {
          assert.equal(request.method(), 'POST');
          const plan = plans.shift();
          if (plan?.roomId) assert.equal(id, plan.roomId);
          body = { roomId: id, secret: String.fromCharCode(65 + invites.length).repeat(43), generation: 1,
            issuerEpoch: 'fake-away-nonce', expiresAt: new Date(Date.now() + (plan?.expiresInMs ?? 600000)).toISOString() };
          invites.push(body); plan?.started.resolve(body);
          if (plan?.held) await plan.held.promise;
          await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
          plan?.finished.resolve(); return;
        } else if (action === 'join') {
          assert.equal(request.method(), 'POST');
          const data = request.postDataJSON();
          assert.match(data.secret, /^[A-Za-z0-9_-]{43}$/);
          joins.push({ roomId: id, secret: data.secret, uid });
          const room = await page.evaluate(({ id, uid }) => {
            const room = window.__rooms[id];
            room.members[uid] = true; room.watchers[uid] = true;
            return room;
          }, { id, uid });
          body = { roomId: id, room };
        } else if (action === 'sessions') body = { sessionId: `session_${uid}_${++serial}`, expiresAt: new Date(Date.now() + 7200000).toISOString() };
        else if (action === 'ice') body = { iceServers: [] };
        else if (action === 'leave') { leaves.push(id); body = { left: true }; }
        else if (action === 'device') body = { registered: true };
        else if (!action && request.method() === 'GET') body = { roomId: id, room: await page.evaluate(id => window.__rooms[id], id) };
        else throw new Error('Unexpected fixture API operation: ' + requestPath);
      }
      await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
    } catch (error) {
      failures.push(String(error));
      await route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: 'Browser fixture failed' }) });
    }
  });
  await context.addInitScript(({ rooms, savedRooms }) => {
    if (!localStorage.getItem('qa-seeded')) {
      if (savedRooms.length) localStorage.setItem('homelisten-rooms-v1', JSON.stringify({ version: 1, selected: savedRooms[0].id, rooms: savedRooms, pendingLeaves: [] }));
      localStorage.setItem('qa-seeded', 'true');
    }
    window.__rooms = Object.fromEntries(rooms.map(room => [room.id, {
      roomName: room.name, ownerUid: 'home_' + room.id, generation: 1, invitationEpoch: 0,
      members: { away: true, other: true }, memberAccess: {}, watchers: { away: true },
      shareInviteEpochs: { away: 'fake-away-nonce' }, sharing: true, audioAvailable: true, lastSeenMs: Date.now()
    }]));
    window.__pcs = []; window.__signOuts = 0; window.__unsubscribes = 0;
    window.__copied = []; window.__shared = []; window.__cameraRequests = []; window.__cameraStreams = [];
    window.__cameraMode = 'unexpected'; window.__cameraStops = 0; window.__scanPlayed = 0;
    window.__readClips = () => new Promise((resolve, reject) => {
      const request = indexedDB.open('home-listen-recordings', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('clips', { keyPath: 'id' });
      request.onerror = () => reject(request.error);
      request.onsuccess = () => {
        const db = request.result, rows = db.transaction('clips').objectStore('clips').getAll();
        rows.onsuccess = () => { resolve(rows.result.map(clip => ({ roomId: clip.roomId, roomName: clip.roomName, name: clip.name, durationMs: clip.durationMs }))); db.close(); };
      };
    });
    // Video playback stays real so the receiver must decode camera frames.
    // Only remote audio playback is fake in these WebRTC fixtures.
    HTMLAudioElement.prototype.play = function () { this.__played = true; return Promise.resolve(); };
    HTMLAudioElement.prototype.pause = function () { this.__paused = true; };
    document.addEventListener('playing', event => { if (event.target.id === 'scan-video') window.__scanPlayed++; }, true);
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async text => { window.__copied.push(text); } } });
    Object.defineProperty(navigator, 'share', { configurable: true, value: async data => { window.__shared.push(data); } });
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia: constraints => {
      window.__cameraRequests.push(structuredClone(constraints));
      if (window.__cameraMode === 'deferred') return new Promise(resolve => { window.__resolveCamera = resolve; });
      if (window.__cameraMode === 'qr') return Promise.resolve(window.__qrCamera);
      return Promise.reject(new Error('Unexpected camera request'));
    } } });
    const subscription = { toJSON: () => ({ endpoint: 'https://fcm.googleapis.com/fake-test', keys: {} }), unsubscribe: async () => { window.__unsubscribes++; return true; } };
    const registration = { pushManager: { getSubscription: async () => subscription, subscribe: async () => subscription } };
    Object.defineProperty(navigator, 'serviceWorker', { value: { register: async () => registration, ready: Promise.resolve(registration), addEventListener: (_type, fn) => { window.__swMessage = fn; } } });
    window.PushManager = class {};
    class FakePeer {
      constructor(config) { this.config = config; this.connectionState = 'new'; this.channels = []; this.closed = false; window.__pcs.push(this); }
      createDataChannel() {
        const channel = { readyState: 'open', send(message) { if (message === 'subscribe') queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ type: 'recording-ready', version: 1 }) })); }, close() { this.readyState = 'closed'; this.onclose?.(); } };
        this.channels.push(channel); return channel;
      }
      addTransceiver() {} async createOffer() { return { type: 'offer', sdp: 'test-offer' }; } async setLocalDescription(value) { this.localDescription = value; }
      async setRemoteDescription(value) { this.remoteDescription = value; this.connectionState = 'connected'; this.onconnectionstatechange?.(); this.ontrack?.({ streams: [new MediaStream()] }); }
      async addIceCandidate() {} getConfiguration() { return this.config; } setConfiguration(value) { this.config = value; }
      close() { this.closed = true; this.connectionState = 'closed'; }
    }
    window.RTCPeerConnection = FakePeer;
  }, { rooms: SAVED_ROOMS, savedRooms });
  return { context, page, errors, requests, leaves, invites, joins, blocked, failures,
    get sessions() { return serial; },
    nextInvite({ roomId, expiresInMs, delay = false } = {}) {
      const plan = { roomId, expiresInMs, started: deferred(), finished: deferred(), held: delay ? deferred() : null };
      plans.push(plan);
      return { requested: plan.started.promise, finished: plan.finished.promise, release: () => plan.held?.resolve() };
    }
  };
}

async function shareLink(page, expectedName) {
  await page.click('#share-room-button');
  await page.waitForFunction(() => document.querySelector('#share-link')?.value && document.querySelector('#share-qr svg'));
  assert.equal(await page.locator('#share-room-name').innerText(), 'Share ' + expectedName);
  assert.equal(await page.locator('#share-link').getAttribute('readonly'), '');
  return page.locator('#share-link').inputValue();
}

async function clearedShare(page) {
  assert.deepEqual(await page.evaluate(() => ({ open: document.querySelector('#room-share-dialog').open,
    link: document.querySelector('#share-link').value, qr: document.querySelector('#share-qr').childElementCount })), { open: false, link: '', qr: 0 });
}

async function noPersistedSecrets(page, invites) {
  assert.equal(await page.evaluate(secrets => Object.keys(localStorage).some(key => secrets.some(secret => localStorage.getItem(key).includes(secret))), invites.map(invite => invite.secret)), false);
}

async function peers(page) {
  return page.evaluate(() => ({ peers: window.__pcs.map(peer => ({ closed: peer.closed, state: peer.connectionState })),
    audio: [...document.querySelectorAll('audio')].filter(audio => audio.srcObject).map(audio => audio.srcObject.id) }));
}

async function displayedQr(page) {
  return page.evaluate(async () => {
    const { createReader } = await import('/src/qr-codec.js');
    const image = new Image();
    image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(document.querySelector('#share-qr svg')));
    await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 256;
    const context = canvas.getContext('2d'); context.fillStyle = '#fff'; context.fillRect(0, 0, 256, 256); context.drawImage(image, 0, 0);
    return createReader().decodeFromCanvas(canvas).getText();
  });
}

async function qrCamera(page, link) {
  await page.evaluate(async link => {
    const { createCode } = await import('/src/qr-codec.js');
    const image = new Image(); image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(createCode(link)));
    await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 512;
    const context = canvas.getContext('2d'); context.imageSmoothingEnabled = false;
    const draw = () => { context.fillStyle = '#fff'; context.fillRect(0, 0, 512, 512); context.drawImage(image, 64, 64, 384, 384); };
    draw();
    const stream = canvas.captureStream(10), paint = setInterval(draw, 100);
    for (const track of stream.getTracks()) {
      const stop = track.stop.bind(track);
      track.stop = () => { window.__cameraStops++; stop(); if (stream.getTracks().every(track => track.readyState === 'ended')) clearInterval(paint); };
    }
    window.__cameraStreams.push(stream); window.__qrCamera = stream; window.__cameraMode = 'qr';
  }, link);
}

// Await the held HTTP body and its resulting browser task before checking that
// an obsolete response did not reopen an already-closed sharing dialog.
async function releaseInvite(page, plan) {
  const response = page.waitForResponse(response => response.url().endsWith('/share-invite'));
  plan.release(); await plan.finished; await (await response).finished();
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

(async () => {
  const viewer = path.resolve(__dirname, '..');
  const port = Number(process.env.HOME_LISTEN_BROWSER_PORT || 4175), base = 'http://127.0.0.1:' + port;
  const server = spawn(process.execPath, [path.join(viewer, 'node_modules/vite/bin/vite.js'), '--host', '127.0.0.1', '--port', String(port), '--strictPort'], { cwd: viewer, stdio: 'ignore' });
  let serverError; server.on('error', error => { serverError = error; });
  let browser, sender, receiver;
  try {
    const deadline = Date.now() + 20000;
    while (true) {
      if (serverError) throw serverError;
      try { if ((await fetch(base)).ok) break; } catch {}
      if (Date.now() >= deadline) throw new Error('Local browser test server did not start');
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    browser = await chromium.launch({ headless: true });
    sender = await fixture(browser, base);
    const page = sender.page;
    await page.goto(base);
    await page.waitForFunction(() => document.querySelector('#room-connections')?.textContent.includes('Bedroom · Connected') && document.querySelector('#room-connections')?.textContent.includes('Children room · Connected'), null, { timeout: 20000 });
    assert.equal(await page.locator('#room-select option').count(), 2);
    assert.equal(await page.evaluate(() => window.__pcs.length), 2);
    const originalPeers = await peers(page);

    const bedroomLink = await shareLink(page, 'Bedroom');
    assert.equal(bedroomLink, base + '/#pair=' + ROOM_A + '.' + sender.invites.at(-1).secret);
    assert.equal(await displayedQr(page), bedroomLink);
    await page.click('#copy-room-link'); await page.click('#send-room-link');
    assert.deepEqual(await page.evaluate(() => ({ copied: window.__copied, shared: window.__shared })), {
      copied: [bedroomLink], shared: [{ title: 'Home Listen · Bedroom', url: bedroomLink }]
    });
    await noPersistedSecrets(page, sender.invites);
    await page.selectOption('#room-select', ROOM_B);
    await clearedShare(page);
    const childrenLink = await shareLink(page, 'Children room');
    assert.equal(childrenLink, base + '/#pair=' + ROOM_B + '.' + sender.invites.at(-1).secret);
    assert.equal(await displayedQr(page), childrenLink);
    await page.click('#copy-room-link'); await page.click('#send-room-link');
    assert.equal(await page.evaluate(() => window.__copied.at(-1)), childrenLink);
    assert.deepEqual(await page.evaluate(() => window.__shared.at(-1)), { title: 'Home Listen · Children room', url: childrenLink });
    await page.click('#renew-room-link');
    await page.waitForFunction(old => document.querySelector('#share-link').value && document.querySelector('#share-link').value !== old && document.querySelector('#share-qr svg'), childrenLink);
    assert.equal(await displayedQr(page), await page.locator('#share-link').inputValue());
    await page.click('#close-room-share'); await clearedShare(page);

    await page.selectOption('#room-select', ROOM_A);
    const switched = sender.nextInvite({ roomId: ROOM_A, delay: true });
    await page.click('#share-room-button'); await switched.requested;
    await page.selectOption('#room-select', ROOM_B); await clearedShare(page);
    await releaseInvite(page, switched); await clearedShare(page);
    const closed = sender.nextInvite({ roomId: ROOM_B, delay: true });
    await page.click('#share-room-button'); await closed.requested;
    await page.click('#close-room-share'); await releaseInvite(page, closed); await clearedShare(page);

    await shareLink(page, 'Children room');
    await page.evaluate(id => { window.__rooms[id].memberAccess.away = { role: 'caregiver', expiresAtMs: Date.now() + 60000 }; window.__emitRoom(id); }, ROOM_B);
    await page.waitForFunction(() => document.querySelector('#share-room-button').disabled);
    await clearedShare(page);
    assert.deepEqual(await peers(page), originalPeers);
    await page.evaluate(id => { window.__rooms[id].memberAccess.away = { role: 'caregiver' }; window.__emitRoom(id); }, ROOM_B);
    await page.waitForFunction(() => !document.querySelector('#share-room-button').disabled);
    sender.nextInvite({ roomId: ROOM_B, expiresInMs: 2000 });
    await shareLink(page, 'Children room');
    await page.waitForFunction(() => document.querySelector('#share-expiry').textContent.includes('This code has expired'), null, { timeout: 7000 });
    assert.deepEqual(await page.evaluate(() => ({ link: document.querySelector('#share-link').value, qr: document.querySelector('#share-qr').childElementCount,
      copy: document.querySelector('#copy-room-link').disabled, share: document.querySelector('#send-room-link').disabled })), { link: '', qr: 0, copy: true, share: true });
    await page.click('#close-room-share');
    await shareLink(page, 'Children room');
    await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: true }); document.dispatchEvent(new Event('visibilitychange')); delete document.hidden; });
    await clearedShare(page);
    const scanLink = await shareLink(page, 'Children room');
    await page.click('#close-room-share');
    await noPersistedSecrets(page, sender.invites);
    assert.deepEqual(await peers(page), originalPeers);

    // Cancel before permission resolves. Stop the late owned camera stream
    // without touching either live audio peer or asking for a microphone.
    await page.click('#add-room-button');
    await page.evaluate(() => { window.__cameraMode = 'deferred'; });
    await page.click('#scan-room-button');
    await page.waitForFunction(() => window.__cameraRequests.length === 1 && typeof window.__resolveCamera === 'function');
    await page.click('#close-room-scan');
    await page.evaluate(() => {
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 2;
      const stream = canvas.captureStream(1), track = stream.getVideoTracks()[0], stop = track.stop.bind(track);
      track.stop = () => { window.__cameraStops++; stop(); }; window.__lateCamera = stream;
      window.__resolveCamera(stream);
    });
    await page.waitForFunction(() => window.__lateCamera.getTracks().every(track => track.readyState === 'ended'));
    assert.deepEqual(await page.evaluate(() => ({ open: document.querySelector('#room-scan-dialog').open, preview: document.querySelector('#scan-video').srcObject,
      requests: window.__cameraRequests, stops: window.__cameraStops })), { open: false, preview: null, requests: [{ video: { facingMode: { ideal: 'environment' } }, audio: false }], stops: 1 });
    assert.deepEqual(await peers(page), originalPeers);
    await page.click('#cancel-pair-button');

    receiver = await fixture(browser, base, { uid: 'new_away', savedRooms: [] });
    const newPhone = receiver.page;
    await newPhone.goto(base);
    await newPhone.waitForFunction(() => document.querySelector('#message').textContent.includes('Ready to add your first room'));
    assert.equal(await newPhone.locator('#room-select option').count(), 0);
    assert.deepEqual(receiver.joins, []);
    await qrCamera(newPhone, scanLink);
    await newPhone.click('#scan-room-button');
    await newPhone.waitForFunction(() => document.querySelector('#room-connections').textContent.includes('Children room · Connected') && !document.querySelector('#room-scan-dialog').open, null, { timeout: 20000 });
    assert.equal(await newPhone.locator('#room-select').inputValue(), ROOM_B);
    assert.deepEqual(receiver.joins, [{ roomId: ROOM_B, secret: scanLink.split('.').at(-1), uid: 'new_away' }]);
    assert.equal(await newPhone.evaluate(() => window.__scanPlayed > 0), true);
    assert.equal(await newPhone.evaluate(() => window.__cameraRequests[0].audio), false);
    assert.equal(await newPhone.evaluate(() => window.__cameraStreams.every(stream => stream.getTracks().every(track => track.readyState === 'ended')) && document.querySelector('#scan-video').srcObject === null), true);
    assert.deepEqual(await newPhone.evaluate(() => ({ uid: window.__auth.currentUser.uid, peers: window.__pcs.map(peer => peer.closed), signOuts: window.__signOuts,
      rooms: JSON.parse(localStorage.getItem('homelisten-rooms-v1')).rooms.map(room => room.id) })), { uid: 'new_away', peers: [false], signOuts: 0, rooms: [ROOM_B] });
    await noPersistedSecrets(newPhone, sender.invites);
    await newPhone.click('#logout-button');
    await newPhone.waitForFunction(() => { const state = JSON.parse(localStorage.getItem('homelisten-rooms-v1')); return state.rooms.length === 0 && state.pendingLeaves.length === 0; });
    assert.deepEqual(receiver.leaves, [ROOM_B]);
    assert.deepEqual(await newPhone.evaluate(() => ({ uid: window.__auth.currentUser.uid, closed: window.__pcs.map(peer => peer.closed), signOuts: window.__signOuts })), { uid: 'new_away', closed: [true], signOuts: 0 });
    assert.equal(await page.evaluate(() => window.__auth.currentUser.uid), 'away');
    assert.deepEqual(await peers(page), originalPeers);
    assert.equal(sender.sessions, 2); assert.deepEqual(sender.leaves, []);

    // Retain every original two-room audio, recording, push, logout and mobile
    // regression check after the sharing and scanner lifecycle exercises.
    await page.selectOption('#room-select', ROOM_B);
    assert.equal(await page.evaluate(() => window.__pcs.some(peer => peer.closed)), false);
    assert.equal(await page.evaluate(() => [...document.querySelectorAll('audio')].filter(audio => audio.srcObject && !audio.muted).length), 1);
    await page.click('#record-device-button');
    await page.evaluate(() => { const channel = window.__pcs[1].channels[0]; for (let i = 0; i < 20; i++) { const bytes = new ArrayBuffer(3212), view = new DataView(bytes); view.setUint32(0, 0x484c4131); view.setUint32(4, i, true); view.setUint32(8, i * 100, true); channel.onmessage?.({ data: bytes }); } });
    await page.selectOption('#room-select', ROOM_A);
    await page.waitForFunction(async id => { const clips = await window.__readClips(); return clips.length === 1 && clips[0].roomId === id; }, ROOM_B);
    const clips = await page.evaluate(() => window.__readClips());
    assert.equal(clips[0].durationMs, 2000); assert.equal(clips[0].roomName, 'Children room');
    assert.equal(await page.evaluate(() => window.__pcs.some(peer => peer.closed)), false);
    await page.click('#alerts-button');
    assert.equal(await page.evaluate(() => window.__unsubscribes), 0);
    await shareLink(page, 'Bedroom');
    // Exercise removal while a dialog is open through the real logout handler;
    // a modal makes the background logout button inert to pointer interaction.
    await page.locator('#logout-button').dispatchEvent('click');
    await page.waitForFunction(id => document.querySelector('#room-select')?.value === id && JSON.parse(localStorage.getItem('homelisten-rooms-v1')).pendingLeaves.length === 0 && !document.querySelector('#logout-button').disabled, ROOM_B);
    await clearedShare(page);
    assert.deepEqual(sender.leaves, [ROOM_A]);
    const state = await page.evaluate(() => ({ closed: window.__pcs.map(peer => peer.closed), signOuts: window.__signOuts, registry: JSON.parse(localStorage.getItem('homelisten-rooms-v1')) }));
    assert.deepEqual(state.closed, [true, false]); assert.equal(state.signOuts, 0); assert.deepEqual(state.registry.rooms.map(room => room.id), [ROOM_B]);
    await page.selectOption('#room-select', ROOM_B);
    await page.waitForFunction(() => document.querySelector('.recording-list')?.textContent.includes('Children_room'));
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await shareLink(page, 'Children room');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth || document.querySelector('#room-share-dialog').scrollWidth > document.querySelector('#room-share-dialog').clientWidth), false);
    await page.click('#close-room-share'); await clearedShare(page);
    await noPersistedSecrets(page, sender.invites);
    for (const device of [sender, receiver]) { assert.deepEqual(device.errors, []); assert.deepEqual(device.failures, []); assert.deepEqual(device.blocked, []); }
    console.log(JSON.stringify({ passed: true, checks: ['two concurrent peers', 'selected-room QR/copy/native sharing', 'renewal replaces code', 'no invitation secrets in storage',
      'room switch clears code without reconnecting', 'late invitation responses stay closed', 'temporary caregiver cannot invite', 'expiry and hidden page clear code',
      'late camera permission stream stopped', 'real QR video scanner pairs independent receiver', 'receiver logout preserves sender identity and peers',
      'one audible room', 'manual room-tagged 2s WAV', 'switch saves recording', 'shared push retained', 'logout scoped to one room/device', 'saved room retained', 'mobile no horizontal overflow'],
      sessions: sender.sessions, leaves: sender.leaves, receiverSessions: receiver.sessions, receiverLeaves: receiver.leaves, clips }, null, 2));
  } catch (error) {
    for (const [name, device] of [['sender', sender], ['receiver', receiver]]) if (device) {
      console.log(JSON.stringify({ device: name, error: String(error), errors: device.errors, fixtureFailures: device.failures, blocked: device.blocked,
        requests: device.requests, pageText: await device.page.locator('body').innerText().catch(() => null) }, null, 2));
    }
    throw error;
  } finally { await browser?.close(); server.kill(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
