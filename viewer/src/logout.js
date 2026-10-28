export async function logoutViewer({ stop, leave, clear, signOut }) {
  await stop();
  // Releasing the anonymous membership prevents abandoned browser identities
  // from using up the home's device limit. Offline logout still clears locally.
  try { await leave(); } catch { /* The owner can remove an offline device. */ }
  clear();
  await signOut();
}
