import { HttpError, randomId } from './security.js';

const RETRY_WINDOW_MS = 15 * 60_000;
// Five recipients can each wait up to ten seconds at the push provider.
const CLAIM_MS = 120_000;

function result(data, extra = {}) {
  const states = Object.values(data.recipients ?? {});
  return {
    sent: states.filter((s) => s === 'sent').length,
    registered: states.length,
    failed: states.filter((s) => s === 'pending').length,
    retryable: !data.complete,
    ...extra,
  };
}

/// A claim serializes attempts; per-recipient outcomes survive retries.
/// "sent" means accepted by a push provider, not displayed on the device.
export async function deliverAlert({ store, id, uid, room, eventId, kind, title, now, push, env, rateLimit }) {
  const path = `rooms/${id}/alertReceipts/${eventId}`;
  let receipt = await store.get(path);
  if (receipt && receipt.data.version !== 2) return { duplicate: true, sent: 0, registered: 0, retryable: false };
  if (receipt?.data.kind && receipt.data.kind !== kind) throw new HttpError(409, 'Use the original category when retrying this alert.');
  if (receipt?.data.complete) return result(receipt.data, { duplicate: true });
  if (receipt && now() - receipt.data.createdAtMs >= RETRY_WINDOW_MS) {
    return result({ ...receipt.data, complete: true }, { expired: true });
  }
  if (receipt?.data.claimUntilMs > now()) return result(receipt.data, { inProgress: true });
  if (!receipt) await rateLimit();
  const claim = randomId();
  const data = {
    ...(receipt?.data ?? { version: 2, kind, createdAtMs: now(), recipients: {}, initialized: false, attempts: 0 }),
    claim, claimUntilMs: now() + CLAIM_MS, complete: false,
    expiresAt: receipt?.data.expiresAt ?? new Date(now() + 60 * 60_000),
  };
  try { await store.put(path, data, receipt ? receipt.version : null); }
  catch (error) {
    if (error.status !== 409) throw error;
    receipt = await store.get(path);
    return result(receipt.data, { inProgress: !receipt.data.complete, duplicate: Boolean(receipt.data.complete) });
  }

  async function save(update) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const current = await store.get(path);
      if (!current || current.data.claim !== claim) throw new HttpError(409, 'An alert retry is already running.');
      const next = update(structuredClone(current.data));
      try { await store.put(path, next, current.version); return next; }
      catch (error) { if (error.status !== 409 || attempt === 4) throw error; }
    }
  }
  const payload = { id: eventId, title, room: room.roomName, roomId: id, kind, sentAt: now() };
  // Snapshot recipients once. A later join must not receive an old event.
  if (!data.initialized) {
    const recipients = {};
    for (const viewerUid of Object.keys(room.members ?? {})) {
      const access = room.memberAccess?.[viewerUid];
      if (access?.expiresAtMs != null && access.expiresAtMs <= now()) continue;
      if (await store.get(`rooms/${id}/devices/${viewerUid}`)) recipients[viewerUid] = 'pending';
    }
    await save((current) => ({ ...current, recipients, initialized: true }));
  }
  const current = await store.get(path);
  for (const [viewerUid, state] of Object.entries(current.data.recipients)) {
    if (state !== 'pending') continue;
    // Re-check membership on each attempt, including access revoked mid-flight.
    const latestRoom = await store.get(`rooms/${id}`);
    const access = latestRoom?.data.memberAccess?.[viewerUid];
    const authorized = latestRoom?.data.ownerUid === uid && latestRoom.data.sharing === true &&
      now() - latestRoom.data.lastSeenMs < 120_000 &&
      latestRoom.data.generation === room.generation && latestRoom.data.members?.[viewerUid] === true &&
      (access?.expiresAtMs == null || access.expiresAtMs > now());
    const devicePath = `rooms/${id}/devices/${viewerUid}`;
    const device = authorized ? await store.get(devicePath) : null;
    let outcome = device ? 'pending' : 'removed';
    if (device) {
      try {
        const response = await push(device.data, payload, env);
        if (response.sent) outcome = 'sent';
        else if (response.expired) {
          const removed = await store.expireDevice(id, viewerUid, device.version);
          outcome = removed ? 'expired' : 'pending';
        }
      } catch { /* A failed recipient stays pending, never "delivered". */ }
    }
    await save((entry) => ({ ...entry, recipients: { ...entry.recipients, [viewerUid]: outcome } }));
  }
  const final = await save((entry) => ({
    ...entry,
    attempts: entry.attempts + 1,
    claimUntilMs: 0,
    complete: !Object.values(entry.recipients).includes('pending') || entry.attempts >= 11,
  }));
  return result(final);
}
