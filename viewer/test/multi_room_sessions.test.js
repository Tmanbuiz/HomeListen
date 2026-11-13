import test from 'node:test';
import assert from 'node:assert/strict';
import { MultiRoomSessions } from '../src/multi-room-sessions.js';
import { RoomRegistry, ROOM_STORAGE_KEY, LEGACY_ROOM_KEY } from '../src/room-registry.js';

function storage(values = {}) {
  const map = new Map(Object.entries(values));
  return { getItem: key => map.get(key) ?? null, setItem: (key, value) => map.set(key, value), removeItem: key => map.delete(key) };
}
function fixture({ deferred = false } = {}) {
  const registry = new RoomRegistry(storage());
  registry.add('room_a', 'Bedroom'); registry.add('room_b', 'Children room');
  registry.select('room_a');
  const made = [], audios = [], gates = [];
  const coordinator = new MultiRoomSessions({ registry, allowed: room => room?.authorized === true,
    createAudio: () => {
      let muted = true;
      const audio = { volume: 0, srcObject: null, plays: 0, pauses: 0,
        get muted() { return muted; },
        set muted(value) { muted = value; assert.ok(audios.filter(item => !item.muted).length <= 1); },
        async play() { this.plays++; }, pause() { this.pauses++; }, remove() { this.removed = true; }
      };
      audios.push(audio); return audio;
    },
    createSession: (id, callbacks) => {
      const gate = Promise.withResolvers(); gates.push(gate);
      const session = { id, callbacks, stopped: 0,
        async start() {
          if (deferred) await gate.promise;
          callbacks.onPeer({ id }); await callbacks.onTrack({ id }); callbacks.onState('connected');
        }, async stop() { this.stopped++; }
      };
      made.push(session); return session;
    }
  });
  async function connect() {
    coordinator.update('room_a', { authorized: true });
    coordinator.update('room_b', { authorized: true });
    await coordinator.startAll();
    await Promise.resolve();
  }
  return { registry, coordinator, made, audios, gates, connect };
}

test('switching audible rooms retains both live peers and mutes before unmuting', async t => {
  const f = fixture(); t.after(() => f.coordinator.stopAll());
  await f.connect();
  const peers = [...f.made];
  await f.coordinator.select('room_b');
  assert.equal(f.made.length, 2);
  assert.ok(peers.every(peer => peer.stopped === 0));
  assert.equal(f.coordinator.entries.get('room_a').audio.muted, true);
  assert.equal(f.coordinator.entries.get('room_b').audio.muted, false);
  await f.coordinator.select('room_a');
  assert.equal(f.coordinator.entries.get('room_a').session, peers[0]);
  assert.equal(f.coordinator.entries.get('room_b').session, peers[1]);
  assert.equal(f.coordinator.entries.get('room_b').audio.muted, true);
});

test('logging out of one room retains another peer and rejects late callbacks', async t => {
  const f = fixture(); t.after(() => f.coordinator.stopAll()); await f.connect();
  const [first, second] = f.made;
  await f.coordinator.remove('room_a', { pendingLeave: true });
  assert.equal(first.stopped, 1); assert.equal(second.stopped, 0);
  assert.equal(f.registry.selected, 'room_b');
  first.callbacks.onState('connected'); await first.callbacks.onTrack({ obsolete: true });
  assert.equal(f.coordinator.entries.has('room_a'), false);
  assert.equal(f.coordinator.entries.get('room_b').session, second);
  assert.deepEqual([...f.registry.pendingLeaves], ['room_a']);
  const leaves = []; await f.registry.flushLeaves(async id => leaves.push(id));
  assert.deepEqual(leaves, ['room_a']); assert.equal(f.registry.rooms.has('room_b'), true);
});

test('Stop during parallel pending starts cannot restore any room audio', async () => {
  const f = fixture({ deferred: true });
  const connecting = f.connect();
  await Promise.resolve(); await f.coordinator.stopAll();
  f.gates.forEach(gate => gate.resolve()); await connecting;
  assert.ok(f.made.every(peer => peer.stopped === 1));
  assert.ok(f.audios.every(audio => audio.muted && audio.srcObject == null));
  assert.ok([...f.registry.rooms.values()].every(row => row.listen === false));
});

test('revocation or sharing loss affects only the corresponding room', async t => {
  const f = fixture(); t.after(() => f.coordinator.stopAll()); await f.connect();
  const [first, second] = f.made;
  f.coordinator.update('room_b', { authorized: false }); await Promise.resolve();
  assert.equal(first.stopped, 0); assert.equal(second.stopped, 1);
  assert.equal(f.coordinator.entries.get('room_a').session, first);
  f.coordinator.update('room_b', { authorized: true }); await Promise.resolve();
  assert.equal(f.made.length, 3); assert.equal(f.made[2].id, 'room_b');
});

test('restoring rooms stays muted until a user playback choice', async t => {
  const f = fixture(); t.after(() => f.coordinator.stopAll());
  f.coordinator.update('room_a', { authorized: true }); f.coordinator.update('room_b', { authorized: true });
  await Promise.resolve(); await f.coordinator.select('room_a', { play: false });
  assert.ok(f.audios.every(audio => audio.muted));
  await f.coordinator.playSelected();
  assert.equal(f.audios.filter(audio => !audio.muted).length, 1);
});

test('a failed room retries independently without reopening another room', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = fixture(); t.after(() => f.coordinator.stopAll()); await f.connect();
  const [first, second] = f.made;
  second.callbacks.onError(new Error('network failure'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(first.stopped, 0); assert.equal(second.stopped, 1);
  t.mock.timers.tick(1000); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.made.length, 3); assert.equal(f.made[2].id, 'room_b');
  assert.equal(f.coordinator.entries.get('room_a').session, first);
});

test('legacy pairing migrates and explicit empty registry cannot revive it', () => {
  const data = storage({ [LEGACY_ROOM_KEY]: 'legacy_room' });
  const migrated = new RoomRegistry(data); assert.equal(migrated.selected, 'legacy_room'); migrated.save();
  migrated.add('room_b', 'Children room');
  const restored = new RoomRegistry(data); assert.deepEqual([...restored.rooms.keys()], ['legacy_room', 'room_b']);
  restored.remove('legacy_room'); restored.remove('room_b'); data.setItem(LEGACY_ROOM_KEY, 'legacy_room');
  assert.equal(new RoomRegistry(data).rooms.size, 0);
  data.setItem(ROOM_STORAGE_KEY, '{bad'); assert.equal(new RoomRegistry(data).rooms.size, 0);
});
