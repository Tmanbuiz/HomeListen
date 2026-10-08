export function parsePairing(value, expectedOrigin) {
  try {
    const url = new URL(value.trim());
    if (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname))) return null;
    if (url.username || url.password || url.origin !== expectedOrigin) return null;
    const code = new URLSearchParams(url.hash.slice(1)).get("pair");
    const match = /^([A-Za-z0-9_-]{16,128})\.([A-Za-z0-9_-]{43})$/.exec(code ?? "");
    return match ? { roomId: match[1], secret: match[2] } : null;
  } catch { return null; }
}
