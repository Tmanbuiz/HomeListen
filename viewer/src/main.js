import "./style.css";
import { initializeApp } from "firebase/app";
import { getAuth, signInAnonymously } from "firebase/auth";
import { getFirestore, doc, collection, onSnapshot, updateDoc, addDoc, Timestamp } from "firebase/firestore";
import { parsePairing } from "./pairing.js";
import { AudioSession } from "./audio-session.js";
import { createAlertRecordings } from "./alert-recordings.js";
import { memberAccess, canListen } from "./access.js";
import { clearAll, dailyCounts, exportJson, filterEvents, loadAll, roomEvents, saveEvent } from "./history.js";

const el = (id) => document.getElementById(id);
const storageKey = "homelisten-room-v2";
const audio = el("audio");
const recordingsPanel = document.createElement("section");
recordingsPanel.className = "card";
el("home-panel").after(recordingsPanel);
const recordings = createAlertRecordings(recordingsPanel);
el("connection").textContent = "Live audio · recording optional";
let auth, db, config, roomId = localStorage.getItem(storageKey);
let room, roomUnsubscribe, session, starting = false, registration, alertsEnabled = false;
let leaseTimer;
const openedInvite = location.hash.includes("pair=") ? location.href : null;
// The bearer invitation is never left in browser history or sent to a server.
if (openedInvite) history.replaceState(null, "", location.pathname + location.search);

function message(text, error = false) {
  el("message").textContent = text;
  el("message").classList.toggle("error", error);
}
function event(text) {
  const item = document.createElement("li");
  const stamp = document.createElement("time");
  stamp.textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  item.append(stamp, document.createTextNode(text));
  el("events").prepend(item);
  while (el("events").children.length > 30) el("events").lastElementChild.remove();
  el("empty-activity").hidden = true;
}
async function api(path, data = undefined, method = "POST") {
  const token = await auth.currentUser.getIdToken();
  const response = await fetch("/api" + path, {
    method, headers: { authorization: "Bearer " + token, "content-type": "application/json" },
    ...(data === undefined ? {} : { body: JSON.stringify(data) })
  });
  const result = await response.json();
  if (!response.ok) throw Object.assign(new Error(result.error ?? "Home Listen could not complete this request."), { code: result.code });
  return result;
}
function sharing() { return room?.sharing === true && Date.now() - room.lastSeenMs < 120_000; }
function renderRoom() {
  if (!room) return;
  if (!memberAccess(room, auth.currentUser.uid)) {
    revoke('Your access expired. Ask the home phone owner to renew it.');
    return;
  }
  const live = sharing();
  const audioAllowed = canListen(room, auth.currentUser.uid);
  el("room-name").textContent = room.roomName;
  el("sharing-status").textContent = !live ? "Monitoring off" :
    room.audioAvailable === false ? "Guardian on · live audio off" : "Sharing on";
  el("sharing-status").classList.toggle("live", live);
  el("listen-button").disabled = !audioAllowed || Boolean(session) || starting;
  el("stop-button").disabled = !session && !starting;
  el("battery").textContent = "Home battery: " + (live && room.battery != null
    ? room.battery + "%" + (room.charging ? " · charging" : "") : "—");
  alertsEnabled = room.watchers?.[auth.currentUser.uid] === true;
  el("alerts-button").textContent = alertsEnabled ? "Disable alerts" : "Enable alerts";
  el("alerts-status").textContent = alertsEnabled
    ? "Alerts are enabled. Sound Watch must be on at home."
    : "Get a notification when the home phone detects a selected sound.";
  if (!audioAllowed && session) void stopListening("Live listening is unavailable. Guardian alerts can remain enabled.");
}
async function watchRoom(id) {
  await stopListening();
  roomUnsubscribe?.();
  roomId = id;
  localStorage.setItem(storageKey, id);
  el("pair-panel").hidden = true; el("home-panel").hidden = false; void renderHistory();
  roomUnsubscribe = onSnapshot(doc(db, "rooms", id), (snapshot) => {
    if (!snapshot.exists()) { revoke(); return; }
    const next = snapshot.data();
    if (next.members?.[auth.currentUser.uid] !== true) { revoke(); return; }
    room = next;
    renderRoom();
    if (!roomId) return;
    message(!sharing() ? "Start monitoring on the home phone." :
      canListen(room, auth.currentUser.uid) ? "Your home phone is ready. Choose when to listen." :
      "Live audio is off for this phone. Enable alerts to receive selected sound notifications.");
  }, () => revoke());
  clearInterval(leaseTimer);
  leaseTimer = setInterval(renderRoom, 10_000);
}
function revoke(reason = "Pairing was removed or changed. Show a new code at home.") {
  void stopListening("This phone is no longer paired.");
  roomUnsubscribe?.(); roomUnsubscribe = null;
  clearInterval(leaseTimer); room = null; roomId = null;
  localStorage.removeItem(storageKey);
  el("home-panel").hidden = true; el("pair-panel").hidden = false; void renderHistory();
  message(reason, true);
}
function browserName() {
  const ua = navigator.userAgent;
  const os = /iPhone|iPad/.test(ua) ? "iPhone" : /Android/.test(ua) ? "Android" : /Windows/.test(ua) ? "Windows" : /Mac/.test(ua) ? "Mac" : "device";
  const browser = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "Browser";
  return browser + " on " + os;
}
// --- Sound alert history (on this phone only) --------------------------------
let historyAll = [];
let historyRows = [];
async function renderHistory() {
  historyAll = await loadAll();
  const panel = el("history-panel");
  panel.hidden = !roomId;
  if (!roomId) { historyRows = []; return; }
  const days = Number(el("history-days").value);
  const rows = filterEvents(roomEvents(historyAll, roomId), {
    query: el("history-search").value, kind: el("history-kind").value, days
  });
  historyRows = rows;
  const counts = dailyCounts(rows, Math.min(days, 14));
  const peak = Math.max(1, ...counts.map((c) => c.count));
  el("history-counts").replaceChildren(...counts.map((c) => {
    const bar = document.createElement("span");
    bar.style.height = Math.max(4, Math.round((c.count / peak) * 44)) + "px";
    bar.className = c.count ? "has" : "";
    bar.title = c.day + ": " + c.count + (c.count === 1 ? " alert" : " alerts");
    return bar;
  }));
  el("history-empty").hidden = rows.length > 0;
  el("history-list").replaceChildren(...rows.map((e) => {
    const item = document.createElement("li");
    const label = document.createElement("span"); label.textContent = e.title;
    const time = document.createElement("time");
    time.dateTime = new Date(e.sentAt).toISOString();
    time.textContent = new Date(e.sentAt).toLocaleString([], { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
    item.append(label, time);
    return item;
  }));
}
for (const id of ["history-search", "history-kind", "history-days"]) el(id).addEventListener("input", () => void renderHistory());
el("history-export").addEventListener("click", () => {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([exportJson(historyRows)], { type: "application/json" }));
  link.download = "home-listen-history.json";
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 5000);
});
el("history-clear").addEventListener("click", async () => {
  if (!confirm("Clear the alert history on this phone?")) return;
  await clearAll(); await renderHistory();
});
// Alerts that arrived while the app was closed are in the database already.
document.addEventListener("visibilitychange", () => { if (!document.hidden) void renderHistory(); });
void renderHistory();

async function pair(value) {
  const invite = parsePairing(value, location.origin);
  if (!invite) throw new Error("Use a Home Listen pairing link from this server.");
  await api("/rooms/" + invite.roomId + "/join", { secret: invite.secret, label: browserName() });
  el("pair-code").value = "";
  await watchRoom(invite.roomId);
  event("Paired with your home phone");
}
function signaling(id) {
  const path = (sid) => doc(db, "rooms", id, "sessions", sid);
  const candidates = (sid) => collection(path(sid), "candidates");
  return {
    watchSession: (sid, next, error) => onSnapshot(path(sid), (snapshot) => next(snapshot.data()), error),
    watchCandidates: (sid, next, error) => onSnapshot(candidates(sid), (snapshot) =>
      next(snapshot.docChanges().filter((change) => change.type === "added")
        .map((change) => ({ ...change.doc.data(), id: change.doc.id }))), error),
    addCandidate: (sid, value) => addDoc(candidates(sid), { ...value, expiresAt: Timestamp.fromDate(new Date(value.expiresAt)) }),
    setOffer: (sid, offer) => updateDoc(path(sid), { offer }),
    end: (sid) => updateDoc(path(sid), { ended: true })
  };
}
async function startListening() {
  if (!canListen(room, auth.currentUser.uid) || session || starting) return;
  starting = true; renderRoom();
  el("audio-status").textContent = "Connecting to your room…";
  const current = new AudioSession({
    api, roomId, firestore: signaling(roomId),
    onPeer: (pc) => recordings.attachPeer(pc),
    onTrack: async (stream) => {
      if (session !== current) return;
      audio.srcObject = stream;
      try { await audio.play(); el("play-button").hidden = true; }
      catch { el("play-button").hidden = false; message("Tap the play button to hear your room."); }
    },
    onState: (state) => {
      if (session !== current) return;
      document.querySelector(".sound-orb").classList.toggle("playing", state === "connected");
      el("audio-status").textContent = state === "connected" ? "You’re listening to your room." : "Connection: " + state;
      if (state === "connected") { message("Live audio · encrypted in transit · recording only for sounds you selected below"); event("Live listening connected"); }
      if (state === "disconnected") recordings.interrupted();
    },
    onError: (error) => {
      if (session === current) { message(error.message, true); void stopListening(error.message); }
    }
  });
  session = current;
  try { await current.start(); }
  catch (error) { if (session === current) { message(error.message, true); await stopListening(error.message); } }
  finally { starting = false; renderRoom(); }
}
async function stopListening(reason = "Listening stopped.") {
  recordings.stop();
  const current = session; session = null;
  audio.pause(); audio.srcObject = null;
  document.querySelector(".sound-orb").classList.remove("playing");
  el("play-button").hidden = true;
  el("audio-status").textContent = reason;
  el("listen-button").disabled = !canListen(room, auth?.currentUser?.uid); el("stop-button").disabled = true;
  await current?.stop();
}
function vapidBytes(value) {
  const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
async function toggleAlerts() {
  if (!roomId) return;
  el("alerts-button").disabled = true;
  try {
    if (alertsEnabled) {
      await api("/rooms/" + roomId + "/device", undefined, "DELETE");
      const old = await registration?.pushManager.getSubscription();
      await old?.unsubscribe();
      message("Sound alerts disabled on this phone.");
      return;
    }
    if (!registration || !("PushManager" in window)) throw new Error("This browser cannot receive alerts. On iPhone, add Home Listen to the Home Screen first.");
    if (!config.vapidPublicKey) throw new Error("The server needs its web push keys before alerts can be enabled.");
    // Permission is requested only from this button, never on page load.
    if (Notification.permission !== "granted" && await Notification.requestPermission() !== "granted") {
      throw new Error("Allow Home Listen notifications in this phone’s settings.");
    }
    const existing = await registration.pushManager.getSubscription();
    const subscription = existing ?? await registration.pushManager.subscribe({
      userVisibleOnly: true, applicationServerKey: vapidBytes(config.vapidPublicKey)
    });
    await api("/rooms/" + roomId + "/device", { kind: "webpush", subscription: subscription.toJSON() });
    message("Alerts enabled. Turn on Sound Watch at home and send a test alert.");
  } catch (error) { message(error.message, true); }
  finally { el("alerts-button").disabled = false; }
}

el("pair-form").addEventListener("submit", async (e) => {
  e.preventDefault(); el("pair-button").disabled = true;
  try { await pair(el("pair-code").value); } catch (error) { message(error.message, true); }
  finally { el("pair-button").disabled = false; }
});
el("listen-button").addEventListener("click", startListening);
el("stop-button").addEventListener("click", () => stopListening());
el("play-button").addEventListener("click", async () => {
  try { await audio.play(); el("play-button").hidden = true; }
  catch { message("Sound is blocked by this browser. Keep Home Listen open and try again.", true); }
});
el("volume").addEventListener("input", (e) => {
  // iOS can reserve volume for the phone's hardware buttons.
  audio.volume = Number(e.target.value); audio.muted = audio.volume === 0;
});
el("alerts-button").addEventListener("click", toggleAlerts);
el("forget-button").addEventListener("click", async () => {
  try { await api("/rooms/" + roomId + "/leave", {}); revoke(); message("Home phone forgotten. You can pair again with a new link."); }
  catch (error) { message(error.message, true); }
});
window.addEventListener("offline", () => { void stopListening("This phone is offline."); message("No internet connection.", true); });
window.addEventListener("pagehide", () => { void stopListening(); });
el("install-help").hidden = !(/iPhone|iPad/.test(navigator.userAgent) && !matchMedia("(display-mode: standalone)").matches);

try {
  const response = await fetch("/api/config", { cache: "no-store" });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error);
  config = result;
  const app = initializeApp(config.firebase);
  auth = getAuth(app); db = getFirestore(app);
  await auth.authStateReady();
  if (!auth.currentUser) await signInAnonymously(auth);
  if ("serviceWorker" in navigator) {
    await navigator.serviceWorker.register("/sw.js");
    registration = await navigator.serviceWorker.ready;
    navigator.serviceWorker.addEventListener("message", (e) => {
      if (e.data?.type === "sound-alert" && e.data.data?.roomId === roomId) {
        event(e.data.data.title);
        void saveEvent(e.data.data).then(renderHistory);
      }
    });
  }
  if (openedInvite) await pair(openedInvite);
  else if (roomId) await watchRoom(roomId);
  else { el("pair-panel").hidden = false; message("Ready to pair with your home phone."); }
} catch (error) {
  el("pair-panel").hidden = false;
  el("pair-button").disabled = !auth?.currentUser;
  message(error.message ?? "Set up Firebase and the cloud server before pairing.", true);
}

// The other way in: the home's secret answer plus a current authenticator code.
// It submits by itself once the answer is filled and the sixth digit is typed.
async function joinWithCode() {
  const answer = el("answer").value.trim();
  const code = el("totp-code").value.replace(/\D/g, "");
  if (!answer || code.length !== 6 || el("code-button").disabled) return;
  el("code-button").disabled = true;
  try {
    const result = await api("/join-code", { answer, code, label: browserName() });
    el("answer").value = ""; el("totp-code").value = "";
    await watchRoom(result.roomId);
    event("Paired with your home phone");
  } catch (error) { message(error.message, true); el("totp-code").select(); }
  finally { el("code-button").disabled = false; }
}
el("code-form").addEventListener("submit", (e) => { e.preventDefault(); void joinWithCode(); });
el("totp-code").addEventListener("input", () => {
  if (el("totp-code").value.replace(/\D/g, "").length !== 6) return;
  if (!el("answer").value.trim()) { message("Enter the secret answer for your home.", true); el("answer").focus(); return; }
  void joinWithCode();
});
el("answer").addEventListener("input", () => {
  if (el("totp-code").value.replace(/\D/g, "").length === 6) void joinWithCode();
});
