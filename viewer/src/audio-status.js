// Plain-language live-audio status for one room entry. It reports what is
// really happening, so a room that cannot be reached never just says
// "Connecting" while it retries.
export const STILL_TRYING = "Still can’t reach the home phone. Trying again…";

export function audioStatus(entry, audible) {
  if (!entry) return "";
  if (entry.problem) return entry.retry ? entry.problem + " Trying again…" : entry.problem;
  if (entry.session && entry.state !== "connected") {
    if (entry.state === "disconnected") return "Connection interrupted. Reconnecting…";
    return entry.attempts > 0 ? STILL_TRYING : "Connecting to this room…";
  }
  if (entry.state === "connected") {
    return entry.blocked || !audible ? "Connected · tap to hear this room." : "You’re listening to this room.";
  }
  return "Ready when you are.";
}

// Short state for the saved-rooms list.
export function connectionLabel(entry) {
  if (entry.state === "connected") return "Connected";
  if (entry.state === "disconnected") return "Reconnecting";
  return entry.attempts > 0 ? "Retrying" : "Connecting";
}
