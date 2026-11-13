import test from 'node:test';
import assert from 'node:assert/strict';
import { FirestoreStore } from '../src/store.js';
import { HttpError } from '../src/security.js';

test('invitation replacement is guarded by the room revision without changing member or session fields', async () => {
  const store = new FirestoreStore({ FIREBASE_PROJECT_ID: 'demo-home' });
  let commit;
  store.call = async (path, options) => { assert.equal(path, ':commit'); commit = JSON.parse(options.body); };
  await store.putInvitation('room', {
    version: 'before-removal', data: { members: { second: true }, activeSessions: { second: 'live' }, invitationEpoch: 3 }
  }, { secretHash: 'hashed', generation: 1, invitationEpoch: 3, expiresAt: new Date(600000) });
  assert.equal(commit.writes.length, 2);
  const [guard, invite] = commit.writes;
  assert.deepEqual(guard.currentDocument, { updateTime: 'before-removal' });
  assert.deepEqual(guard.updateMask.fieldPaths, ['invitationEpoch']);
  assert.deepEqual(Object.keys(guard.update.fields), ['invitationEpoch']);
  assert.equal(guard.update.fields.invitationEpoch.integerValue, '3');
  assert.equal(invite.update.name, store.name + 'roomInvites/room');
  assert.equal(invite.update.fields.invitationEpoch.integerValue, '3');
});

test('expired push removes only the examined registration and its watcher in one CAS commit', async () => {
  const store = new FirestoreStore({ FIREBASE_PROJECT_ID: 'demo-home' });
  store.get = async (path) => path.endsWith('/devices/away')
    ? { version: 'token-v1', data: { token: 'old' } }
    : { version: 'room-v3', data: { watchers: { away: true, second: true }, members: { away: true } } };
  let commit;
  store.call = async (path, options) => { assert.equal(path, ':commit'); commit = JSON.parse(options.body); };
  assert.equal(await store.expireDevice('room', 'away', 'token-v1'), true);
  assert.equal(commit.writes.length, 2);
  assert.deepEqual(commit.writes[0], { delete: store.name + 'rooms/room/devices/away', currentDocument: { updateTime: 'token-v1' } });
  assert.deepEqual(commit.writes[1].currentDocument, { updateTime: 'room-v3' });
  assert.deepEqual(commit.writes[1].updateMask, { fieldPaths: ['watchers'] });
  assert.deepEqual(commit.writes[1].update.fields.watchers.mapValue.fields, { second: { booleanValue: true } });
});

test('refresh during an expiry commit survives the conflict retry', async () => {
  const store = new FirestoreStore({ FIREBASE_PROJECT_ID: 'demo-home' });
  let version = 'old', commits = 0;
  store.get = async (path) => path.endsWith('/devices/away')
    ? { version, data: { token: version } } : { version: 'room', data: { watchers: { away: true } } };
  store.call = async () => { commits++; version = 'new'; throw new HttpError(409, 'changed'); };
  assert.equal(await store.expireDevice('room', 'away', 'old'), false);
  assert.equal(commits, 1);
});

test('expiry retries room contention using the latest watcher list', async () => {
  const store = new FirestoreStore({ FIREBASE_PROJECT_ID: 'demo-home' });
  let attempt = 0, final;
  store.get = async (path) => path.endsWith('/devices/away')
    ? { version: 'old', data: {} }
    : { version: 'room-' + attempt, data: { watchers: attempt ? { away: true, added: true } : { away: true } } };
  store.call = async (path, options) => {
    if (attempt++ === 0) throw new HttpError(409, 'changed');
    final = JSON.parse(options.body);
  };
  assert.equal(await store.expireDevice('room', 'away', 'old'), true);
  assert.deepEqual(final.writes[1].update.fields.watchers.mapValue.fields, { added: { booleanValue: true } });
  assert.deepEqual(final.writes[1].currentDocument, { updateTime: 'room-1' });
});
