import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import { IDBFactory } from 'fake-indexeddb';
import { savePushRooms } from '../src/room-registry.js';

async function worker() {
  const database = new IDBFactory(), handlers = {}, notifications = [], messages = [], opened = [];
  const context = vm.createContext({ indexedDB: database, Date, URL, self: {
    location: { origin: 'https://home.example' },
    addEventListener: (event, handler) => { handlers[event] = handler; },
    clients: { matchAll: async () => [], openWindow: async path => opened.push(path) },
    registration: { showNotification: async (...args) => notifications.push(args) }
  }, encodeURIComponent });
  vm.runInContext(await readFile(new URL('../public/sw.js', import.meta.url), 'utf8'), context);
  return { database, handlers, notifications, messages, opened, context, async push(roomId) {
    let work;
    handlers.push({ data: { json: () => ({ id: 'event_shared', title: 'Possible crying', room: 'Room', roomId, sentAt: Date.now() }) }, waitUntil: promise => { work = promise; } });
    await work;
  } };
}

test('background push accepts every saved room but suppresses a logged-out room', async () => {
  const f = await worker(); await savePushRooms(['room_a', 'room_b'], f.database);
  await f.push('room_a'); await f.push('room_b'); assert.equal(f.notifications.length, 2);
  await savePushRooms(['room_b'], f.database);
  await f.push('room_a'); assert.equal(f.notifications.length, 2);
  await f.push('room_b'); assert.equal(f.notifications.length, 3);
  await savePushRooms([], f.database); await f.push('room_b'); assert.equal(f.notifications.length, 3);
  assert.notEqual(f.notifications[0][1].tag, f.notifications[1][1].tag);
});

test('legacy installations without a room snapshot retain their push behavior', async () => {
  const f = await worker(); await f.push('legacy_room'); assert.equal(f.notifications.length, 1);
});

test('notification click opens or selects its room without requesting audio', async () => {
  const f = await worker(); let work;
  f.handlers.notificationclick({ notification: { close() {}, data: { roomId: 'room_b' } }, waitUntil: promise => { work = promise; } });
  await work; assert.deepEqual(f.opened, ['/?room=room_b']);
  f.context.self.clients.matchAll = async () => [{ url: 'https://home.example/', focus: async () => {}, postMessage: value => f.messages.push(value) }];
  f.handlers.notificationclick({ notification: { close() {}, data: { roomId: 'room_a' } }, waitUntil: promise => { work = promise; } });
  await work;
  assert.equal(f.messages.length, 1); assert.equal(f.messages[0].type, 'open-alert'); assert.equal(f.messages[0].roomId, 'room_a');
  assert.equal(f.messages[0].play, undefined);
});
