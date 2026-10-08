// One receive-only peer. This module never calls getUserMedia.
export class AudioSession {
  constructor({ api, roomId, firestore, rtc = (config) => new RTCPeerConnection(config),
    onTrack, onState, onError, now = () => Date.now() }) {
    Object.assign(this, { api, roomId, firestore, rtc, onTrack, onState, onError, now });
    this.closed = false;
    this.unsubscribers = [];
    this.candidates = [];
    this.seenCandidates = new Set();
    this.applyingAnswer = false;
  }
  async start() {
    const session = await this.api("/rooms/" + this.roomId + "/sessions", {});
    this.session = session;
    if (this.closed) { await this.endRemote(); return; }
    const ice = await this.api("/rooms/" + this.roomId + "/ice", {});
    if (this.closed) { await this.endRemote(); return; }
    const pc = this.pc = this.rtc({ iceServers: ice.iceServers });
    const fail = (error) => { if (!this.closed) this.onError(error); };
    pc.ontrack = (event) => {
      if (!this.closed) this.onTrack(event.streams[0] ?? new MediaStream([event.track]));
    };
    pc.onconnectionstatechange = () => {
      if (this.closed) return;
      this.onState(pc.connectionState);
      if (pc.connectionState === "failed") fail(new Error("Audio connection lost. Tap Listen live to reconnect."));
    };
    pc.onicecandidate = (event) => {
      if (this.closed || !event.candidate) return;
      const item = event.candidate.toJSON();
      this.firestore.addCandidate(session.sessionId, {
        candidate: item.candidate, sdpMid: item.sdpMid ?? null,
        sdpMLineIndex: item.sdpMLineIndex ?? null, side: "away",
        expiresAt: session.expiresAt
      }).catch(fail);
    };
    pc.addTransceiver("audio", { direction: "recvonly" });
    this.unsubscribers.push(this.firestore.watchSession(session.sessionId, async (data) => {
      if (this.closed || !data) return;
      if (data.ended) { fail(new Error("The home phone ended this connection.")); return; }
      if (!data.answer || pc.remoteDescription || this.applyingAnswer) return;
      this.applyingAnswer = true;
      try {
        await pc.setRemoteDescription({ type: "answer", sdp: data.answer });
        if (this.closed) return;
        for (const candidate of this.candidates.splice(0)) await pc.addIceCandidate(candidate);
      } catch (error) { fail(error); }
      finally { this.applyingAnswer = false; }
    }, fail));
    this.unsubscribers.push(this.firestore.watchCandidates(session.sessionId, (items) => {
      for (const item of items) {
        if (this.closed || item.side !== "home" || this.seenCandidates.has(item.id)) continue;
        this.seenCandidates.add(item.id);
        const candidate = {
          candidate: item.candidate, sdpMid: item.sdpMid, sdpMLineIndex: item.sdpMLineIndex
        };
        if (pc.remoteDescription) pc.addIceCandidate(candidate).catch(fail);
        else this.candidates.push(candidate);
      }
    }, fail));
    const offer = await pc.createOffer();
    if (this.closed) return;
    await pc.setLocalDescription(offer);
    if (this.closed) return;
    await this.firestore.setOffer(session.sessionId, offer.sdp);
    if (this.closed) return;
    this.timeout = setTimeout(() => fail(new Error("The home phone did not connect. Check sharing and the relay setup.")), 35_000);
    const originalState = pc.onconnectionstatechange;
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "connected") clearTimeout(this.timeout);
      originalState();
    };
    this.expiry = setTimeout(() => fail(new Error("This listening session expired. Tap Listen live to start another.")),
      Math.max(0, Date.parse(session.expiresAt) - this.now()));
    this.refresh = setInterval(async () => {
      try {
        const next = await this.api("/rooms/" + this.roomId + "/ice", {});
        if (!this.closed) pc.setConfiguration({ ...pc.getConfiguration(), iceServers: next.iceServers });
      } catch (error) { fail(error); }
    }, 25 * 60_000);
  }
  async endRemote() {
    if (!this.session || this.ended) return;
    this.ended = true;
    await this.firestore.end(this.session.sessionId).catch(() => {});
  }
  async stop() {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.timeout); clearTimeout(this.expiry); clearInterval(this.refresh);
    for (const unsubscribe of this.unsubscribers.splice(0)) unsubscribe();
    if (this.pc) {
      this.pc.ontrack = this.pc.onicecandidate = this.pc.onconnectionstatechange = null;
      this.pc.close();
    }
    await this.endRemote();
  }
}
