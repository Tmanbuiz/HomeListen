import test from "node:test";
import assert from "node:assert/strict";
import { IDBFactory } from "fake-indexeddb";
import { CATEGORIES, EpisodeRecorder, MAX_CLIP_BYTES, RecordingStore, clipName, decodePcmPacket, defaultRules, restoreRules, wav } from "../src/alert-recordings.js";

function packet(sequence, clock, samples = 1600) {
  const bytes = new ArrayBuffer(12 + samples * 2), view = new DataView(bytes);
  view.setUint32(0, 0x484c4131); view.setUint32(4, sequence, true); view.setUint32(8, clock >>> 0, true);
  for (let i = 0; i < samples; i++) view.setInt16(12 + i * 2, 1234, true);
  return bytes;
}
function fixture(category = "crying", seconds = 30) {
  let now = Date.UTC(2026, 9, 22, 1, 30);
  const rules = defaultRules(), clips = [];
  rules[category] = { recordAudio: true, minimumSeconds: seconds };
  const recorder = new EpisodeRecorder({ rules, now: () => now, onClip: (clip) => clips.push(clip) });
  let sequence = 0;
  return { recorder, clips, rules, advance(ms = 100, observed = category) {
    now += ms; recorder.feed(packet(sequence++, now)); recorder.observe(observed, now);
  }, jump(ms) { now += ms; }, get now() { return now; } };
}

test("recording is opt-in for all categories with crying30 and cough8 defaults", () => {
  const rules = defaultRules();
  assert.equal(rules.crying.minimumSeconds, 30); assert.equal(rules.coughing.minimumSeconds, 8);
  assert.ok(CATEGORIES.every((name) => rules[name].recordAudio === false));
  const restored = restoreRules('{"crying":{"recordAudio":true,"minimumSeconds":900},"coughing":{"recordAudio":"true","minimumSeconds":-5}}');
  assert.deepEqual(restored.crying, { recordAudio: true, minimumSeconds: 300 });
  assert.deepEqual(restored.coughing, { recordAudio: false, minimumSeconds: 0 });
  assert.deepEqual(restoreRules("bad"), defaultRules());
});

test("binary framing rejects bad magic, odd or unbounded packets", () => {
  const frame = decodePcmPacket(packet(3, 123)); assert.equal(frame.sequence, 3); assert.equal(frame.clock, 123); assert.equal(frame.pcm.byteLength, 3200);
  assert.equal(decodePcmPacket(new ArrayBuffer(11)), null);
  assert.equal(decodePcmPacket(new ArrayBuffer(6414)), null);
  assert.equal(decodePcmPacket(new ArrayBuffer(15)), null);
  assert.equal(decodePcmPacket(new ArrayBuffer(14)), null);
});

test("crying below30s is discarded and sustained episode includes triggering audio", async () => {
  const short = fixture();
  for (let i = 0; i < 299; i++) short.advance();
  short.recorder.stop(); assert.equal(short.clips.length, 0);
  const full = fixture();
  for (let i = 0; i < 350; i++) full.advance();
  assert.equal(full.recorder.recording, true);
  full.recorder.stop(); assert.equal(full.clips.length, 1);
  assert.equal(full.clips[0].durationMs, 35000);
  const data = new DataView(await full.clips[0].audio.arrayBuffer());
  assert.equal(data.getUint32(24, true), 16000); assert.equal(data.getUint16(22, true), 1);
  assert.equal(data.getUint32(40, true), 35000 * 32);
  assert.equal(data.getInt16(44, true), 1234);
});

test("silence ends the episode, checkbox off and Stop discard unqualified candidates", () => {
  const f = fixture("coughing", 8);
  for (let i = 0; i < 90; i++) f.advance();
  for (let i = 0; i < 22; i++) f.advance(100, null);
  assert.equal(f.clips.length, 1); assert.equal(f.recorder.candidate, null);
  assert.equal(f.clips[0].durationMs, 9000);
  assert.equal(f.clips[0].size, 9000 * 32 + 44);
  const off = fixture("crying", 30);
  off.advance(); off.rules.crying.recordAudio = false; off.recorder.stop("recording settings changed");
  assert.equal(off.clips.length, 0); assert.equal(off.recorder.preBytes, 0);
});

test("missing frame or long audio gap splits qualified clips and cannot qualify short ones", () => {
  const f = fixture("crying", 1);
  for (let i = 0; i < 20; i++) f.advance();
  f.recorder.feed(packet(90, f.now + 100));
  assert.equal(f.clips.length, 1); assert.equal(f.clips[0].reason, "connection interrupted");
  const short = fixture(); short.advance(); short.jump(1500); short.recorder.tick();
  assert.equal(short.clips.length, 0); assert.equal(short.recorder.preBytes, 0);
});

test("32-bit timestamp wrap retains continuous audio", () => {
  const f = fixture("crying", 0);
  f.recorder.feed(packet(0, 0xfffffff0)); f.recorder.observe("crying", f.now);
  f.recorder.feed(packet(1, 84));
  assert.equal(f.clips.length, 0);
  f.recorder.stop(); assert.equal(f.clips.length, 1);
});

test("single100ms source drop splits even when transport sequence is consecutive", () => {
  const f = fixture("crying", 1);
  for (let i = 0; i < 20; i++) f.advance();
  // Previous payload is100ms; a200ms source-clock step means a frame vanished
  // before sender sequence assignment, despite arriving as sequence20.
  f.jump(200); f.recorder.feed(packet(20, f.now));
  assert.equal(f.clips.length, 1); assert.equal(f.clips[0].reason, "connection interrupted");
  assert.equal(f.clips[0].durationMs, 2000);
});

test("PCM without detector verdicts ends clip and waits for fresh verdicts", () => {
  const f = fixture("crying", 1);
  for (let i = 0; i < 20; i++) f.advance();
  for (let i = 20; i < 56; i++) { f.jump(100); f.recorder.feed(packet(i, f.now)); f.recorder.tick(); }
  assert.equal(f.clips.length, 1); assert.equal(f.clips[0].durationMs, 2000);
  assert.equal(f.recorder.recording, false); assert.equal(f.recorder.waitingForVerdicts, true);
  f.recorder.observe("crying", f.now - 12 * 3600000);
  assert.equal(f.recorder.waitingForVerdicts, false);
  assert.equal(f.recorder.recording, true);
});

test("WAV filename includes local date time and sound, without path separators", () => {
  const at = new Date(2026, 9, 22, 1, 30, 0, 123).getTime();
  assert.equal(clipName("crying", at), "2026-10-22_01-30-00-123_Crying.wav");
  assert.ok(!clipName("loud sound", at).includes("/"));
});

test("out-of-range source timestamps cannot create invalid clip filenames", () => {
  const f = fixture("crying", 0);
  f.recorder.feed(packet(0, 123)); f.recorder.observe("crying", 1e300);
  f.recorder.stop();
  assert.equal(f.clips.length, 1); assert.ok(!f.clips[0].name.includes("NaN"));
});

test("recording filename uses receiver clock even when source is hours behind", () => {
  const f = fixture("crying", 0);
  f.recorder.feed(packet(0, 123)); f.recorder.observe("crying", f.now - 5 * 3600000);
  f.recorder.stop();
  assert.equal(f.clips[0].startedAt, f.now - 100);
  assert.ok(f.clips[0].name.startsWith(clipName("crying", f.now - 100).replace(".wav", "_")));
});

test("hard cap bounds a single candidate to10minutes", () => {
  const f = fixture("crying", 0);
  for (let i = 0; i < 6010; i++) f.advance();
  assert.equal(f.clips.length, 1); assert.ok(f.clips[0].size <= MAX_CLIP_BYTES + 44);
  assert.equal(f.clips[0].reason, "10 minute limit");
});

test("qualified crying continues across size split without another30s hold or overlapping samples", () => {
  const f = fixture("crying", 30);
  for (let i = 0; i < 6010; i++) f.advance();
  assert.equal(f.clips.length, 1);
  assert.equal(f.recorder.recording, true);
  f.recorder.stop();
  assert.equal(f.clips.length, 2);
  assert.equal(f.clips[0].durationMs, 600000);
  assert.equal(f.clips[1].durationMs, 1000);
  assert.equal(f.clips[1].startedAt, f.clips[0].startedAt + f.clips[0].durationMs);
  assert.equal(f.clips.reduce((sum, clip) => sum + clip.size - 44, 0), 601000 * 32);
});

test("split carries unconfirmed tail exactly once and final trim follows last match", () => {
  const f = fixture("crying", 30);
  for (let i = 0; i < 6350; i++) {
    f.jump(100); f.recorder.feed(packet(i, f.now));
    // Deliberately misalign detector windows and the10-minute audio boundary.
    if (i % 5 === 1) f.recorder.observe("crying", f.now);
  }
  f.recorder.stop();
  assert.equal(f.clips.length, 2);
  assert.equal(f.clips[0].durationMs, 599700);
  assert.equal(f.clips[1].durationMs, 35000);
  assert.equal(f.clips[1].startedAt, f.clips[0].startedAt + f.clips[0].durationMs);
  assert.equal(f.clips.reduce((sum, clip) => sum + clip.size - 44, 0), 634700 * 32);
});

test("IndexedDB saves playable blobs, deletes, and prunes by age/count", async () => {
  const now = Date.UTC(2026, 9, 22), store = new RecordingStore(new IDBFactory(), () => now);
  const audio = wav([new Uint8Array(32)], 32);
  for (let i = 0; i < 102; i++) await store.save({ id: String(i), startedAt: now - i * 100, audio, size: 76 });
  let rows = await store.list(); assert.equal(rows.length, 100);
  assert.equal(rows[0].audio.type, "audio/wav");
  await store.save({ id: "old", startedAt: now - 8 * 86400000, audio, size: 76 });
  assert.ok(!(await store.list()).some((clip) => clip.id === "old"));
  await store.delete("0"); assert.equal((await store.list()).length, 99);
  await store.clear(); assert.deepEqual(await store.list(), []);
});

test("IndexedDB cap retains newest clips under200MB", async () => {
  const store = new RecordingStore(new IDBFactory(), () => 1000000000);
  await store.save({ id: "a", startedAt: 999999999, size: 150 * 1024 * 1024 });
  await store.save({ id: "b", startedAt: 1000000000, size: 150 * 1024 * 1024 });
  assert.deepEqual((await store.list()).map((clip) => clip.id), ["b"]);
});
