import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { FirestoreStore } from '../src/store.js';
import { HttpError } from '../src/security.js';
import { createWorker } from '../src/worker.js';

// Exercise the actual store's REST encoding and commit preconditions against
// a local atomic REST stub. No credentials or live Firestore data are used.
function restStore() {
  const store = new FirestoreStore({ FIREBASE_PROJECT_ID: 'demo-home' });
  const documents = new Map(), commits = [];
  let revision = 0;
  store.call = async (path, options = {}, beforeSend = null) => {
    if (path.startsWith('/')) return structuredClone(documents.get(store.name + path.slice(1)) ?? null);
    const input = JSON.parse(options.body);
    if (path === ':runQuery') {
      const query = input.structuredQuery;
      assert.equal(query.where.fieldFilter.field.fieldPath, 'expiresAt');
      assert.equal(query.where.fieldFilter.op, 'LESS_THAN_OR_EQUAL');
      const cutoff = new Date(query.where.fieldFilter.value.timestampValue).getTime();
      const collection = query.from[0].collectionId;
      return [...documents.values()].filter((doc) => doc.name.split('/').at(-2) === collection &&
        new Date(doc.fields.expiresAt?.timestampValue).getTime() <= cutoff)
        .slice(0, query.limit).map((document) => ({ document: structuredClone(document) }));
    }
    assert.equal(path, ':commit'); assert.equal(options.method, 'POST');
    if (store.beforeCommit) await store.beforeCommit(input);
    if (beforeSend) beforeSend();
    commits.push(structuredClone(input));
    // Check the entire commit before applying any write, as Firestore does.
    for (const write of input.writes) {
      const old = documents.get(write.update?.name ?? write.delete);
      const condition = write.currentDocument;
      if ((condition?.exists === false && old) || (condition?.exists === true && !old) ||
          (condition?.updateTime && old?.updateTime !== condition.updateTime)) {
        throw new HttpError(409, 'REST precondition failed');
      }
    }
    for (const write of input.writes) {
      if (write.delete) { documents.delete(write.delete); continue; }
      const update = structuredClone(write.update);
      if (write.updateMask) {
        const nextFields = structuredClone(documents.get(update.name)?.fields ?? {});
        for (const field of write.updateMask.fieldPaths) nextFields[field] = update.fields[field];
        update.fields = nextFields;
      }
      documents.set(update.name, { ...update, updateTime: 'revision-' + ++revision });
    }
    return {};
  };
  return { store, documents, commits };
}

const invitation = (hash = 'hash') => ({ kind: 'away', roomId: 'room', issuerUid: 'issuer',
  issuerEpoch: 'issuer-nonce', generation: 1, invitationEpoch: 0, secretHash: hash, expiresAt: new Date(600000) });
const roomData = { ownerUid: 'home', members: { issuer: true }, watchers: {}, activeSessions: {},
  generation: 1, invitationEpoch: 0, shareInviteEpochs: { issuer: 'issuer-nonce' }, sharing: false };
async function issuedStore() {
  const s = restStore(); await s.store.put('rooms/room', roomData, null);
  await s.store.putShareInvitation('room', await s.store.get('rooms/room'), 'roomInvites/issuer-index', null,
    'roomInvites/away-hash', invitation());
  return s;
}
async function consumeArgs(store) {
  const room = await store.get('rooms/room');
  const data = { ...room.data, members: { ...room.data.members, receiver: true },
    shareInviteEpochs: { ...room.data.shareInviteEpochs, receiver: 'receiver-nonce' } };
  return ['room', room, data, 'roomInvites/away-hash', await store.get('roomInvites/away-hash'),
    'roomInvites/issuer-index', await store.get('roomInvites/issuer-index'), 'receiver', () => 100000];
}

test('REST issuance guards room and index, establishes a legacy nonce and creates only a private hashed invite', async () => {
  const { store, commits } = restStore(); const legacy = { ...roomData }; delete legacy.shareInviteEpochs;
  await store.put('rooms/room', legacy, null);
  const room = await store.get('rooms/room');
  await store.putShareInvitation('room', room, 'roomInvites/issuer-index', null, 'roomInvites/away-hash', invitation());
  const [guard, index, invite] = commits.at(-1).writes;
  assert.deepEqual(guard.currentDocument, { updateTime: room.version });
  assert.deepEqual(guard.updateMask.fieldPaths, ['invitationEpoch', 'shareInviteEpochs']);
  assert.deepEqual(Object.keys(guard.update.fields).sort(), ['invitationEpoch', 'shareInviteEpochs']);
  assert.deepEqual(index.currentDocument, { exists: false });
  assert.deepEqual(invite.currentDocument, { exists: false });
  assert.equal(invite.update.fields.secretHash.stringValue, 'hash');
  assert.equal(invite.update.fields.expiresAt.timestampValue, new Date(600000).toISOString());
  assert.deepEqual((await store.get('rooms/room')).data.members, { issuer: true });
  assert.equal((await store.get('rooms/room')).data.shareInviteEpochs.issuer, 'issuer-nonce');
  assert.ok((await store.get('roomInvites/away-hash')).data.expiresAt instanceof Date);
});

test('REST renewal removes only the examined unused code with all revision preconditions', async () => {
  const { store, commits } = await issuedStore();
  await store.put('roomInvites/home', { secretHash: 'home-hash', expiresAt: new Date(600000) });
  await store.put('roomInvites/other-issuer', { secretHash: 'other-hash', expiresAt: new Date(600000) });
  const index = await store.get('roomInvites/issuer-index'), previous = await store.get('roomInvites/away-hash');
  await store.putShareInvitation('room', await store.get('rooms/room'), 'roomInvites/issuer-index', index,
    'roomInvites/away-next', invitation('next'), { ...previous, path: 'roomInvites/away-hash' });
  const writes = commits.at(-1).writes;
  assert.equal(writes.length, 4);
  assert.deepEqual(writes[1].currentDocument, { updateTime: index.version });
  assert.deepEqual(writes[3], { delete: store.name + 'roomInvites/away-hash', currentDocument: { updateTime: previous.version } });
  assert.equal(await store.get('roomInvites/away-hash'), null);
  assert.equal((await store.get('roomInvites/home')).data.secretHash, 'home-hash');
  assert.equal((await store.get('roomInvites/other-issuer')).data.secretHash, 'other-hash');
});

test('REST redemption atomically grants membership and spends the invite and issuer slot', async () => {
  const { store, commits } = await issuedStore(); const args = await consumeArgs(store);
  await store.consumeShareInvitation(...args);
  const writes = commits.at(-1).writes;
  assert.equal(writes.length, 3);
  assert.deepEqual(writes.map((write) => write.currentDocument), [
    { updateTime: args[1].version }, { updateTime: args[4].version }, { updateTime: args[6].version }
  ]);
  assert.deepEqual(writes[2].updateMask, { fieldPaths: ['pendingHash'] });
  assert.equal((await store.get('rooms/room')).data.members.receiver, true);
  assert.equal((await store.get('roomInvites/away-hash')).data.receiverUid, 'receiver');
  assert.equal((await store.get('roomInvites/away-hash')).data.receiverEpoch, 'receiver-nonce');
  assert.equal((await store.get('roomInvites/issuer-index')).data.pendingHash, null);
  assert.equal((await store.get('roomInvites/issuer-index')).data.issuerUid, 'issuer');
});

test('a changed room, invite or issuer slot aborts every REST redemption write', async () => {
  for (const changed of ['rooms/room', 'roomInvites/away-hash', 'roomInvites/issuer-index']) {
    const { store } = await issuedStore(); const args = await consumeArgs(store);
    const doc = await store.get(changed); await store.put(changed, { ...doc.data, changed: true }, doc.version);
    await assert.rejects(store.consumeShareInvitation(...args), { status: 409 });
    assert.equal((await store.get('rooms/room')).data.members.receiver, undefined, changed);
    assert.equal((await store.get('roomInvites/away-hash')).data.receiverUid, undefined, changed);
    assert.equal((await store.get('roomInvites/issuer-index')).data.pendingHash, 'hash', changed);
  }
});

test('a competing consumption prevents a stale REST renewal from deleting its receipt', async () => {
  const { store } = await issuedStore();
  const room = await store.get('rooms/room'), index = await store.get('roomInvites/issuer-index');
  const previous = await store.get('roomInvites/away-hash');
  await store.consumeShareInvitation(...await consumeArgs(store));
  await assert.rejects(store.putShareInvitation('room', room, 'roomInvites/issuer-index', index,
    'roomInvites/away-next', invitation('next'), { ...previous, path: 'roomInvites/away-hash' }), { status: 409 });
  assert.equal((await store.get('roomInvites/away-hash')).data.receiverUid, 'receiver');
  assert.equal(await store.get('roomInvites/away-next'), null);
  // A retry against fresh revisions leaves the consumed receipt available.
  const consumed = await store.get('roomInvites/away-hash');
  await store.putShareInvitation('room', await store.get('rooms/room'), 'roomInvites/issuer-index',
    await store.get('roomInvites/issuer-index'), 'roomInvites/away-next', invitation('next'), { ...consumed, path: 'roomInvites/away-hash' });
  assert.equal((await store.get('roomInvites/away-hash')).data.receiverUid, 'receiver');
});

test('REST redemption rechecks expiry immediately before sending a delayed commit', async () => {
  const { store } = await issuedStore(); let time = 599999;
  const args = await consumeArgs(store); args[8] = () => time;
  store.beforeCommit = () => { time = 600000; };
  await assert.rejects(store.consumeShareInvitation(...args), { status: 403, code: 'invite_expired' });
  assert.equal((await store.get('rooms/room')).data.members.receiver, undefined);
  assert.equal((await store.get('roomInvites/away-hash')).data.receiverUid, undefined);
});

test('service-token refresh cannot delay a redemption beyond expiry before its REST request', async (t) => {
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const store = new FirestoreStore({ FIREBASE_PROJECT_ID: 'demo-home', FIREBASE_SERVICE_ACCOUNT: JSON.stringify({
    project_id: 'demo-home', client_email: 'expiry-test@demo-home.iam.gserviceaccount.com',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' })
  }) });
  let time = 599999, requests = 0;
  t.mock.method(globalThis, 'fetch', async (url) => {
    requests++;
    assert.equal(url, 'https://oauth2.googleapis.com/token');
    time = 600000;
    return Response.json({ access_token: 'test-only-token', expires_in: 3600 });
  });
  await assert.rejects(store.consumeShareInvitation('room', { data: roomData, version: 'room-version' },
    { ...roomData, shareInviteEpochs: { ...roomData.shareInviteEpochs, receiver: 'receiver-nonce' } },
    'roomInvites/away-hash', { data: invitation(), version: 'invite-version' },
    'roomInvites/issuer-index', { version: 'index-version' }, 'receiver', () => time), { status: 403, code: 'invite_expired' });
  assert.equal(requests, 1);
});

test('REST HTTP missing documents return absence while failed writes and conflicts remain errors', async (t) => {
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const store = new FirestoreStore({ FIREBASE_PROJECT_ID: 'demo-home', FIREBASE_SERVICE_ACCOUNT: JSON.stringify({
    project_id: 'demo-home', client_email: 'http-test@demo-home.iam.gserviceaccount.com',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' })
  }) });
  let failure = { status: 404, reason: 'NOT_FOUND' };
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'test-only-token', expires_in: 3600 });
    assert.ok(url.startsWith(store.root));
    assert.equal(options.headers.authorization, 'Bearer test-only-token');
    return Response.json({ error: { status: failure.reason } }, { status: failure.status });
  });
  assert.equal(await store.get('rooms/missing'), null);
  await assert.rejects(store.put('rooms/missing', {}), { status: 502 });
  await assert.rejects(store.delete('rooms/missing'), { status: 502 });
  await assert.rejects(store.expired('roomInvites', 100000), { status: 502 });
  failure = { status: 400, reason: 'FAILED_PRECONDITION' };
  await assert.rejects(store.put('rooms/changed', {}, 'stale-revision'), { status: 409 });
  failure = { status: 409, reason: 'ABORTED' };
  await assert.rejects(store.put('rooms/changed', {}, 'stale-revision'), { status: 409 });
});

test('cleanup removes expired pending codes, consumed receipts and issuer indexes with revision guards', async () => {
  const { store, commits } = restStore();
  for (const [path, data] of [
    ['roomInvites/pending', { kind: 'away' }], ['roomInvites/receipt', { kind: 'away', receiverUid: 'receiver' }],
    ['roomInvites/index', { kind: 'away-index' }], ['roomInvites/home', { secretHash: 'home-hash' }],
    ['joinThrottle/old', { count: 10 }]
  ]) await store.put(path, { ...data, expiresAt: new Date(100000) });
  await store.put('roomInvites/fresh', { kind: 'away', expiresAt: new Date(600000) });
  assert.equal(await store.cleanup(100000), 5);
  assert.equal(commits.at(-1).writes.length, 5);
  assert.ok(commits.at(-1).writes.every((write) => write.currentDocument.updateTime));
  assert.ok(await store.get('roomInvites/fresh'));
  for (const path of ['pending', 'receipt', 'index', 'home']) assert.equal(await store.get('roomInvites/' + path), null);
});

test('cleanup retries an expired query without deleting a concurrently renewed issuer index', async () => {
  const { store } = restStore();
  await store.put('roomInvites/index', { kind: 'away-index', pendingHash: 'old', expiresAt: new Date(100000) });
  await store.put('roomInvites/old', { kind: 'away', expiresAt: new Date(100000) });
  let once = true;
  store.beforeCommit = async ({ writes }) => {
    if (once && writes.some((write) => write.delete?.endsWith('/roomInvites/index'))) {
      once = false;
      await store.put('roomInvites/index', { kind: 'away-index', pendingHash: 'new', expiresAt: new Date(600000) });
    }
  };
  assert.equal(await store.cleanup(100000), 1);
  assert.equal((await store.get('roomInvites/index')).data.pendingHash, 'new');
  assert.equal(await store.get('roomInvites/old'), null);
});

test('Worker away links work through the real REST store with concurrent receivers and same-UID retries', async () => {
  const { store } = restStore();
  const worker = createWorker({ storeFor: () => store, now: () => 100000,
    authenticate: async (request) => ({ uid: request.headers.get('authorization') }) });
  async function api(path, uid, input = {}) {
    const response = await worker.fetch(new Request('https://home.example/api' + path, {
      method: 'POST', headers: { authorization: uid, 'content-type': 'application/json' }, body: JSON.stringify(input)
    }), {});
    return { status: response.status, body: await response.json() };
  }
  const id = (await api('/rooms', 'home')).body.roomId;
  const homeInvite = await api(`/rooms/${id}/invite`, 'home');
  await api(`/rooms/${id}/join`, 'issuer', { secret: homeInvite.body.secret });
  const shared = await api(`/rooms/${id}/share-invite`, 'issuer');
  const results = await Promise.all(['receiver_a', 'receiver_b'].map((uid) => api(`/rooms/${id}/join`, uid, { secret: shared.body.secret })));
  assert.deepEqual(results.map((result) => result.status).sort(), [200, 403]);
  const winner = results[0].status === 200 ? 'receiver_a' : 'receiver_b';
  assert.equal((await api(`/rooms/${id}/join`, winner, { secret: shared.body.secret })).status, 200);
  assert.equal(Object.keys((await store.get(`rooms/${id}`)).data.members).length, 2);
});
