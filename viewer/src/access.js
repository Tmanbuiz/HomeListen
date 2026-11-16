export function memberAccess(room, uid, now = Date.now()) {
  if (!room || room.members?.[uid] !== true) return false;
  const expiry = room.memberAccess?.[uid]?.expiresAtMs;
  return expiry == null || expiry > now;
}

export function canListen(room, uid, now = Date.now()) {
  return memberAccess(room, uid, now) && room.sharing === true &&
    now - room.lastSeenMs < 120_000 && room.audioAvailable !== false &&
    room.memberAccess?.[uid]?.role !== 'alerts';
}

export function canInviteAway(room, uid) {
  const entries = room?.memberAccess;
  if (entries != null && (typeof entries !== 'object' || Array.isArray(entries))) return false;
  const access = entries?.[uid];
  if (access != null && (typeof access !== 'object' || Array.isArray(access))) return false;
  return Boolean(uid && room?.ownerUid !== uid && room?.members?.[uid] === true &&
    Number.isSafeInteger(room.generation) &&
    (access?.role ?? 'caregiver') === 'caregiver' && access?.expiresAtMs == null);
}
