import test from 'node:test';
import assert from 'node:assert/strict';
import { EpisodeRecorder, defaultRules, MAX_CLIP_BYTES } from '../src/alert-recordings.js';

function fixture() {
  let now = 1_800_000_000_000, sequence = 0, context = { roomId: 'room_a', roomName: 'Bedroom' };
  const clips = [], rules = defaultRules();
  const recorder = new EpisodeRecorder({ rules, now: () => now, context: () => context, onClip: clip => clips.push(clip) });
  function frame({ skip = false } = {}) {
    now += 100; if (skip) sequence++;
    const bytes = new ArrayBuffer(3212), view = new DataView(bytes);
    view.setUint32(0, 0x484c4131); view.setUint32(4, sequence++ >>> 0, true); view.setUint32(8, now >>> 0, true);
    recorder.feed(bytes);
  }
  return { recorder, clips, rules, frame, switchRoom() { context = { roomId: 'room_b', roomName: 'Children room' }; }, advance(ms) { now += ms; } };
}

test('manual recording is opt-in and saves PCM without detector verdicts or category consent changes', () => {
  const f = fixture(); f.frame(); assert.equal(f.recorder.recording, false);
  f.recorder.startManual(); for (let i = 0; i < 30; i++) f.frame();
  assert.equal(f.recorder.recording, true); f.recorder.stopManual();
  assert.equal(f.clips.length, 1); assert.equal(f.clips[0].durationMs, 3000);
  assert.equal(f.clips[0].category, 'manual'); assert.equal(f.clips[0].roomId, 'room_a');
  assert.match(f.clips[0].name, /^Bedroom_.*Room_recording/);
  assert.ok(Object.values(f.rules).every(rule => rule.recordAudio === false));
  f.frame(); assert.equal(f.clips.length, 1); assert.equal(f.recorder.enabled, false);
});

test('room switches finalize the old clip and a new tap records the new room separately', () => {
  const f = fixture(); f.recorder.startManual(); f.frame(); f.frame();
  f.recorder.stop('room changed'); f.switchRoom(); f.frame();
  assert.equal(f.clips.length, 1); assert.equal(f.clips[0].roomId, 'room_a');
  assert.equal(f.recorder.manualArmed, false);
  f.recorder.startManual(); f.frame(); f.recorder.stopManual();
  assert.equal(f.clips.length, 2); assert.equal(f.clips[1].roomId, 'room_b');
  assert.equal(f.clips[1].durationMs, 100);
});

test('missing audio and channel loss stop manual recording until explicitly started again', () => {
  const f = fixture(); f.recorder.startManual(); f.frame(); f.frame({ skip: true });
  assert.equal(f.recorder.manualArmed, false); assert.equal(f.clips.length, 1);
  f.frame(); assert.equal(f.clips.length, 1);
  f.recorder.startManual(); f.frame(); f.advance(1100); f.recorder.tick();
  assert.equal(f.recorder.manualArmed, false); assert.equal(f.clips.length, 2);
});

test('manual recording with no source audio times out without inventing a clip', () => {
  const f = fixture(); f.recorder.startManual(); f.advance(5100); f.recorder.tick();
  assert.equal(f.recorder.manualArmed, false); assert.equal(f.clips.length, 0);
  assert.match(f.recorder.manualProblem, /No recording audio/);
});

test('manual recordings split at ten minutes without losing PCM or room attribution', () => {
  const f = fixture(); f.recorder.startManual();
  for (let i = 0; i < 6010; i++) f.frame();
  f.recorder.stopManual(); assert.equal(f.clips.length, 2);
  assert.ok(f.clips.every(clip => clip.size <= MAX_CLIP_BYTES + 44 && clip.roomId === 'room_a'));
  assert.equal(f.clips.reduce((sum, clip) => sum + clip.durationMs, 0), 601000);
});
