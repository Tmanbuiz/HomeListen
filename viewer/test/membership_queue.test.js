import test from 'node:test';
import assert from 'node:assert/strict';
import { MembershipQueue } from '../src/membership-queue.js';
import { RoomRegistry } from '../src/room-registry.js';

function deferred() { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; }
function registry() {
  const storage = new Map(); return new RoomRegistry({ getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) });
}
const id = 'bedroom_1234567890';

test('logout waits for an older join and its obsolete result cannot restore the room', async () => {
  const queue = new MembershipQueue(), rooms = registry(), started = deferred(), reply = deferred(), calls = [];
  rooms.add(id, 'Bedroom'); const ticket = queue.begin();
  const pairing = queue.request(async () => { calls.push('join started'); started.resolve(); await reply.promise; calls.push('join granted'); return id; }).then(room => {
    if (!queue.cancelled(ticket, room)) rooms.add(room);
    queue.finish(ticket);
  });
  await started.promise; queue.logout(id); rooms.remove(id, { pendingLeave: true });
  const logout = queue.flush(() => rooms.flushLeaves(async () => { calls.push('leave'); }));
  assert.equal(rooms.rooms.has(id), false); assert.equal(rooms.pendingLeaves.has(id), true);
  reply.resolve(); await pairing; await logout;
  assert.deepEqual(calls, ['join started', 'join granted', 'leave']);
  assert.equal(rooms.rooms.has(id), false); assert.equal(rooms.selected, null); assert.equal(rooms.pendingLeaves.has(id), false);
});
test('failed offline logout keeps its pending leave after a late join result', async () => {
  const queue = new MembershipQueue(), rooms = registry(), reply = deferred(); rooms.add(id);
  const ticket = queue.begin(), pairing = queue.request(() => reply.promise).then(room => { if (!queue.cancelled(ticket, room)) rooms.add(room); queue.finish(ticket); });
  queue.logout(id); rooms.remove(id, { pendingLeave: true });
  const logout = queue.flush(() => rooms.flushLeaves(async () => { throw new Error('offline'); }));
  reply.resolve(id); await pairing; await logout;
  assert.equal(rooms.rooms.has(id), false); assert.equal(rooms.pendingLeaves.has(id), true);
  await queue.flush(() => rooms.flushLeaves(async () => {})); assert.equal(rooms.pendingLeaves.has(id), false);
});
test('a new intentional pairing waits for logout and cannot be revoked by older cleanup', async () => {
  const queue = new MembershipQueue(), oldReply = deferred(), calls = [], old = queue.begin();
  const first = queue.request(async () => { await oldReply.promise; calls.push('old join'); }).finally(() => queue.finish(old));
  queue.logout(id); const logout = queue.flush(async () => { calls.push('leave'); });
  const fresh = queue.begin();
  const second = (async () => { await queue.flush(async () => {}); await queue.request(async () => { calls.push('new join'); }); queue.finish(fresh); })();
  oldReply.resolve(); await first; await logout; await second;
  assert.deepEqual(calls, ['old join', 'leave', 'new join']); assert.equal(queue.cancelled(fresh, id), false);
});
test('leaving one room does not cancel a join or retained membership for a different room', () => {
  const queue = new MembershipQueue(), ticket = queue.begin(); queue.logout(id);
  assert.equal(queue.cancelled(ticket, id), true); assert.equal(queue.cancelled(ticket, 'children_123456789'), false);
  queue.finish(ticket); const next = queue.begin(); assert.equal(queue.cancelled(next, id), false); queue.finish(next);
});
test('a queued online leave finishes before a new join released by a failed offline retry', async () => {
  const queue = new MembershipQueue(), rooms = registry(), retryReply = deferred(), onlineReply = deferred(), onlineStarted = deferred(), calls = [];
  rooms.add(id); rooms.remove(id, { pendingLeave: true }); let member = true;
  const retry = queue.flush(() => rooms.flushLeaves(async () => { await retryReply.promise; throw new Error('offline'); }));
  const ticket = queue.begin();
  const pairing = (async () => {
    await retry;
    await queue.request(async () => { calls.push('new join'); member = true; });
    if (!queue.cancelled(ticket, id)) rooms.add(id);
    queue.finish(ticket);
  })();
  const online = queue.flush(() => rooms.flushLeaves(async () => { calls.push('online leave'); onlineStarted.resolve(); await onlineReply.promise; member = false; }));
  retryReply.resolve(); await onlineStarted.promise;
  assert.deepEqual(calls, ['online leave']); assert.equal(rooms.rooms.has(id), false);
  onlineReply.resolve(); await online; await pairing;
  assert.deepEqual(calls, ['online leave', 'new join']);
  assert.equal(rooms.rooms.has(id), true); assert.equal(rooms.pendingLeaves.has(id), false); assert.equal(member, true);
});
