import "./style.css";
import { initializeApp } from "firebase/app";
import { getAuth, signInAnonymously } from "firebase/auth";
import { getFirestore, doc, collection, onSnapshot, updateDoc, addDoc, Timestamp } from "firebase/firestore";
import { parsePairing } from "./pairing.js";
import { recoveringWatch } from "./recovering-watch.js";
import { AudioSession } from "./audio-session.js";
import { createAlertRecordings, RECORDING_CHANNEL } from "./alert-recordings.js";
import { memberAccess, canListen } from "./access.js";
import { RoomRegistry, savePushRooms } from "./room-registry.js";
import { MultiRoomSessions } from "./multi-room-sessions.js";
import { clearAll, dailyCounts, exportJson, filterEvents, loadAll, roomEvents, saveEvent } from "./history.js";

const el = id => document.getElementById(id);
let auth, db, config, registration, addingRoom = false, loggingOut = false;
let roomId = null, historyAll = [], historyRows = [], pushTail = Promise.resolve(), leavesTail = Promise.resolve();
const registry = new RoomRegistry({
  getItem: key => localStorage.getItem(key), setItem: (key, value) => localStorage.setItem(key, value), removeItem: key => localStorage.removeItem(key)
}, () => message("Rooms cannot be saved in this browser. Check storage permissions.", true));
const recordingsPanel = document.createElement("section"); recordingsPanel.className = "card";
el("home-panel").after(recordingsPanel);
const recordings = createAlertRecordings(recordingsPanel); recordingsPanel.hidden = true;
const openedInvite = location.hash.includes("pair=") ? location.href : null;
const alertRoom = new URL(location.href).searchParams.get("room");
if (openedInvite) history.replaceState(null, "", location.pathname + location.search);
if (alertRoom && registry.rooms.has(alertRoom)) registry.select(alertRoom);

const sessions = new MultiRoomSessions({ registry,
  allowed: room => canListen(room, auth?.currentUser?.uid),
  createAudio: () => { const audio = document.createElement("audio"); audio.autoplay = true; audio.playsInline = true; audio.hidden = true; document.body.append(audio); return audio; },
  createSession: (id, callbacks) => new AudioSession({ api, roomId: id, firestore: signaling(id), ...callbacks }),
  onPeer: (entry, pc) => {
    // Negotiate each channel before its initial offer. Switching only changes
    // recording subscriptions, never peer lifetime or another room's audio.
    entry.channel = pc.createDataChannel(RECORDING_CHANNEL, { ordered: true });
    if (registry.selected === entry.id) selectRecording(entry);
  },
  onChanged: renderRooms,
  onInterrupted: () => recordings.interrupted(),
  onSelected: entry => { roomId = entry?.id ?? null; selectRecording(entry); void renderHistory(); }
});
function selectRecording(entry) {
  recordings.attachChannel(entry?.channel ?? null, { roomId: entry?.id, roomName: registry.rooms.get(entry?.id)?.name });
}
function message(text, error = false) {
  el("message").textContent = text; el("message").classList.toggle("error", error);
}
function event(text) {
  const item = document.createElement("li"), stamp = document.createElement("time");
  stamp.textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  item.append(stamp, document.createTextNode(text)); el("events").prepend(item);
  while (el("events").children.length > 30) el("events").lastElementChild.remove();
  el("empty-activity").hidden = true;
}
async function api(path, data = undefined, method = "POST") {
  let tokenTimer;
  const token = await Promise.race([auth.currentUser.getIdToken(),
    new Promise((_, reject) => { tokenTimer = setTimeout(() => reject(new Error("Sign-in timed out. Try again.")), 15_000); })
  ]).finally(() => clearTimeout(tokenTimer));
  const response = await fetch("/api" + path, { signal: AbortSignal.timeout(15_000), method,
    headers: { authorization: "Bearer " + token, "content-type": "application/json" },
    ...(data === undefined ? {} : { body: JSON.stringify(data) }) });
  const result = await response.json();
  if (!response.ok) throw Object.assign(new Error(result.error ?? "Home Listen could not complete this request."), { code: result.code, status: response.status });
  return result;
}
function sharing(room) { return room?.sharing === true && Date.now() - room.lastSeenMs < 120_000; }
function renderRooms() {
  const selected = sessions.selected, uid = auth?.currentUser?.uid;
  roomId = selected?.id ?? null;
  el("rooms-panel").hidden = registry.rooms.size === 0;
  el("home-panel").hidden = !selected; recordingsPanel.hidden = !selected;
  el("pair-panel").hidden = registry.rooms.size > 0 && !addingRoom;
  el("cancel-pair-button").hidden = !registry.rooms.size;
  el("forget-button").hidden = true; el("logout-button").hidden = !selected;
  el("logout-button").disabled = loggingOut || !auth?.currentUser;
  el("room-select").replaceChildren(...[...registry.rooms.values()].map(row => {
    const option = document.createElement("option"); option.value = row.id; option.textContent = row.name; option.selected = row.id === registry.selected; return option;
  }));
  el("room-connections").replaceChildren(...[...sessions.entries.values()].map(entry => {
    const item = document.createElement("li");
    const state = entry.session ? entry.state === "connected" ? "Connected" : "Connecting" : entry.state === "reconnecting" ? "Reconnecting" : !entry.room ? "Checking access" : !sharing(entry.room) ? "Monitoring off" : !canListen(entry.room, uid) ? "Live audio unavailable" : "Audio paused";
    item.textContent = `${registry.rooms.get(entry.id)?.name ?? "Room"} · ${state}${entry.id === registry.selected ? " · selected" : " · muted"}`; return item;
  }));
  el("listen-button").disabled = loggingOut || ![...sessions.entries.values()].some(entry => canListen(entry.room, uid) && !entry.session);
  el("stop-button").disabled = ![...sessions.entries.values()].some(entry => entry.session || entry.retry);
  if (!selected) { el("history-panel").hidden = true; return; }
  const room = selected.room, live = sharing(room), alerts = room?.watchers?.[uid] === true;
  recordings.setRoomContext({ roomId: selected.id, roomName: registry.rooms.get(selected.id)?.name });
  el("room-name").textContent = registry.rooms.get(selected.id)?.name ?? "Your room";
  el("sharing-status").textContent = !room ? "Checking access…" : !live ? "Monitoring off" : room.audioAvailable === false ? "Guardian on · live audio off" : "Sharing on";
  el("sharing-status").classList.toggle("live", live);
  el("audio-status").textContent = selected.problem ?? (selected.blocked || (selected.session && !sessions.audible) ? "Connected · tap to hear this room." : selected.state === "connected" ? "You’re listening to this room." : selected.session ? "Connecting to this room…" : "Ready when you are.");
  document.querySelector(".sound-orb").classList.toggle("playing", selected.state === "connected" && sessions.audible && !selected.blocked);
  el("play-button").hidden = !selected.session || (sessions.audible && !selected.blocked);
  el("battery").textContent = "Home battery: " + (live && room.battery != null ? room.battery + "%" + (room.charging ? " · charging" : "") : "—");
  el("alerts-button").textContent = alerts ? "Disable room alerts" : "Enable room alerts";
  el("alerts-button").disabled = loggingOut || !room;
  el("alerts-status").textContent = alerts ? "Alerts are enabled for this room, even when another room is selected." : "Get a notification when this room detects a selected sound.";
}
function syncPushAccess() {
  const ids = [...registry.rooms.keys()];
  pushTail = pushTail.catch(() => {}).then(() => savePushRooms(ids)).catch(() => message("Room access could not be saved for background notifications. Check browser storage.", true));
  return pushTail;
}
function flushLeaves() {
  leavesTail = leavesTail.then(() => registry.flushLeaves(async id => {
    try { await api(`/rooms/${id}/leave`, {}); } catch (error) { if (error.status !== 404) throw error; }
  }));
  return leavesTail;
}
async function removeRoom(id, { logout = false, reason = "Room access was removed. Pair again with a fresh link." } = {}) {
  const entry = sessions.entries.get(id); if (!entry) return;
  entry.unwatch?.(); entry.unwatch = null;
  await sessions.remove(id, { pendingLeave: logout }); await syncPushAccess();
  if (logout) await flushLeaves();
  message(reason); event(reason);
}
function watchRoom(id) {
  const entry = sessions.ensure(id); if (entry.unwatch) return;
  entry.unwatch = recoveringWatch((next, error) => onSnapshot(doc(db, "rooms", id), { includeMetadataChanges: true },
    snapshot => { if (!snapshot.metadata.fromCache) next(snapshot); }, error), snapshot => {
    if (sessions.entries.get(id) !== entry) return;
    const data = snapshot.data();
    if (!snapshot.exists() || !memberAccess(data, auth.currentUser.uid)) { void removeRoom(id); return; }
    registry.update(id, { alerts: data.watchers?.[auth.currentUser.uid] === true }); sessions.update(id, data);
  }, error => {
    if (sessions.entries.get(id) !== entry) return;
    entry.problem = error.code === "permission-denied" ? "Room access is being checked…" : "Cloud connection lost. Reconnecting…";
    sessions.update(id, null);
    // A listener error is not proof of revocation. Confirm current membership
    // before discarding it, while pausing audio until fresh access is verified.
    void api(`/rooms/${id}`, undefined, "GET").catch(failure => {
      if (sessions.entries.get(id) === entry && failure.status === 404) void removeRoom(id);
    });
  });
}
function browserName() {
  const ua = navigator.userAgent;
  const os = /iPhone|iPad/.test(ua) ? "iPhone" : /Android/.test(ua) ? "Android" : /Windows/.test(ua) ? "Windows" : /Mac/.test(ua) ? "Mac" : "device";
  const browser = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "Browser";
  return browser + " on " + os;
}
async function addedRoom(id, data) {
  registry.add(id, data?.roomName ?? registry.rooms.get(id)?.name ?? "Your room");
  sessions.ensure(id); addingRoom = false; watchRoom(id);
  if (data) sessions.update(id, data);
  await sessions.select(id); await syncPushAccess();
  message("Room saved. Other rooms stay connected; only the selected room is audible.");
}
async function pair(value) {
  if (loggingOut) return;
  const invite = parsePairing(value, location.origin);
  if (!invite) throw new Error("Use a Home Listen pairing link from this server.");
  if (!auth.currentUser) await signInAnonymously(auth);
  await flushLeaves();
  const result = await api(`/rooms/${invite.roomId}/join`, { secret: invite.secret, label: browserName() });
  el("pair-code").value = ""; await addedRoom(invite.roomId, result.room); event("Paired with another room");
}
function signaling(id) {
  const path = sid => doc(db, "rooms", id, "sessions", sid), candidates = sid => collection(path(sid), "candidates");
  return {
    watchSession: (sid, next, error) => onSnapshot(path(sid), snapshot => next(snapshot.data()), error),
    watchCandidates: (sid, next, error) => onSnapshot(candidates(sid), snapshot => next(snapshot.docChanges().filter(change => change.type === "added").map(change => ({ ...change.doc.data(), id: change.doc.id }))), error),
    addCandidate: (sid, value) => addDoc(candidates(sid), { ...value, expiresAt: Timestamp.fromDate(new Date(value.expiresAt)) }),
    setOffer: (sid, offer) => updateDoc(path(sid), { offer }), end: sid => updateDoc(path(sid), { ended: true })
  };
}
function vapidBytes(value) {
  const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4));
  return Uint8Array.from(binary, char => char.charCodeAt(0));
}
async function toggleAlerts() {
  const entry = sessions.selected; if (loggingOut || !entry?.room) return;
  const id = entry.id; el("alerts-button").disabled = true;
  try {
    if (entry.room.watchers?.[auth.currentUser.uid] === true) {
      await api(`/rooms/${id}/device`, undefined, "DELETE"); registry.update(id, { alerts: false });
      entry.room = { ...entry.room, watchers: { ...entry.room.watchers, [auth.currentUser.uid]: false } };
      // The browser endpoint is shared by all rooms (and tabs). Removing one
      // server registration must never unsubscribe the shared endpoint.
      message("Alerts disabled for this room. Other rooms are unchanged.");
    } else {
      if (!registration || !("PushManager" in window)) throw new Error("This browser cannot receive alerts. On iPhone, add Home Listen to the Home Screen first.");
      if (!config.vapidPublicKey) throw new Error("The server needs its web push keys before alerts can be enabled.");
      if (Notification.permission !== "granted" && await Notification.requestPermission() !== "granted") throw new Error("Allow Home Listen notifications in this phone’s settings.");
      const subscription = await registration.pushManager.getSubscription() ?? await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: vapidBytes(config.vapidPublicKey) });
      await api(`/rooms/${id}/device`, { kind: "webpush", subscription: subscription.toJSON() }); registry.update(id, { alerts: true });
      entry.room = { ...entry.room, watchers: { ...entry.room.watchers, [auth.currentUser.uid]: true } };
      message("Alerts enabled for this room. Send a test alert at home.");
    }
  } catch (error) { message(error.message, true); }
  finally { renderRooms(); }
}
async function logoutRoom() {
  const id = registry.selected; if (loggingOut || !id) return;
  loggingOut = true; renderRooms();
  try { await removeRoom(id, { logout: true, reason: "This device left the room. Other rooms and devices stay connected." }); }
  finally { loggingOut = false; renderRooms(); }
  // Anonymous Firebase identity remains shared by this device's other rooms.
}

el("pair-form").addEventListener("submit", async e => {
  e.preventDefault(); el("pair-button").disabled = true;
  try { await pair(el("pair-code").value); } catch (error) { message(error.message, true); }
  finally { el("pair-button").disabled = false; }
});
el("room-select").addEventListener("change", e => { void sessions.select(e.target.value); });
el("add-room-button").addEventListener("click", () => { addingRoom = true; renderRooms(); el("pair-panel").scrollIntoView({ block: "start", behavior: "smooth" }); });
el("cancel-pair-button").addEventListener("click", () => { addingRoom = false; renderRooms(); });
el("listen-button").addEventListener("click", () => { void sessions.startAll().then(() => sessions.playSelected()); });
el("stop-button").addEventListener("click", () => { void sessions.stopAll(); });
el("play-button").addEventListener("click", () => { void sessions.playSelected(); });
el("volume").addEventListener("input", e => sessions.setVolume(e.target.value));
el("alerts-button").addEventListener("click", toggleAlerts);
el("forget-button").addEventListener("click", logoutRoom);
el("logout-button").addEventListener("click", logoutRoom);
window.addEventListener("offline", () => { void sessions.suspend(); message("No internet connection. Saved rooms are retained.", true); });
window.addEventListener("online", () => { void flushLeaves().then(() => sessions.resume()); });
window.addEventListener("pagehide", () => { void sessions.suspend(); });
window.addEventListener("pageshow", e => { if (e.persisted) void sessions.resume(); });
el("install-help").hidden = !(/iPhone|iPad/.test(navigator.userAgent) && !matchMedia("(display-mode: standalone)").matches);
setInterval(() => {
  for (const entry of sessions.entries.values()) {
    if (entry.room && !memberAccess(entry.room, auth?.currentUser?.uid)) void removeRoom(entry.id);
    else if (entry.room) sessions.update(entry.id, entry.room);
  }
}, 10_000);

// Sound history follows the selected room. Late reads cannot replace another
// room's list after switching.
async function renderHistory() {
  const selected = roomId;
  historyAll = await loadAll(); if (selected !== roomId) return;
  const panel = el("history-panel"); panel.hidden = !roomId;
  if (!roomId) { historyRows = []; return; }
  const days = Number(el("history-days").value);
  const rows = filterEvents(roomEvents(historyAll, roomId), { query: el("history-search").value, kind: el("history-kind").value, days });
  historyRows = rows;
  const counts = dailyCounts(rows, Math.min(days, 14)), peak = Math.max(1, ...counts.map(c => c.count));
  el("history-counts").replaceChildren(...counts.map(c => {
    const bar = document.createElement("span"); bar.style.height = Math.max(4, Math.round((c.count / peak) * 44)) + "px"; bar.className = c.count ? "has" : "";
    bar.title = c.day + ": " + c.count + (c.count === 1 ? " alert" : " alerts"); return bar;
  }));
  el("history-empty").hidden = rows.length > 0;
  el("history-list").replaceChildren(...rows.map(e => {
    const item = document.createElement("li"), label = document.createElement("span"), time = document.createElement("time"); label.textContent = e.title;
    time.dateTime = new Date(e.sentAt).toISOString(); time.textContent = new Date(e.sentAt).toLocaleString([], { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
    item.append(label, time); return item;
  }));
}
for (const id of ["history-search", "history-kind", "history-days"]) el(id).addEventListener("input", () => void renderHistory());
el("history-export").addEventListener("click", () => {
  const link = document.createElement("a"); link.href = URL.createObjectURL(new Blob([exportJson(historyRows)], { type: "application/json" })); link.download = "home-listen-history.json"; link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 5000);
});
el("history-clear").addEventListener("click", async () => { if (confirm("Clear the alert history on this phone?")) { await clearAll(); await renderHistory(); } });
document.addEventListener("visibilitychange", () => { if (!document.hidden) void renderHistory(); });

async function joinWithCode() {
  if (loggingOut) return;
  const answer = el("answer").value.trim(), code = el("totp-code").value.replace(/\D/g, "");
  if (!answer || code.length !== 6 || el("code-button").disabled) return;
  el("code-button").disabled = true;
  try {
    if (!auth.currentUser) await signInAnonymously(auth);
    await flushLeaves();
    const result = await api("/join-code", { answer, code, label: browserName() });
    el("answer").value = ""; el("totp-code").value = ""; await addedRoom(result.roomId, result.room); event("Paired with another room");
  } catch (error) { message(error.message, true); el("totp-code").value = ""; el("totp-code").focus(); }
  finally { el("code-button").disabled = false; }
}
el("code-form").addEventListener("submit", e => { e.preventDefault(); void joinWithCode(); });
el("totp-code").addEventListener("input", () => {
  if (el("totp-code").value.replace(/\D/g, "").length !== 6) return;
  if (!el("answer").value.trim()) { message("Enter the secret answer for your home.", true); el("answer").focus(); return; }
  void joinWithCode();
});

try {
  const response = await fetch("/api/config", { cache: "no-store" }), result = await response.json();
  if (!response.ok) throw new Error(result.error);
  config = result;
  const app = initializeApp(config.firebase); auth = getAuth(app); db = getFirestore(app);
  await auth.authStateReady(); if (!auth.currentUser) await signInAnonymously(auth);
  if ("serviceWorker" in navigator) {
    await navigator.serviceWorker.register("/sw.js"); registration = await navigator.serviceWorker.ready;
    navigator.serviceWorker.addEventListener("message", e => {
      if (e.data?.type === "sound-alert" && registry.rooms.has(e.data.data?.roomId)) {
        event(`${e.data.data.title} · ${registry.rooms.get(e.data.data.roomId).name}`); void saveEvent(e.data.data).then(renderHistory);
      }
      if (e.data?.type === "open-alert" && registry.rooms.has(e.data.roomId)) void sessions.select(e.data.roomId, { play: false });
    });
  }
  registry.save(); await syncPushAccess(); await flushLeaves();
  for (const id of registry.rooms.keys()) watchRoom(id);
  await sessions.select(registry.selected, { play: false }); renderRooms();
  if (openedInvite) await pair(openedInvite);
  else message(registry.rooms.size ? "Your rooms stay paired. Select a room to hear it; other available rooms stay connected and muted." : "Ready to add your first room.");
} catch (error) {
  addingRoom = true; renderRooms(); el("pair-button").disabled = !auth?.currentUser;
  message(error.message ?? "Set up Firebase and the cloud server before pairing.", true);
}
