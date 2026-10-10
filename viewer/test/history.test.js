import test from "node:test";
import assert from "node:assert/strict";
import { dailyCounts, exportJson, filterEvents, trim } from "../src/history.js";

const DAY = 86_400_000;
const NOW = new Date(2026, 9, 10, 12, 0, 0).getTime();
const ev = (id, daysAgo, kind = "crying", title = "Possible crying") =>
  ({ id, title, kind, room: "Bedroom", sentAt: NOW - daysAgo * DAY });

test("trim keeps newest first, drops duplicates and anything older than 30 days", () => {
  const out = trim([ev("a", 1), ev("b", 0), ev("a", 1), ev("old", 31), { title: "no id", sentAt: NOW }], NOW);
  assert.deepEqual(out.map((e) => e.id), ["b", "a"]);
});

test("trim caps the history at 500 events", () => {
  const many = Array.from({ length: 700 }, (_, i) => ({ ...ev("e" + i, 0), sentAt: NOW - i }));
  const out = trim(many, NOW);
  assert.equal(out.length, 500);
  assert.equal(out[0].id, "e0");
});

test("filters by range, category and search text", () => {
  const list = [ev("a", 0, "crying"), ev("b", 3, "barking", "Possible barking"), ev("c", 20, "crying")];
  assert.deepEqual(filterEvents(list, { days: 1, now: NOW }).map((e) => e.id), ["a"]);
  assert.deepEqual(filterEvents(list, { days: 30, kind: "barking", now: NOW }).map((e) => e.id), ["b"]);
  assert.deepEqual(filterEvents(list, { days: 30, query: "  BARK ", now: NOW }).map((e) => e.id), ["b"]);
  assert.deepEqual(filterEvents(list, { days: 30, query: "bedroom", now: NOW }).map((e) => e.id), ["a", "b", "c"]);
});

test("daily counts include days with no alerts, oldest first", () => {
  const counts = dailyCounts([ev("a", 0), ev("b", 0), ev("c", 2)], 3, NOW);
  assert.deepEqual(counts.map((c) => c.count), [1, 0, 2]);
  assert.equal(counts.length, 3);
});

test("the export is metadata only", () => {
  const data = JSON.parse(exportJson([ev("a", 0)], NOW));
  assert.deepEqual(Object.keys(data.events[0]).sort(), ["at", "id", "kind", "room", "title"]);
  assert.match(data.note, /No audio/);
});
