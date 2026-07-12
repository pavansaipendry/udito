// End-to-end test against a running relay (wrangler dev or deployed).
//
//   DEEPGRAM_API_KEY=… node test/e2e.mjs [serverURL]
//
// Simulates the whole feature with no app and no browser: creates a session,
// joins with the code, streams a synthesized voice clip as 16 kHz PCM the way
// the guest page's Safari fallback does, and asserts transcript results reach
// the app socket. Exits 0 on success.

import { execFileSync } from "node:child_process";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const server = process.argv[2] ?? "http://127.0.0.1:8787";
const key = process.env.DEEPGRAM_API_KEY;
if (!key) {
  console.error("Set DEEPGRAM_API_KEY.");
  process.exit(2);
}
const wsBase = server.replace(/^http/, "ws");
const SPOKEN = "Hello from the desert. This is a live transcript test, one two three.";

function fail(message) {
  console.error("FAIL:", message);
  process.exit(1);
}

// 1. Synthesize speech → 16 kHz mono s16 WAV → raw PCM.
const dir = mkdtempSync(join(tmpdir(), "ears-live-"));
const wav = join(dir, "test.wav");
execFileSync("say", ["-o", wav, "--data-format=LEI16@16000", SPOKEN]);
const bytes = readFileSync(wav);
const dataIndex = bytes.indexOf(Buffer.from("data"));
if (dataIndex < 0) fail("no data chunk in synthesized WAV");
const pcm = bytes.subarray(dataIndex + 8);
console.log(`synthesized ${pcm.length} bytes of 16 kHz PCM`);

// 2. Create a session (what the Ears app does).
const created = await fetch(`${server}/sessions`, {
  method: "POST",
  body: JSON.stringify({ deepgramKey: key }),
}).then((r) => r.json());
if (!created.code || !created.appToken) fail(`create: ${JSON.stringify(created)}`);
console.log(`session created — code ${created.code}`);

// Wrong-code join must be rejected.
const badCode = created.code === "123456" ? "654321" : "123456";
const bad = await fetch(`${server}/join`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code: badCode }),
});
if (bad.ok) fail("join with a wrong code was accepted");
console.log("wrong code correctly rejected");

// 3. App socket.
const appEvents = [];
const appWS = new WebSocket(`${wsBase}/app?code=${created.code}&token=${created.appToken}&since=0`);
appWS.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping") return appWS.send(JSON.stringify({ type: "pong" }));
  appEvents.push(msg);
  if (msg.type === "result" && msg.text) {
    console.log(`  app got: ${msg.isFinal ? "[final]  " : "[interim]"} ${msg.text}`);
  }
};
await new Promise((res, rej) => {
  appWS.onopen = res;
  appWS.onerror = () => rej(fail("app socket refused"));
});
console.log("app socket connected");

// 4. Guest joins and streams the PCM at real-time pace (100 ms chunks).
const joined = await fetch(`${server}/join`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code: created.code, name: "TestGuest" }),
}).then((r) => r.json());
if (!joined.token) fail(`join: ${JSON.stringify(joined)}`);

const guestResults = [];
const guestWS = new WebSocket(
  `${wsBase}/guest?code=${created.code}&token=${joined.token}&format=pcm&rate=16000`
);
guestWS.binaryType = "arraybuffer";
guestWS.onmessage = (e) => {
  if (typeof e.data !== "string") return;
  const msg = JSON.parse(e.data);
  if (msg.type === "ping") return guestWS.send(JSON.stringify({ type: "pong" }));
  if (msg.type === "result") guestResults.push(msg);
};
await new Promise((res, rej) => {
  guestWS.onopen = res;
  guestWS.onerror = () => rej(fail("guest socket refused"));
});
console.log("guest socket connected, streaming audio…");

const CHUNK = 3200; // 100 ms of 16 kHz s16 mono
for (let offset = 0; offset < pcm.length; offset += CHUNK) {
  guestWS.send(pcm.subarray(offset, offset + CHUNK));
  await new Promise((r) => setTimeout(r, 100));
}
// Trailing silence nudges endpointing to finalize the utterance.
const silence = new Uint8Array(CHUNK);
for (let i = 0; i < 15; i++) {
  guestWS.send(silence);
  await new Promise((r) => setTimeout(r, 100));
}
await new Promise((r) => setTimeout(r, 3000));

// 5. Assert.
const finals = appEvents.filter((m) => m.type === "result" && m.isFinal && m.text);
const joinedEvent = appEvents.find((m) => m.type === "guest" && m.event === "joined");
if (!joinedEvent) fail("app never saw the guest join");
if (!finals.length) fail("no finalized transcript reached the app socket");
if (!guestResults.length) fail("guest self-view got no results");

const heard = finals.map((m) => m.text).join(" ");
console.log(`\nassembled transcript: "${heard}"`);
if (!/desert|transcript|hello/i.test(heard)) fail("transcript does not resemble the spoken text");

// 6. App reconnect replay: a fresh socket with since=0 must replay the finals.
appWS.close();
const replayed = [];
const appWS2 = new WebSocket(`${wsBase}/app?code=${created.code}&token=${created.appToken}&since=0`);
appWS2.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping") return appWS2.send(JSON.stringify({ type: "pong" }));
  if (msg.type === "result" && msg.isFinal) replayed.push(msg);
};
await new Promise((res, rej) => {
  appWS2.onopen = res;
  appWS2.onerror = () => rej(fail("app reconnect refused"));
});
await new Promise((r) => setTimeout(r, 1500));
if (replayed.length < finals.length) {
  fail(`reconnect replayed ${replayed.length} finals, expected ${finals.length}`);
}
console.log(`app reconnect replayed ${replayed.length} finals — nothing lost`);

// 7. End the session; guest must be told.
const guestEnded = new Promise((res) => {
  guestWS.addEventListener("message", (e) => {
    if (typeof e.data === "string" && JSON.parse(e.data).type === "ended") res(true);
  });
});
appWS2.send(JSON.stringify({ type: "end" }));
const gotEnded = await Promise.race([
  guestEnded,
  new Promise((r) => setTimeout(() => r(false), 4000)),
]);
if (!gotEnded) fail("guest was not notified when the host ended the session");
console.log("guest notified of session end");

// A dead code must reject rejoin.
const rejoin = await fetch(`${server}/join`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code: created.code }),
});
if (rejoin.ok) fail("ended session still accepts joins");
console.log("ended code correctly rejected");

console.log("\nPASS — full path guest→relay→Deepgram→app verified");
process.exit(0);
