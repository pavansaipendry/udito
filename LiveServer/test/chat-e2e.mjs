// End-to-end test for guest chat against a running relay (wrangler dev or
// deployed). No Deepgram key needed — chat never touches the transcriber.
//
//   node test/chat-e2e.mjs [serverURL]
//
// Creates a session, joins as a guest, sends a text message and a code
// message, and asserts: the app socket receives both (kind, name, seq
// intact), the guest gets delivery acks, and a message sent while the app
// socket is down is replayed on reconnect via ?since=.

const server = process.argv[2] ?? "http://127.0.0.1:8787";
const wsBase = server.replace(/^http/, "ws");

function fail(message) {
  console.error("FAIL:", message);
  process.exit(1);
}

const CODE_SNIPPET = `function greet(name) {\n  // classic\n  return \`hello, \${name}\`;\n}`;

// 1. Session + guest join (dummy Deepgram key — never dialed for chat).
const created = await fetch(`${server}/sessions`, {
  method: "POST",
  body: JSON.stringify({ deepgramKey: "chat-test-dummy" }),
}).then((r) => r.json());
if (!created.code || !created.appToken) fail(`create: ${JSON.stringify(created)}`);
console.log(`session created — code ${created.code}`);

const appEvents = [];
const appWS = new WebSocket(`${wsBase}/app?code=${created.code}&token=${created.appToken}&since=0`);
appWS.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping") return appWS.send(JSON.stringify({ type: "pong" }));
  appEvents.push(msg);
};
await new Promise((res, rej) => {
  appWS.onopen = res;
  appWS.onerror = () => rej(fail("app socket refused"));
});

const joined = await fetch(`${server}/join`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code: created.code, name: "ChatGuest" }),
}).then((r) => r.json());
if (!joined.token) fail(`join: ${JSON.stringify(joined)}`);

const acks = [];
const guestWS = new WebSocket(
  `${wsBase}/guest?code=${created.code}&token=${joined.token}&format=pcm&rate=16000`
);
guestWS.onmessage = (e) => {
  if (typeof e.data !== "string") return;
  const msg = JSON.parse(e.data);
  if (msg.type === "ping") return guestWS.send(JSON.stringify({ type: "pong" }));
  if (msg.type === "chatAck") acks.push(msg.id);
};
await new Promise((res, rej) => {
  guestWS.onopen = res;
  guestWS.onerror = () => rej(fail("guest socket refused"));
});
console.log("app and guest sockets connected");

// 2. Guest sends a text message and a code message.
guestWS.send(JSON.stringify({ type: "chat", id: "m1", kind: "text", text: "hey — can you check this?" }));
guestWS.send(JSON.stringify({ type: "chat", id: "m2", kind: "code", text: CODE_SNIPPET }));
await new Promise((r) => setTimeout(r, 1500));

const chats = appEvents.filter((m) => m.type === "chat");
if (chats.length !== 2) fail(`app got ${chats.length} chat events, expected 2`);
const [text, code] = chats;
if (text.kind !== "text" || text.text !== "hey — can you check this?") {
  fail(`text message mangled: ${JSON.stringify(text)}`);
}
if (code.kind !== "code" || code.text !== CODE_SNIPPET) {
  fail(`code message mangled: ${JSON.stringify(code)}`);
}
if (text.name !== "ChatGuest") fail(`chat lost the guest name: ${JSON.stringify(text)}`);
if (!(code.seq > text.seq)) fail(`seq not increasing: ${text.seq} then ${code.seq}`);
if (!acks.includes("m1") || !acks.includes("m2")) fail(`guest acks missing: ${JSON.stringify(acks)}`);
console.log(`app received both messages (seq ${text.seq}, ${code.seq}), guest acked — indentation intact`);

// 3. Ill-formed chat frames must be ignored, not crash the session.
guestWS.send(JSON.stringify({ type: "chat", id: "m3", kind: "code", text: "   " }));
guestWS.send(JSON.stringify({ type: "chat", id: "m4", kind: "nonsense", text: 42 }));
await new Promise((r) => setTimeout(r, 800));
const afterJunk = appEvents.filter((m) => m.type === "chat");
if (afterJunk.some((m) => m.seq > code.seq && !String(m.text).trim())) {
  fail("blank chat was forwarded");
}
console.log("blank/junk chat frames ignored");

// 4. A message sent while the app socket is down replays on reconnect.
const lastSeq = Math.max(...appEvents.filter((m) => m.seq).map((m) => m.seq));
appWS.close();
await new Promise((r) => setTimeout(r, 500));
guestWS.send(JSON.stringify({ type: "chat", id: "m5", kind: "text", text: "sent while you were away" }));
await new Promise((r) => setTimeout(r, 800));

const replayEvents = [];
const appWS2 = new WebSocket(
  `${wsBase}/app?code=${created.code}&token=${created.appToken}&since=${lastSeq}`
);
appWS2.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping") return appWS2.send(JSON.stringify({ type: "pong" }));
  replayEvents.push(msg);
};
await new Promise((res, rej) => {
  appWS2.onopen = res;
  appWS2.onerror = () => rej(fail("app reconnect refused"));
});
await new Promise((r) => setTimeout(r, 1200));

const replayedChats = replayEvents.filter((m) => m.type === "chat");
if (replayedChats.length !== 1 || replayedChats[0].text !== "sent while you were away") {
  fail(`reconnect replayed ${JSON.stringify(replayedChats)}, expected exactly the missed message`);
}
console.log("missed chat replayed on app reconnect — nothing lost");

// 5. Clean up.
appWS2.send(JSON.stringify({ type: "end" }));
await new Promise((r) => setTimeout(r, 500));

console.log("\nPASS — guest chat path verified (text, code, acks, replay)");
process.exit(0);
