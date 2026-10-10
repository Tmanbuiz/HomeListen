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
