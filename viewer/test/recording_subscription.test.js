import test from 'node:test';
import assert from 'node:assert/strict';
import { RecordingSubscription } from '../src/recording-subscription.js';

test('a lost subscription is retried, audio/ack stops retries, off ignores late ack', t => {
  t.mock.timers.enable({apis:['setTimeout']});
  const sent = [];
  const s = new RecordingSubscription({send: m => sent.push(m), isOpen: () => true});
  s.request(true); t.mock.timers.tick(1000);
  assert.deepEqual(sent, ['subscribe','subscribe']);
  s.acknowledge(); t.mock.timers.tick(10000);
  assert.equal(sent.length, 2); assert.equal(s.ready, true);
  s.request(false); s.acknowledge();
  assert.equal(s.ready, false); assert.equal(sent.at(-1), 'unsubscribe');
  s.close();
});
test('open is observed, retries are bounded, and close cancels recovery', t => {
  t.mock.timers.enable({apis:['setTimeout']});
  let open = false; const sent = [];
  const s = new RecordingSubscription({send: m => sent.push(m), isOpen: () => open});
  s.request(true); assert.equal(sent.length, 0);
  open = true; s.opened();
  for (let i=0;i<6;i++) t.mock.timers.tick(1000);
  assert.equal(sent.length, 5); assert.equal(s.exhausted, true);
  s.request(true); s.close(); t.mock.timers.tick(10000);
  assert.equal(sent.length, 6);
});
