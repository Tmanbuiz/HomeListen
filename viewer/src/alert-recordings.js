// Receiver-only, opt-in recordings. PCM arrives inside the authorized live peer;
// no microphone, upload, or service-worker/background recording is used here.
export const RECORDING_CHANNEL = "homelisten-alert-audio-v1";
export const CATEGORIES = ["crying", "coughing", "barking", "knocking", "loud sound"];
export const LABELS = { crying: "Crying", coughing: "Coughing", barking: "Dog sounds", knocking: "Knocks and doorbells", "loud sound": "Loud sounds" };
export const MAX_CLIP_BYTES = 16_000 * 2 * 600;
const RATE = 32_000, GAP = 2000, DAY = 86_400_000;
export function defaultRules() {
  return Object.fromEntries(CATEGORIES.map((name) => [name, { recordAudio: false, minimumSeconds: name === "crying" ? 30 : name === "coughing" ? 8 : 0 }]));
}
export function restoreRules(raw) {
  const rules = defaultRules();
  try {
    const stored = JSON.parse(raw);
    for (const name of CATEGORIES) {
      rules[name].recordAudio = stored?.[name]?.recordAudio === true;
      const seconds = stored?.[name]?.minimumSeconds;
      if (Number.isInteger(seconds)) rules[name].minimumSeconds = Math.max(0, Math.min(300, seconds));
    }
  } catch { /* default: recording stays off */ }
  return rules;
}
export function decodePcmPacket(value) {
  if (!(value instanceof ArrayBuffer) || value.byteLength < 14 || value.byteLength > 6412 || value.byteLength % 2) return null;
  const view = new DataView(value);
  if (view.getUint32(0, false) !== 0x484c4131) return null; // HLA1
  return { sequence: view.getUint32(4, true), clock: view.getUint32(8, true), pcm: new Uint8Array(value.slice(12)) };
}
export function clipName(category, at, suffix = "") {
  const d = new Date(at), p = (n, width = 2) => String(n).padStart(width, "0");
  const stamp = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}-${p(d.getMilliseconds(), 3)}`;
  return `${stamp}_${LABELS[category].replaceAll(" ", "_")}${suffix}.wav`;
}
export function wav(parts, size) {
  const header = new ArrayBuffer(44), h = new DataView(header);
  for (const [offset, word] of [[0, "RIFF"], [8, "WAVE"], [12, "fmt "], [36, "data"]]) {
    for (let i = 0; i < word.length; i++) h.setUint8(offset + i, word.charCodeAt(i));
  }
  h.setUint32(4, size + 36, true); h.setUint32(16, 16, true); h.setUint16(20, 1, true);
  h.setUint16(22, 1, true); h.setUint32(24, 16_000, true); h.setUint32(28, RATE, true);
  h.setUint16(32, 2, true); h.setUint16(34, 16, true); h.setUint32(40, size, true);
  return new Blob([header, ...parts], { type: "audio/wav" });
}

export class EpisodeRecorder {
  constructor({ rules = defaultRules(), onClip = () => {}, onState = () => {}, now = () => Date.now() } = {}) {
    Object.assign(this, { rules, onClip, onState, now });
    this.pre = []; this.preBytes = 0; this.candidate = null;
    this.sequence = this.clock = this.lastPcmAt = this.lastVerdictAt = null;
    this.frameDuration = 0;
  }
  get enabled() { return CATEGORIES.some((name) => this.rules[name]?.recordAudio); }
  get recording() { return this.candidate?.qualified === true; }
  get waitingForVerdicts() {
    return this.lastPcmAt != null && this.now() - this.lastPcmAt <= 1000 &&
      (this.lastVerdictAt == null || this.now() - this.lastVerdictAt > 3000);
  }
  feed(packet) {
    if (!this.enabled) return;
    const frame = decodePcmPacket(packet);
    if (!frame) { this.stop("invalid audio frame"); return; }
    const delta = this.clock == null ? 0 : (frame.clock - this.clock) >>> 0;
    // A native capture tap can drop a100ms chunk before a sequence number is
    // assigned. Source-clock continuity catches that as well as transport loss.
    if (this.sequence != null && (frame.sequence !== ((this.sequence + 1) >>> 0) || delta > this.frameDuration + 80)) this.stop("connection interrupted");
    this.sequence = frame.sequence; this.clock = frame.clock; this.lastPcmAt = this.now();
    const { pcm } = frame;
    this.frameDuration = pcm.byteLength / RATE * 1000;
    const active = this.candidate;
    if (active) {
      if (this.waitingForVerdicts) this.finish("detector updates paused");
      else if (this.now() - active.lastMatched > GAP) this.finish();
      else if (active.size + pcm.byteLength > MAX_CLIP_BYTES) this.finish("10 minute limit");
      else { active.parts.push(pcm); active.size += pcm.byteLength; }
    }
    this.pre.push(pcm); this.preBytes += pcm.byteLength;
    while (this.pre.length > 1 && this.preBytes - this.pre[0].byteLength >= RATE) this.preBytes -= this.pre.shift().byteLength;
  }
  observe(category, _sourceAt = this.now()) {
    if (!this.enabled || this.lastPcmAt == null || this.now() - this.lastPcmAt > 1000) return;
    if (category !== null && !CATEGORIES.includes(category)) return;
    this.lastVerdictAt = this.now();
    const rule = this.rules[category];
    if (!CATEGORIES.includes(category) || !rule?.recordAudio) {
      if (this.candidate && this.now() - this.candidate.lastMatched >= GAP) this.finish();
      return;
    }
    if (this.candidate && this.candidate.category !== category) this.finish();
    if (!this.candidate) {
      this.candidate = {
        // Use this receiving device's clock for its filenames. A home phone's
        // clock can be wrong even while its monotonic PCM cadence is healthy.
        category, startedAt: this.now() - Math.round(this.preBytes / RATE * 1000),
        started: this.now() - this.preBytes / RATE * 1000, lastMatched: this.now(),
        parts: this.pre.slice(), size: this.preBytes, lastMatchedBytes: this.preBytes, qualified: false
      };
    }
    const active = this.candidate;
    active.lastMatched = this.now();
    active.lastMatchedBytes = active.size;
    // Both received samples and matching-time span must clear the rule. Missing
    // frames must never become 30 seconds of supposedly continuous crying.
    if (active.size / RATE >= rule.minimumSeconds && this.now() - active.started >= rule.minimumSeconds * 1000) active.qualified = true;
    this.onState(this.recording);
  }
  finish(reason = "sound ended") {
    const active = this.candidate;
    this.candidate = null;
    if (active?.qualified && active.size) {
      // The2s grace period joins brief pauses but is not part of the sound's
      // final clip. Keep samples only through the last matching verdict.
      const size = active.lastMatchedBytes;
      let remaining = size;
      const parts = [];
      for (const part of active.parts) {
        if (remaining <= 0) break;
        parts.push(part.byteLength <= remaining ? part : part.subarray(0, remaining));
        remaining -= Math.min(remaining, part.byteLength);
      }
      const id = `${active.startedAt}-${globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2)}`;
      this.onClip({ id, category: active.category, startedAt: active.startedAt,
        name: clipName(active.category, active.startedAt, `_${id.slice(-6)}`),
        durationMs: Math.round(size / RATE * 1000), reason,
        audio: wav(parts, size), size: size + 44 });
    }
    this.onState(false);
  }
  stop(reason = "listening stopped") {
    this.finish(reason); this.pre = []; this.preBytes = 0;
    this.sequence = this.clock = this.lastPcmAt = this.lastVerdictAt = null;
    this.frameDuration = 0;
  }
  tick() {
    if (this.lastPcmAt != null && this.now() - this.lastPcmAt > 1000) this.stop("connection interrupted");
    else if (this.candidate && this.waitingForVerdicts) this.finish("detector updates paused");
    else if (this.candidate && this.now() - this.candidate.lastMatched >= GAP) this.finish();
  }
}

function openRecordings(factory) {
  return new Promise((resolve, reject) => {
    const request = factory.open("home-listen-recordings", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("clips", { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
export class RecordingStore {
  constructor(factory = globalThis.indexedDB, now = () => Date.now()) { this.factory = factory; this.now = now; }
  async run(mode, work) {
    if (!this.factory) throw new Error("This browser cannot save audio. Use a browser with IndexedDB enabled.");
    const db = await openRecordings(this.factory);
    return new Promise((resolve, reject) => {
      const tx = db.transaction("clips", mode);
      const request = work(tx.objectStore("clips"));
      tx.oncomplete = () => { db.close(); resolve(request?.result); };
      tx.onerror = tx.onabort = () => { db.close(); reject(tx.error ?? new Error("Audio storage failed.")); };
    });
  }
  async list() {
    const rows = await this.run("readonly", (store) => store.getAll());
    let bytes = 0;
    const keep = [], drop = [];
    for (const clip of rows.sort((a, b) => b.startedAt - a.startedAt)) {
      if (clip.startedAt < this.now() - 7 * DAY || keep.length >= 100 || bytes + clip.size > 200 * 1024 * 1024) drop.push(clip.id);
      else { keep.push(clip); bytes += clip.size; }
    }
    if (drop.length) await this.run("readwrite", (store) => { for (const id of drop) store.delete(id); });
    return keep;
  }
  async save(clip) { await this.run("readwrite", (store) => store.put(clip)); await this.list(); }
  async delete(id) { await this.run("readwrite", (store) => store.delete(id)); }
  async clear() { await this.run("readwrite", (store) => store.clear()); }
}

export function createAlertRecordings(container) {
  const settingsKey = "homelisten-recording-rules-v1";
  let raw;
  try { raw = localStorage.getItem(settingsKey); } catch { /* unavailable */ }
  const rules = restoreRules(raw), store = new RecordingStore();
  let channel = null, timer = null, epoch = 0, urls = [], saveTail = Promise.resolve(), problem = null, state = "Recording is off. Select the sounds to save.";
  const heading = document.createElement("h2"); heading.textContent = "Record sound alerts";
  const help = document.createElement("p"); help.className = "fine";
  help.textContent = "Optional audio is saved only in this receiving browser. Keep Listen live connected from the start of the sound. The home phone must use Live + Guardian and enable that sound. Recording can stop when the page closes or the device suspends. Browser storage can be cleared or evicted; download clips you want to keep.";
  const status = document.createElement("p"); status.className = "recording-status"; status.setAttribute("role", "status");
  const ruleBox = document.createElement("div"), list = document.createElement("ol"); list.className = "recording-list";
  const error = (value) => { problem = `Recording problem: ${value.message ?? value}`; renderStatus(); };
  const recorder = new EpisodeRecorder({ rules,
    onState: () => renderStatus(),
    onClip: (clip) => {
      saveTail = saveTail.then(() => store.save(clip)).then(renderList).catch(error);
    }
  });
  function renderStatus() {
    status.textContent = problem ?? (recorder.recording ? "● Recording this sound on this device…" :
      !recorder.enabled ? "Recording is off. Select the sounds to save." :
      channel?.readyState === "open" ? (recorder.lastPcmAt == null
        ? "Waiting for recording audio · update the home app if this continues"
        : recorder.waitingForVerdicts ? "Waiting for sound detector updates · no audio is being saved"
        : "Waiting for selected sounds · live connection required") : state);
    status.classList.toggle("recording-active", recorder.recording);
  }
  function subscribe() {
    if (channel?.readyState === "open") channel.send(recorder.enabled ? "subscribe" : "unsubscribe");
    renderStatus();
  }
  function changed() {
    problem = null;
    recorder.stop("recording settings changed");
    try { localStorage.setItem(settingsKey, JSON.stringify(rules)); } catch { error("Settings could not be saved for your next visit."); }
    subscribe();
  }
  for (const category of CATEGORIES) {
    const row = document.createElement("div"); row.className = "recording-rule";
    const label = document.createElement("label"), check = document.createElement("input"); check.type = "checkbox"; check.checked = rules[category].recordAudio;
    label.append(check, document.createTextNode(`Record ${LABELS[category].toLowerCase()}`));
    check.addEventListener("change", () => { rules[category].recordAudio = check.checked; changed(); });
    const hold = document.createElement("label"); hold.textContent = "Save episode after ";
    const select = document.createElement("select"); select.className = "field"; select.setAttribute("aria-label", `${LABELS[category]} minimum duration`);
    for (const seconds of [...new Set([0, 8, 15, 30, 60, 120, 300, rules[category].minimumSeconds])].sort((a, b) => a - b)) {
      const option = document.createElement("option"); option.value = String(seconds); option.textContent = seconds === 0 ? "Immediately" : seconds >= 60 ? `${seconds / 60} min` : `${seconds}s`;
      option.selected = seconds === rules[category].minimumSeconds; select.append(option);
    }
    select.addEventListener("change", () => { rules[category].minimumSeconds = Number(select.value); changed(); });
    hold.append(select); row.append(label, hold); ruleBox.append(row);
  }
  async function renderList() {
    const clips = await store.list();
    for (const url of urls) URL.revokeObjectURL(url); urls = [];
    list.replaceChildren();
    for (const clip of clips) {
      const item = document.createElement("li"), name = document.createElement("strong"), info = document.createElement("p"), player = document.createElement("audio");
      name.textContent = clip.name; info.className = "fine"; info.textContent = `${(clip.durationMs / 1000).toFixed(1)}s · ${clip.reason}`;
      const url = URL.createObjectURL(clip.audio); urls.push(url); player.src = url; player.controls = true; player.preload = "none";
      const actions = document.createElement("div"); actions.className = "recording-actions";
      const download = document.createElement("a"); download.href = url; download.download = clip.name; download.textContent = "Download";
      const remove = document.createElement("button"); remove.type = "button"; remove.className = "small secondary"; remove.textContent = "Delete";
      remove.addEventListener("click", () => { void store.delete(clip.id).then(renderList).catch(error); });
      actions.append(download, remove); item.append(name, info, player, actions); list.append(item);
    }
    if (!clips.length) { const empty = document.createElement("li"); empty.textContent = "No recorded alerts yet."; list.append(empty); }
  }
  const limits = document.createElement("p"); limits.className = "fine"; limits.textContent = "Clips close after a 2-second detection gap and trim back to the last matching sound. Long episodes split at 10 minutes. Kept for 7 days, up to 100 clips or 200 MB. Short candidates below your duration are discarded.";
  const clear = document.createElement("button"); clear.type = "button"; clear.className = "secondary"; clear.textContent = "Delete all recordings";
  clear.addEventListener("click", () => { if (confirm("Delete all audio recordings from this browser?")) { recorder.stop("recordings cleared"); void saveTail.then(() => store.clear()).then(renderList).catch(error); } });
  container.append(heading, help, ruleBox, status, limits, list, clear);
  renderStatus(); void renderList().catch(error);
  return {
    attachPeer(pc) {
      this.stop(); const generation = ++epoch;
      channel = pc.createDataChannel(RECORDING_CHANNEL, { ordered: true });
      const current = channel; current.binaryType = "arraybuffer";
      current.onopen = () => { if (generation === epoch) subscribe(); };
      current.onmessage = (event) => {
        if (generation !== epoch || !recorder.enabled) return;
        if (event.data instanceof ArrayBuffer) { recorder.feed(event.data); return; }
        if (typeof event.data !== "string" || event.data.length > 512) return;
        try {
          const verdict = JSON.parse(event.data);
          if (verdict.type === "verdict" && (verdict.category === null || CATEGORIES.includes(verdict.category)) && Number.isFinite(verdict.at)) recorder.observe(verdict.category, verdict.at);
        } catch { /* ignore malformed control data */ }
      };
      current.onclose = current.onerror = () => { if (generation === epoch) { recorder.stop("connection interrupted"); state = "Recording stopped · reconnect live audio to continue."; renderStatus(); } };
      timer = setInterval(() => { recorder.tick(); renderStatus(); }, 500);
      state = "Recording armed · choose Listen live to receive audio."; renderStatus();
    },
    interrupted() {
      recorder.stop("connection interrupted");
    },
    stop() {
      epoch++; clearInterval(timer); timer = null;
      const old = channel; channel = null;
      if (old) { old.onopen = old.onmessage = old.onclose = old.onerror = null; old.close(); }
      recorder.stop(); state = "Recording armed · choose Listen live to receive audio."; renderStatus();
    }
  };
}
