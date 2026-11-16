// One live session: pairs the Ears app with one remote guest by code,
// pipes the guest's audio into a Deepgram nova-3 live socket, and fans
// transcript results out to the app (and back to the guest for self-view).
// The guest can also type chat messages (plain text or code) that go one
// way: guest → app only.
//
// Built to survive bad connections on every leg:
// - Guest audio is raw linear16 PCM — resumable at any byte, so audio
//   arriving while Deepgram is down is buffered and flushed on reconnect.
// - Final results AND chat messages share one sequence counter; the app
//   replays anything it missed on reconnect via ?since=<seq>.
// - KeepAlive frames every 5 s hold the Deepgram socket through silence.
//
// Session metadata (including the Deepgram key) lives in DO storage only so
// an engine restart mid-session recovers; everything is wiped on end and by
// the TTL alarm (10 min unused code, 24 h hard cap).

const WAITING_TTL_MS = 10 * 60 * 1000;
const LIVE_TTL_MS = 24 * 60 * 60 * 1000;
const AUDIO_BUFFER_CAP = 1 << 20; // ~1 MB of guest audio while Deepgram is down
const FINALS_CAP = 500; // replay ring for app reconnects
const CHATS_CAP = 200; // replay ring for guest chat messages
const CHAT_TEXT_CAP = 32000; // per message — enough for a hefty code paste
const DG_MAX_BACKOFF_MS = 8000;

export class LiveSession {
  constructor(state, env) {
    this.state = state;
    this.storage = state.storage;
    this.meta = null; // {code, appToken, guestToken, guestName, deepgramKey, phase, createdAt, seq}
    this.appWS = null;
    this.guestWS = null;
    this.dg = null;
    this.dgOpen = false;
    this.dgBackoff = 500;
    this.dgConnecting = false;
    this.guestRate = 16000;
    this.audioBuffer = []; // [ArrayBuffer] while Deepgram is down (PCM only)
    this.audioBuffered = 0;
    this.finals = []; // [{seq, text, speechFinal}]
    this.chats = []; // [{type:"chat", seq, kind, lang, text, name, at}]
    this.keepAliveTimer = null;
    this.pingTimer = null;
    // Live-share state (a DO instance is either a code session or a share,
    // never both — they live in different id namespaces).
    this.shareMeta = null; // {publishKey, createdAt, ended}
    this.publisherWS = null;
    this.viewerWS = new Set();
    this.shareEntries = new Map(); // entry id -> entry (memory only; the
    // publisher re-sends a full snapshot on every reconnect)
    this.shareOrder = [];
    this.state.blockConcurrencyWhile(async () => {
      this.meta = (await this.storage.get("meta")) ?? null;
      this.shareMeta = (await this.storage.get("shareMeta")) ?? null;
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/init":
        return this.handleInit(request);
      case "/join":
        return this.handleJoin(request);
      case "/app":
        return this.handleAppSocket(request, url);
      case "/guest":
        return this.handleGuestSocket(request, url);
      case "/ratelimit":
        return this.handleRateLimit(request);
      case "/share-init":
        return this.handleShareInit(request);
      case "/publish":
        return this.handlePublishSocket(request, url);
      case "/watch":
        return this.handleWatchSocket(request, url);
      default:
        return json({ error: "Not found." }, 404);
    }
  }

  // MARK: - Session lifecycle

  async handleInit(request) {
    const body = await request.json();
    if (this.meta && this.meta.phase !== "ended") {
      const age = Date.now() - this.meta.createdAt;
      const stale =
        (this.meta.phase === "waiting" && age > WAITING_TTL_MS) || age > LIVE_TTL_MS;
      if (!stale) return json({ error: "busy" }, 409);
      await this.wipe("expired");
    }
    this.meta = {
      code: body.code,
      appToken: body.appToken,
      guestToken: null,
      guestName: null,
      deepgramKey: body.deepgramKey,
      phase: "waiting",
      createdAt: Date.now(),
      seq: 0,
    };
    this.finals = [];
    await this.storage.put("meta", this.meta);
    await this.storage.setAlarm(Date.now() + WAITING_TTL_MS);
    return json({ ok: true });
  }

  async handleJoin(request) {
    const body = await request.json();
    if (!this.meta || this.meta.phase === "ended") {
      return json({ error: "That code isn't active. Ask for a fresh one." }, 404);
    }
    if (this.guestWS) {
      return json({ error: "Someone is already connected with this code." }, 409);
    }
    this.meta.guestToken = randomToken();
    this.meta.guestName = String(body.name ?? "").trim() || "Guest";
    await this.storage.put("meta", this.meta);
    await this.storage.setAlarm(this.meta.createdAt + LIVE_TTL_MS);
    return json({ token: this.meta.guestToken, name: this.meta.guestName });
  }

  async wipe(reason) {
    const notice = JSON.stringify({ type: "ended", reason });
    for (const ws of [this.appWS, this.guestWS]) {
      try {
        ws?.send(notice);
        ws?.close(1000, "session ended");
      } catch {}
    }
    this.appWS = null;
    this.guestWS = null;
    this.closeDeepgram();
    this.stopTimers();
    this.finals = [];
    this.chats = [];
    this.audioBuffer = [];
    this.audioBuffered = 0;
    if (this.meta) this.meta.phase = "ended";
    await this.storage.deleteAll(); // also clears the alarm
  }

  async alarm() {
    if (this.shareMeta && !this.shareMeta.ended) {
      if (Date.now() - this.shareMeta.createdAt >= LIVE_TTL_MS) {
        await this.wipeShare("expired");
      }
      return;
    }
    if (!this.meta || this.meta.phase === "ended") return;
    const age = Date.now() - this.meta.createdAt;
    if (this.meta.phase === "waiting" && age >= WAITING_TTL_MS) {
      await this.wipe("expired");
    } else if (age >= LIVE_TTL_MS) {
      await this.wipe("expired");
    }
  }

  // MARK: - Rate limiting (one "limiter:global" instance serves all IPs)

  /// Sliding-window per-key counter, memory-only — a DO restart forgiving
  /// the counts is fine; this exists to stop code brute-forcing and
  /// drive-by session spam, not to bill anyone.
  async handleRateLimit(request) {
    const { key, limit, windowMs } = await request.json();
    const now = Date.now();
    this.rateBuckets ??= new Map();
    const fresh = (this.rateBuckets.get(key) ?? []).filter((t) => now - t < windowMs);
    if (fresh.length >= limit) {
      this.rateBuckets.set(key, fresh);
      return json({ ok: false }, 429);
    }
    fresh.push(now);
    this.rateBuckets.set(key, fresh);
    if (this.rateBuckets.size > 10000) this.rateBuckets.clear(); // churn cap
    return json({ ok: true });
  }

  // MARK: - Live share (host transcript → browser viewers)

  async handleShareInit(request) {
    const body = await request.json();
    this.shareMeta = { publishKey: body.publishKey, createdAt: Date.now(), ended: false };
    this.shareEntries = new Map();
    this.shareOrder = [];
    await this.storage.put("shareMeta", this.shareMeta);
    await this.storage.setAlarm(Date.now() + LIVE_TTL_MS);
    return json({ ok: true });
  }

  handlePublishSocket(request, url) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return json({ error: "Expected a WebSocket." }, 426);
    }
    if (!this.shareMeta || this.shareMeta.ended) {
      return json({ error: "Share is not active." }, 404);
    }
    if (url.searchParams.get("key") !== this.shareMeta.publishKey) {
      return json({ error: "Bad key." }, 403);
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    try {
      this.publisherWS?.close(1000, "replaced by a newer connection");
    } catch {}
    this.publisherWS = server;

    server.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      const msg = safeParse(event.data);
      if (!msg) return;
      switch (msg.type) {
        case "snapshot":
          this.shareEntries = new Map();
          this.shareOrder = [];
          for (const entry of msg.entries ?? []) this.shareUpsert(entry, false);
          this.broadcastViewers(JSON.stringify({
            type: "snapshot",
            entries: this.shareOrder.map((id) => this.shareEntries.get(id)),
          }));
          break;
        case "upsert":
          if (msg.entry?.id) {
            this.shareUpsert(msg.entry, false);
            this.broadcastViewers(JSON.stringify({ type: "upsert", entry: msg.entry }));
          }
          break;
        case "clear":
          this.shareEntries = new Map();
          this.shareOrder = [];
          this.broadcastViewers(JSON.stringify({ type: "snapshot", entries: [] }));
          break;
        case "end":
          this.state.waitUntil(this.wipeShare("host"));
          break;
      }
    });
    const drop = () => {
      if (this.publisherWS === server) this.publisherWS = null;
    };
    server.addEventListener("close", drop);
    server.addEventListener("error", drop);

    server.send(JSON.stringify({ type: "viewers", count: this.viewerWS.size }));
    this.startTimers();
    return new Response(null, { status: 101, webSocket: client });
  }

  handleWatchSocket(request, url) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return json({ error: "Expected a WebSocket." }, 426);
    }
    if (!this.shareMeta || this.shareMeta.ended) {
      return json({ error: "Share is not active." }, 404);
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    this.viewerWS.add(server);

    const drop = () => {
      if (!this.viewerWS.delete(server)) return;
      this.notifyViewerCount();
    };
    server.addEventListener("close", drop);
    server.addEventListener("error", drop);
    server.addEventListener("message", () => {}); // viewers only pong

    server.send(JSON.stringify({
      type: "snapshot",
      entries: this.shareOrder.map((id) => this.shareEntries.get(id)),
      live: this.publisherWS != null,
    }));
    this.notifyViewerCount();
    this.startTimers();
    return new Response(null, { status: 101, webSocket: client });
  }

  shareUpsert(entry) {
    if (!this.shareEntries.has(entry.id)) this.shareOrder.push(entry.id);
    this.shareEntries.set(entry.id, entry);
  }

  broadcastViewers(text) {
    for (const ws of this.viewerWS) {
      try {
        ws.send(text);
      } catch {}
    }
  }

  notifyViewerCount() {
    try {
      this.publisherWS?.send(JSON.stringify({ type: "viewers", count: this.viewerWS.size }));
    } catch {}
  }

  async wipeShare(reason) {
    const notice = JSON.stringify({ type: "ended", reason });
    for (const ws of [this.publisherWS, ...this.viewerWS]) {
      try {
        ws?.send(notice);
        ws?.close(1000, "share ended");
      } catch {}
    }
    this.publisherWS = null;
    this.viewerWS = new Set();
    this.shareEntries = new Map();
    this.shareOrder = [];
    if (this.shareMeta) this.shareMeta.ended = true;
    await this.storage.deleteAll();
  }

  // MARK: - App socket

  handleAppSocket(request, url) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return json({ error: "Expected a WebSocket." }, 426);
    }
    if (!this.meta || this.meta.phase === "ended") {
      return json({ error: "Session is not active." }, 404);
    }
    if (url.searchParams.get("token") !== this.meta.appToken) {
      return json({ error: "Bad token." }, 403);
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    try {
      this.appWS?.close(1000, "replaced by a newer connection");
    } catch {}
    this.appWS = server;

    server.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      const msg = safeParse(event.data);
      if (msg?.type === "end") this.state.waitUntil(this.wipe("host"));
    });
    const drop = () => {
      if (this.appWS === server) this.appWS = null;
    };
    server.addEventListener("close", drop);
    server.addEventListener("error", drop);

    this.sendApp({
      type: "status",
      state: this.meta.phase,
      guest: this.guestName(),
      guestConnected: this.guestWS != null,
      seq: this.meta.seq,
    });
    // Replay finals and chat messages the app missed while its socket was
    // down — both share one seq counter, so merge back into arrival order.
    const since = Number(url.searchParams.get("since") ?? NaN);
    if (Number.isFinite(since)) {
      const replay = [
        ...this.finals
          .filter((final) => final.seq > since)
          .map((final) => ({
            type: "result",
            seq: final.seq,
            text: final.text,
            isFinal: true,
            speechFinal: final.speechFinal,
          })),
        ...this.chats.filter((chat) => chat.seq > since),
      ].sort((a, b) => a.seq - b.seq);
      for (const event of replay) this.sendApp(event);
    }
    this.startTimers();
    return new Response(null, { status: 101, webSocket: client });
  }

  // MARK: - Guest socket

  handleGuestSocket(request, url) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return json({ error: "Expected a WebSocket." }, 426);
    }
    if (!this.meta || this.meta.phase === "ended") {
      return json({ error: "Session is not active." }, 404);
    }
    if (
      !this.meta.guestToken ||
      url.searchParams.get("token") !== this.meta.guestToken
    ) {
      return json({ error: "Bad token." }, 403);
    }

    // Guests always send raw linear16 PCM — resumable at any byte, so
    // buffering and Deepgram reconnects are always safe (a containerized
    // format would only parse from its first bytes).
    const rate = clampRate(Number(url.searchParams.get("rate")));
    if (this.dg && rate !== this.guestRate) this.closeDeepgram();
    this.guestRate = rate;

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    try {
      this.guestWS?.close(1000, "replaced by a newer connection");
    } catch {}
    this.guestWS = server;

    if (this.meta.phase === "waiting") {
      this.meta.phase = "live";
      this.state.waitUntil(this.storage.put("meta", this.meta));
    }

    server.addEventListener("message", (event) => {
      if (typeof event.data === "string") {
        const msg = safeParse(event.data);
        if (msg?.type === "level") {
          this.sendApp({ type: "level", value: Number(msg.value) || 0 });
        } else if (msg?.type === "chat") {
          this.handleGuestChat(msg);
        }
        return;
      }
      this.ingestAudio(event.data);
    });
    const drop = () => {
      if (this.guestWS !== server) return;
      this.guestWS = null;
      this.sendApp({ type: "guest", event: "left", name: this.guestName() });
    };
    server.addEventListener("close", drop);
    server.addEventListener("error", drop);

    this.sendApp({ type: "guest", event: "joined", name: this.guestName() });
    console.log(`[${this.meta.code}] guest connected (${this.guestRate} Hz)`);

    this.state.waitUntil(this.ensureDeepgram());
    this.startTimers();
    return new Response(null, { status: 101, webSocket: client });
  }

  ingestAudio(data) {
    if (this.dgOpen && this.dg) {
      try {
        this.dg.send(data);
        return;
      } catch {}
    }
    // Deepgram is down — buffer for the flush on reconnect.
    this.audioBuffer.push(data);
    this.audioBuffered += data.byteLength ?? 0;
    while (this.audioBuffered > AUDIO_BUFFER_CAP && this.audioBuffer.length) {
      this.audioBuffered -= this.audioBuffer[0].byteLength ?? 0;
      this.audioBuffer.shift();
    }
  }

  /// Guest → app chat. One-way: nothing the host types ever reaches the
  /// guest. Messages get seq numbers from the same counter as finals so a
  /// reconnecting app replays them in order; the guest gets an ack so their
  /// bubble can flip from "sending" to "sent".
  handleGuestChat(msg) {
    if (!this.meta || this.meta.phase === "ended") return;
    const text = String(msg.text ?? "").replace(/\r\n/g, "\n");
    if (!text.trim()) return;
    this.meta.seq += 1;
    const event = {
      type: "chat",
      seq: this.meta.seq,
      kind: msg.kind === "code" ? "code" : "text",
      lang: typeof msg.lang === "string" ? msg.lang.slice(0, 24) : null,
      text: text.slice(0, CHAT_TEXT_CAP),
      name: this.guestName(),
      at: Date.now(),
    };
    this.chats.push(event);
    if (this.chats.length > CHATS_CAP) this.chats.shift();
    this.state.waitUntil(this.storage.put("meta", this.meta));
    this.sendApp(event);
    if (msg.id != null) {
      try {
        this.guestWS?.send(JSON.stringify({ type: "chatAck", id: String(msg.id).slice(0, 64) }));
      } catch {}
    }
  }

  // MARK: - Deepgram

  async ensureDeepgram() {
    if (this.dg || this.dgConnecting) return;
    if (!this.meta || this.meta.phase !== "live") return;
    this.dgConnecting = true;
    try {
      const url = new URL("https://api.deepgram.com/v1/listen");
      url.searchParams.set("model", "nova-3");
      url.searchParams.set("interim_results", "true");
      url.searchParams.set("smart_format", "true");
      // smart_format alone holds words back while it waits for context
      // (e.g. to format numerals); no_delay forces results out immediately
      // at a small formatting cost — right trade for a live view.
      url.searchParams.set("no_delay", "true");
      url.searchParams.set("endpointing", "300");
      url.searchParams.set("encoding", "linear16");
      url.searchParams.set("sample_rate", String(this.guestRate));
      url.searchParams.set("channels", "1");
      const response = await fetch(url, {
        headers: {
          Upgrade: "websocket",
          Authorization: `Token ${this.meta.deepgramKey}`,
        },
      });
      const ws = response.webSocket;
      if (!ws) throw new Error(`Deepgram refused the socket (HTTP ${response.status})`);
      ws.accept();
      this.dg = ws;
      this.dgOpen = true;
      this.dgBackoff = 500;

      ws.addEventListener("message", (event) => {
        if (typeof event.data === "string") this.handleDeepgram(event.data);
      });
      const gone = () => {
        if (this.dg !== ws) return;
        console.log(`[${this.meta?.code}] Deepgram socket closed — will retry`);
        this.dg = null;
        this.dgOpen = false;
        this.scheduleDeepgramRetry();
      };
      ws.addEventListener("close", gone);
      ws.addEventListener("error", gone);

      // Raw PCM is resumable at any byte — flush everything captured while
      // the transcriber was down.
      for (const chunk of this.audioBuffer) {
        try {
          ws.send(chunk);
        } catch {}
      }
      this.audioBuffer = [];
      this.audioBuffered = 0;
      console.log(`[${this.meta.code}] Deepgram connected (${this.guestRate} Hz)`);
    } catch (error) {
      console.log(`[${this.meta?.code}] Deepgram connect failed: ${error.message}`);
      this.sendApp({ type: "warning", message: `Transcriber connection failed: ${error.message}` });
      this.scheduleDeepgramRetry();
    } finally {
      this.dgConnecting = false;
    }
  }

  scheduleDeepgramRetry() {
    if (!this.meta || this.meta.phase !== "live") return;
    const delay = this.dgBackoff;
    this.dgBackoff = Math.min(this.dgBackoff * 2, DG_MAX_BACKOFF_MS);
    setTimeout(() => this.state.waitUntil(this.ensureDeepgram()), delay);
  }

  closeDeepgram() {
    const ws = this.dg;
    this.dg = null;
    this.dgOpen = false;
    if (!ws) return;
    try {
      ws.send(JSON.stringify({ type: "CloseStream" }));
    } catch {}
    try {
      ws.close(1000, "session ended");
    } catch {}
  }

  handleDeepgram(text) {
    const response = safeParse(text);
    if (response?.type !== "Results") return;
    const transcript = response.channel?.alternatives?.[0]?.transcript ?? "";
    const isFinal = response.is_final ?? false;
    const speechFinal = response.speech_final ?? false;
    if (!transcript && !speechFinal) return;

    this.meta.seq += 1;
    const event = {
      type: "result",
      seq: this.meta.seq,
      text: transcript,
      isFinal,
      speechFinal,
    };
    if (isFinal) {
      this.finals.push({ seq: event.seq, text: transcript, speechFinal });
      if (this.finals.length > FINALS_CAP) this.finals.shift();
      this.state.waitUntil(this.storage.put("meta", this.meta));
    }
    this.sendApp(event);
    try {
      this.guestWS?.send(JSON.stringify(event));
    } catch {}
  }

  // MARK: - Plumbing

  sendApp(obj) {
    try {
      this.appWS?.send(JSON.stringify(obj));
    } catch {}
  }

  startTimers() {
    if (this.keepAliveTimer) return;
    // Holds the Deepgram socket open through silences (same trick the app
    // itself uses) and keeps NATs on both client legs warm.
    this.keepAliveTimer = setInterval(() => {
      if (this.dgOpen) {
        try {
          this.dg?.send(JSON.stringify({ type: "KeepAlive" }));
        } catch {}
      }
    }, 5000);
    this.pingTimer = setInterval(() => {
      const ping = JSON.stringify({ type: "ping" });
      for (const ws of [this.appWS, this.guestWS, this.publisherWS, ...this.viewerWS]) {
        try {
          ws?.send(ping);
        } catch {}
      }
      if (!this.appWS && !this.guestWS && !this.dg
          && !this.publisherWS && this.viewerWS.size === 0) {
        this.stopTimers();
      }
    }, 20000);
  }

  stopTimers() {
    if (this.keepAliveTimer) clearInterval(this.keepAliveTimer);
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.keepAliveTimer = null;
    this.pingTimer = null;
  }

  guestName() {
    return this.meta?.guestName ?? null;
  }
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function clampRate(rate) {
  return Number.isFinite(rate) && rate >= 8000 && rate <= 48000 ? Math.round(rate) : 16000;
}

function safeParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
