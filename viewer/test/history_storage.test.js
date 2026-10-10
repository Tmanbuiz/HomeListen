import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import { IDBFactory } from 'fake-indexeddb';
import { loadAll, MAX_EVENTS } from '../src/history.js';

const DAY = 86_400_000;
function open(indexedDB) {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('home-listen-history', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('events', { keyPath: 'id' });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function seed(indexedDB) {
  const db = await open(indexedDB);
  await new Promise((resolve, reject) => {
    const tx = db.transaction('events', 'readwrite');
    const store = tx.objectStore('events');
    const now = Date.now();
    for (let i = 0; i < 650; i++) store.put({ id: 'recent-' + i, sentAt: now - i * 1000, title: 'Possible crying', roomId: 'room' });
    store.put({ id: 'expired', sentAt: now - 31 * DAY });
    store.put({ id: 'future', sentAt: now + DAY });
    tx.oncomplete = resolve; tx.onerror = () => reject(tx.error);
  });
  db.close();
}
async function stored(indexedDB) {
  const db = await open(indexedDB);
  const rows = await new Promise((resolve, reject) => {
    const request = db.transaction('events', 'readonly').objectStore('events').getAll();
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
  db.close();
  return rows;
}

test('page load deletes stale and surplus records from IndexedDB itself', async () => {
  const previous = globalThis.indexedDB;
  const database = new IDBFactory();
  globalThis.indexedDB = database;
  try {
    await seed(database);
    assert.equal((await loadAll()).length, MAX_EVENTS);
    const rows = await stored(database);
    assert.equal(rows.length, MAX_EVENTS);
    assert.equal(rows.some(e => ['expired', 'future', 'recent-649'].includes(e.id)), false);
  } finally { globalThis.indexedDB = previous; }
});

test('background push prunes stored history even with no open browser page', async () => {
  const database = new IDBFactory();
  await seed(database);
  const handlers = {}, notifications = [];
  const context = vm.createContext({ indexedDB: database, Date, URL, self: {
    addEventListener: (name, handler) => { handlers[name] = handler; },
    clients: { matchAll: async () => [] },
    registration: { showNotification: async (...args) => { notifications.push(args); } }
  } });
  vm.runInContext(await readFile(new URL('../public/sw.js', import.meta.url), 'utf8'), context);
  let done;
  handlers.push({ data: { json: () => ({ id: 'background', title: 'Possible knocking', roomId: 'room', sentAt: Date.now() }) },
    waitUntil: (work) => { done = work; } });
  await done;
  const rows = await stored(database);
  assert.equal(rows.length, MAX_EVENTS);
  assert.equal(rows.some(e => e.id === 'background'), true);
  assert.equal(rows.some(e => ['expired', 'future', 'recent-649'].includes(e.id)), false);
  assert.equal(notifications.length, 1);
  done = null;
  handlers.push({ data: { json: () => ({ id: 'future-push', title: 'Future', sentAt: Date.now() + DAY }) },
    waitUntil: (work) => { done = work; } });
  assert.equal(done, null);
  assert.equal(notifications.length, 1);
});
