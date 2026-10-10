import { HttpError, serviceToken } from "./security.js";

function encode(value) {
  if (value === null) return { nullValue: null };
  if (value instanceof Date) return { timestampValue: value.toISOString() };
  if (typeof value === "string") return { stringValue: value };
  if (typeof value === "boolean") return { booleanValue: value };
  if (typeof value === "number") return Number.isInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(encode) } };
  return { mapValue: { fields: fields(value) } };
}

function fields(value) {
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, encode(item)]));
}

function decode(value) {
  if ("nullValue" in value) return null;
  if ("stringValue" in value) return value.stringValue;
  if ("booleanValue" in value) return value.booleanValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return value.doubleValue;
  if ("timestampValue" in value) return new Date(value.timestampValue);
  if ("arrayValue" in value) return (value.arrayValue.values ?? []).map(decode);
  return Object.fromEntries(Object.entries(value.mapValue?.fields ?? {}).map(([key, item]) => [key, decode(item)]));
}

export class FirestoreStore {
  constructor(env) {
    this.env = env;
    this.root = "https://firestore.googleapis.com/v1/projects/" + encodeURIComponent(env.FIREBASE_PROJECT_ID) +
      "/databases/(default)/documents";
    this.name = "projects/" + env.FIREBASE_PROJECT_ID + "/databases/(default)/documents/";
  }
  async call(path, options = {}) {
    const token = await serviceToken(this.env);
    const response = await fetch(this.root + path, {
      ...options,
      headers: { authorization: "Bearer " + token, "content-type": "application/json" }
    });
    if (response.status === 404) return null;
    const body = await response.json();
    if (!response.ok) {
      const status = ["FAILED_PRECONDITION", "ALREADY_EXISTS", "ABORTED"].includes(body.error?.status)
        ? 409 : response.status === 403 ? 503 : 502;
      throw new HttpError(status, status === 409 ? "The room changed. Try again." : "Firebase could not complete this request.");
    }
    return body;
  }
  async get(path) {
    const document = await this.call("/" + path);
    return document ? {
      data: Object.fromEntries(Object.entries(document.fields ?? {}).map(([key, value]) => [key, decode(value)])),
      version: document.updateTime
    } : null;
  }
  async put(path, data, version = undefined) {
    const currentDocument = version === null ? { exists: false } : version ? { updateTime: version } : undefined;
    await this.call(":commit", {
      method: "POST",
      body: JSON.stringify({ writes: [{
        update: { name: this.name + path, fields: fields(data) },
        ...(currentDocument ? { currentDocument } : {})
      }] })
    });
  }
  async createHome(uid, id, data) {
    // A room and its owner reservation must succeed or fail together.
    await this.call(":commit", {
      method: "POST",
      body: JSON.stringify({ writes: [
        { update: { name: this.name + "owners/" + uid, fields: fields({ roomId: id }) }, currentDocument: { exists: false } },
        { update: { name: this.name + "rooms/" + id, fields: fields(data) }, currentDocument: { exists: false } }
      ] })
    });
  }
  async openSession(id, room, sid, session) {
    const activeSessions = { ...room.data.activeSessions, [session.viewerUid]: sid };
    const old = room.data.activeSessions?.[session.viewerUid];
    const previous = old ? await this.get("rooms/" + id + "/sessions/" + old) : null;
    const writes = [
      { update: { name: this.name + "rooms/" + id, fields: fields({ ...room.data, activeSessions }) },
        currentDocument: { updateTime: room.version } },
      { update: { name: this.name + "rooms/" + id + "/sessions/" + sid, fields: fields(session) },
        currentDocument: { exists: false } }
    ];
    if (previous) writes.push({
      update: { name: this.name + "rooms/" + id + "/sessions/" + old, fields: fields({ ended: true }) },
      updateMask: { fieldPaths: ["ended"] }
    });
    await this.call(":commit", { method: "POST", body: JSON.stringify({ writes }) });
  }
  async delete(path) {
    await this.call(":commit", { method: "POST", body: JSON.stringify({ writes: [{ delete: this.name + path }] }) });
  }
  async expireDevice(id, uid, version) {
    const devicePath = `rooms/${id}/devices/${uid}`;
    for (let attempt = 0; attempt < 5; attempt++) {
      const device = await this.get(devicePath);
      if (!device || device.version !== version) return false;
      const room = await this.get(`rooms/${id}`);
      if (!room) return false;
      const watchers = { ...room.data.watchers };
      delete watchers[uid];
      try {
        // Both preconditions belong to one commit: a refreshed registration
        // must survive an expired response for an older token.
        await this.call(":commit", { method: "POST", body: JSON.stringify({ writes: [
          { delete: this.name + devicePath, currentDocument: { updateTime: version } },
          { update: { name: this.name + `rooms/${id}`, fields: fields({ watchers }) },
            updateMask: { fieldPaths: ["watchers"] }, currentDocument: { updateTime: room.version } }
        ] }) });
        return true;
      } catch (error) { if (error.status !== 409 || attempt === 4) throw error; }
    }
    return false;
  }
  async expired(collectionId, now, limit = 100) {
    const result = await this.call(":runQuery", {
      method: "POST",
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId, allDescendants: true }],
          where: { fieldFilter: { field: { fieldPath: "expiresAt" }, op: "LESS_THAN_OR_EQUAL", value: encode(new Date(now)) } },
          limit
        }
      })
    });
    return result.filter((item) => item.document).map((item) => item.document.name.slice(this.name.length));
  }
  async cleanup(now) {
    const paths = [];
    for (const collection of ["candidates", "sessions", "roomInvites", "alertReceipts"]) {
      paths.push(...await this.expired(collection, now, 100));
    }
    if (paths.length) await this.call(":commit", {
      method: "POST", body: JSON.stringify({ writes: paths.map((path) => ({ delete: this.name + path })) })
    });
    return paths.length;
  }
}
