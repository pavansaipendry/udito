# Ears Live Transcript relay

Pairs the Ears app with one remote person by a 6-digit code, transcribes their
mic through Deepgram nova-3, and streams the results into the app's Live
Transcript window. One-way: nothing on the Mac is captured.

```
guest browser ──opus/pcm──▶ Durable Object ──audio──▶ Deepgram nova-3
                                   │◀──────results──────┘
Ears app     ◀──JSON results───────┘
```

- One Durable Object per session, addressed by the code. Wiped on end,
  10-minute TTL for unused codes, 24-hour hard cap.
- The Deepgram key is sent by the app at session creation and lives only in
  the session's storage until the session ends — no secrets deployed here.
- Finals carry sequence numbers; the app replays missed ones on reconnect.
- Guest page (`src/guest.html`) is served from `/`: 16 kHz linear16 PCM via
  AudioWorklet on every browser (raw PCM is resumable at any byte — no
  container-header fragility), with a ~20 s offline buffer so dropouts delay
  words instead of losing them. Debug a live deployment with
  `npx wrangler tail ears-live`.

## Deploy (one time)

```sh
cd LiveServer
npx wrangler login     # opens the browser for Cloudflare OAuth (free account works)
npx wrangler deploy
```

`deploy` prints the public URL, e.g. `https://ears-live.<account>.workers.dev`.
Paste it into Ears → Settings → "Live Transcript relay URL". Done — that URL
is also the page guests open.

## Develop / test

```sh
npx wrangler dev --local --port 8787
DEEPGRAM_API_KEY=… node test/e2e.mjs            # full path incl. real Deepgram
node test/e2e.mjs https://ears-live.<you>.workers.dev   # against production
```

The e2e test synthesizes speech with `say`, streams it like a guest, and
asserts the transcript reaches the app socket, reconnect replay included.
