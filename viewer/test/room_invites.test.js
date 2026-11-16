import test from 'node:test';
import assert from 'node:assert/strict';
import { RoomInvite, PairingScanner } from '../src/room-invites.js';
import { canInviteAway } from '../src/access.js';
import { RoomRegistry } from '../src/room-registry.js';

const roomId = 'bedroom_1234567890', secret = 'B'.repeat(43);
function pending() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function setup({ legacy = false } = {}) {
  let now = 1_800_000_000_000;
  const request = pending(), calls = [];
  const current = { id: roomId, name: 'Bedroom', origin: 'https://home.example', supported: true, uid: 'away',
    room: { ownerUid: 'home', members: { away: true }, generation: 2, invitationEpoch: 1, memberAccess: {},
      shareInviteEpochs: legacy ? {} : { away: 'epoch_first' } } };
  const controller = new RoomInvite({ current: () => current, create: id => { calls.push(id); return request.promise; }, now: () => now });
  const reply = () => ({ roomId, secret, generation: 2, expiresAt: new Date(now + 600_000).toISOString(), issuerEpoch: 'epoch_first' });
  return { current, request, calls, controller, reply, advance: ms => { now += ms; } };
}

test('only current permanent caregivers can share, including legacy missing roles', () => {
  const s = setup(), { room } = s.current;
  assert.equal(canInviteAway(room, 'away'), true);
  room.memberAccess.away = { expiresAtMs: null }; assert.equal(canInviteAway(room, 'away'), true);
  for (const access of ['malformed', [], { role: 'alerts' }, { role: 'guest' }, { role: 'unknown' }, { expiresAtMs: 0 }, { role: 'caregiver', expiresAtMs: Date.now() + 60000 }]) {
    room.memberAccess.away = access; assert.equal(canInviteAway(room, 'away'), false);
  }
  room.memberAccess = {}; assert.equal(canInviteAway(room, 'stranger'), false);
  room.members.home = true; assert.equal(canInviteAway(room, 'home'), false);
  room.members.away = false; assert.equal(canInviteAway(room, 'away'), false);
  room.members.away = true; room.generation = undefined; assert.equal(canInviteAway(room, 'away'), false);
});
test('shared code is room-scoped, in memory, expires and drops its secret', async () => {
  const s = setup(); const opening = s.controller.open();
  assert.equal(s.controller.state.phase, 'loading'); assert.deepEqual(s.calls, [roomId]);
  s.request.resolve(s.reply()); await opening;
  assert.equal(s.controller.state.url, `https://home.example/#pair=${roomId}.${secret}`);
  assert.equal(s.controller.state.context.name, 'Bedroom');
  s.advance(600_000); s.controller.tick();
  assert.equal(s.controller.state.phase, 'expired'); assert.equal(s.controller.state.url, undefined);
  s.controller.close(); assert.deepEqual(s.controller.state, { phase: 'closed' });
});
test('late sharing responses cannot survive close or selected room changes', async () => {
  for (const change of ['close', 'selection', 'origin', 'uid', 'role', 'nonce', 'generation', 'revocation']) {
    const s = setup(); const opening = s.controller.open();
    if (change === 'close') s.controller.close();
    if (change === 'selection') s.current.id = 'children_123456789';
    if (change === 'origin') s.current.origin = 'https://other.example';
    if (change === 'uid') s.current.uid = 'other';
    if (change === 'role') s.current.room.memberAccess.away = { role: 'alerts' };
    if (change === 'nonce') s.current.room.shareInviteEpochs.away = 'epoch_other';
    if (change === 'generation') s.current.room.generation++;
    if (change === 'revocation') s.current.room.invitationEpoch++;
    s.controller.sync(); s.request.resolve(s.reply()); await opening;
    assert.equal(s.controller.state.phase, 'closed', change);
  }
});
test('first legacy nonce can arrive before or after response; subsequent rotations close the code', async () => {
  for (const before of [true, false]) {
    const s = setup({ legacy: true }); const opening = s.controller.open();
    if (before) { s.current.room.shareInviteEpochs.away = 'epoch_first'; s.controller.sync(); }
    s.request.resolve(s.reply()); await opening; s.controller.sync();
    assert.equal(s.controller.state.phase, 'ready');
    s.current.room.shareInviteEpochs.away = 'epoch_first'; s.controller.sync();
    assert.equal(s.controller.state.phase, 'ready');
    delete s.current.room.shareInviteEpochs.away; s.controller.sync();
    assert.equal(s.controller.state.phase, 'closed');
  }
});
test('mismatched response nonce, room, generation or stale expiry never exposes a code', async () => {
  for (const key of ['issuerEpoch', 'roomId', 'generation', 'expiresAt', 'secret']) {
    const s = setup(), response = s.reply();
    response[key] = key === 'generation' ? 7 : key === 'expiresAt' ? '2020-01-01T00:00:00Z' : 'wrong';
    const opening = s.controller.open(); s.request.resolve(response); await opening;
    assert.notEqual(s.controller.state.phase, 'ready'); assert.equal(s.controller.state.url, undefined);
  }
});
test('a legacy nonce can be established only once while the invite request is pending', async () => {
  for (const replacement of ['epoch_rotated', null]) {
    const s = setup({ legacy: true }); const opening = s.controller.open();
    s.current.room.shareInviteEpochs.away = 'epoch_first'; s.controller.sync();
    s.current.room.shareInviteEpochs.away = replacement; s.controller.sync();
    s.request.resolve({ ...s.reply(), issuerEpoch: replacement ?? 'epoch_first' }); await opening;
    assert.equal(s.controller.state.phase, 'closed'); assert.equal(s.controller.state.url, undefined);
  }
});
test('registering a stale pairing does not replace a newer selected room', () => {
  const saved = new Map();
  const registry = new RoomRegistry({ getItem: key => saved.get(key) ?? null, setItem: (key, value) => saved.set(key, value), removeItem: key => saved.delete(key) });
  registry.add('newer_room_1234567', 'Children room');
  registry.add('older_room_1234567', 'Bedroom', { select: false });
  assert.equal(registry.selected, 'newer_room_1234567');
  assert.equal(JSON.parse(saved.get('homelisten-rooms-v1')).selected, 'newer_room_1234567');
  assert.equal(registry.rooms.size, 2);
});
test('restricted or unsupported clients do not issue any sharing request', async () => {
  const s = setup(); s.current.supported = false; await s.controller.open();
  s.current.supported = true; s.current.room.memberAccess.away = { role: 'guest' }; await s.controller.open();
  assert.deepEqual(s.calls, []); assert.equal(s.controller.state.phase, 'closed');
});

test('cancelling before a camera permission response stops that late stream and never decodes', async () => {
  const permission = pending(); let stopped = 0, decoded = 0;
  const stream = { getTracks: () => [{ stop: () => stopped++ }] };
  const scanner = new PairingScanner({ media: () => permission.promise, decoder: async () => ({ decodeFromStream: async () => { decoded++; } }),
    createVideo: () => ({ srcObject: null }), result: assert.fail, problem: assert.fail });
  const opening = scanner.start(); await Promise.resolve(); scanner.stop(); permission.resolve(stream); await opening;
  assert.equal(stopped, 1); assert.equal(decoded, 0); assert.equal(scanner.active, false);
});
test('scanner uses video only and releases its camera before accepting one pairing result', async () => {
  let stopped = 0, controlsStopped = 0, callback, received;
  const stream = { getTracks: () => [{ stop: () => stopped++ }] };
  const scanner = new PairingScanner({ media: async constraints => { assert.equal(constraints.audio, false); return stream; },
    decoder: async () => ({ decodeFromStream: async (_stream, _video, cb) => { callback = cb; return { stop: () => controlsStopped++ }; } }),
    createVideo: () => ({ srcObject: null }), result: text => { assert.ok(stopped > 0); received = text; }, problem: assert.fail });
  await scanner.start(); callback({ getText: () => 'pairing link' }, null, { stop: () => controlsStopped++ });
  callback({ getText: () => 'late code' });
  assert.equal(received, 'pairing link'); assert.equal(scanner.active, false); assert.ok(controlsStopped > 0);
});
test('camera denial leaves no active scanner and offers a paste fallback', async () => {
  let message;
  const scanner = new PairingScanner({ media: async () => { throw Object.assign(new Error(), { name: 'NotAllowedError' }); }, decoder: async () => ({}),
    createVideo: () => ({ srcObject: null }), result: assert.fail, problem: text => { message = text; } });
  await scanner.start(); assert.equal(scanner.active, false); assert.match(message, /paste the pairing link/);
});
test('late decoder cleanup cannot clear a newer scan preview', async () => {
  const oldDecode = pending(), attached = pending(), previews = [];
  const first = { getTracks: () => [{ stop() {} }] }, second = { getTracks: () => [{ stop() {} }] };
  let count = 0;
  const scanner = new PairingScanner({ media: async () => ++count === 1 ? first : second,
    createVideo: () => { const video = { srcObject: null }; previews.push(video); return video; },
    decoder: async () => ({ decodeFromStream: async (stream, video) => {
      video.srcObject = stream;
      if (stream === first) { attached.resolve(); return oldDecode.promise; }
      return { stop: () => { video.srcObject = null; } };
    } }), result: assert.fail, problem: assert.fail });
  const opening = scanner.start(); await attached.promise; scanner.stop(); await scanner.start();
  oldDecode.resolve({ stop: () => { previews[0].srcObject = null; } }); await opening;
  assert.equal(scanner.active, true); assert.equal(scanner.video, previews[1]);
  assert.equal(previews[1].srcObject, second); scanner.stop();
});
