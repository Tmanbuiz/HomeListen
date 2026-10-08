import { before, after, beforeEach, test } from "node:test";
import { readFile } from "node:fs/promises";
import { initializeTestEnvironment, assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import { doc, collection, getDoc, getDocs, setDoc, updateDoc, Timestamp } from "firebase/firestore";
let env;
const roomId = "room", sid = "session";
const expiry = Timestamp.fromMillis(Date.now() + 60 * 60_000);
const path = "rooms/" + roomId + "/sessions/" + sid;
const db = (uid) => env.authenticatedContext(uid).firestore();
before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-homelisten",
    firestore: { rules: await readFile("firestore.rules", "utf8") }
  });
});
after(async () => { await env?.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    await setDoc(doc(admin, "rooms", roomId), {
      ownerUid: "home", members: { away: true, other: true }, watchers: {},
      activeSessions: { away: sid }, generation: 1, sharing: true
    });
    await setDoc(doc(admin, path), {
      ownerUid: "home", viewerUid: "away", generation: 1, expiresAt: expiry,
      offer: null, answer: null, ended: false
    });
    await setDoc(doc(admin, "roomInvites", roomId), { secretHash: "private" });
    await setDoc(doc(admin, "rooms", roomId, "devices", "away"), { token: "private" });
  });
});
test("unpaired and signed-out phones cannot read rooms or invitations", async () => {
  await assertFails(getDoc(doc(db("stranger"), "rooms", roomId)));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), "rooms", roomId)));
  await assertSucceeds(getDoc(doc(db("away"), "rooms", roomId)));
  for (const uid of ["home", "away", "stranger"]) {
    await assertFails(getDoc(doc(db(uid), "roomInvites", roomId)));
    await assertFails(getDoc(doc(db(uid), "rooms", roomId, "devices", "away")));
  }
});
test("client SDK cannot create rooms, self-enroll, or change sharing", async () => {
  await assertFails(setDoc(doc(db("stranger"), "rooms", "another"), { ownerUid: "stranger" }));
  await assertFails(updateDoc(doc(db("away"), "rooms", roomId), { sharing: false }));
  await assertFails(updateDoc(doc(db("home"), "rooms", roomId), { sharing: false }));
  await assertFails(updateDoc(doc(db("stranger"), "rooms", roomId), { members: { stranger: true } }));
});
test("only the two participants can read a session and write their own SDP once", async () => {
  await assertSucceeds(getDoc(doc(db("away"), path)));
  await assertFails(getDoc(doc(db("other"), path)));
  await assertFails(getDocs(collection(db("away"), "rooms", roomId, "sessions")));
  await assertSucceeds(updateDoc(doc(db("away"), path), { offer: "offer" }));
  await assertFails(updateDoc(doc(db("away"), path), { offer: "replacement" }));
  await assertFails(updateDoc(doc(db("away"), path), { answer: "forged" }));
  await assertSucceeds(updateDoc(doc(db("home"), path), { answer: "answer" }));
  await assertFails(updateDoc(doc(db("away"), path), { viewerUid: "other" }));
  await assertFails(setDoc(doc(db("away"), "rooms", roomId, "sessions", "own"), { viewerUid: "away" }));
});
test("candidate side and expiry cannot be forged", async () => {
  const candidate = { candidate: "candidate", sdpMid: "0", sdpMLineIndex: 0, side: "away", expiresAt: expiry };
  await assertSucceeds(setDoc(doc(db("away"), path, "candidates", "good"), candidate));
  await assertFails(setDoc(doc(db("away"), path, "candidates", "forged"), { ...candidate, side: "home" }));
  await assertFails(setDoc(doc(db("away"), path, "candidates", "long"), { ...candidate, expiresAt: Timestamp.fromMillis(expiry.toMillis() + 1000) }));
  await assertFails(setDoc(doc(db("other"), path, "candidates", "other"), candidate));
});
test("revocation, stopped sharing and replaced sessions block further signaling", async () => {
  for (const change of [
    { members: { other: true } }, { generation: 2 }, { sharing: false }, { activeSessions: { away: "new" } }
  ]) {
    await env.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), "rooms", roomId), {
        members: { away: true, other: true }, generation: 1, sharing: true, activeSessions: { away: sid }, ...change
      });
    });
    await assertFails(updateDoc(doc(db("away"), path), { offer: "offer" }));
  }
});
test("expired sessions cannot exchange SDP", async () => {
  await env.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), path), { expiresAt: Timestamp.fromMillis(Date.now() - 1000) });
  });
  await assertFails(updateDoc(doc(db("away"), path), { offer: "late offer" }));
});
test("ended sessions cannot be restarted or receive more candidates", async () => {
  await assertSucceeds(updateDoc(doc(db("away"), path), { ended: true }));
  await assertFails(updateDoc(doc(db("away"), path), { ended: false }));
  await assertFails(setDoc(doc(db("away"), path, "candidates", "late"),
    { candidate: "late", sdpMid: "0", sdpMLineIndex: 0, side: "away", expiresAt: expiry }));
});
