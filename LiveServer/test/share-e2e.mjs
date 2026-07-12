// End-to-end test for the live share path (no Deepgram involved):
// create share → publisher connects + snapshots → viewer joins late and
// gets the snapshot → live upserts flow → publisher sees viewer count →
// end notifies viewers and kills the token.
//
//   node test/share-e2e.mjs [serverURL]

const server = process.argv[2] ?? "http://127.0.0.1:8787";
const wsBase = server.replace(/^http/, "ws");

function fail(message) {
  console.error("FAIL:", message);
  process.exit(1);
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// 1. Create the share.
const share = await fetch(`${server}/shares`, { method: "POST" }).then((r) => r.json());
if (!share.token || !share.publishKey || !share.viewURL) fail(`create: ${JSON.stringify(share)}`);
console.log(`share created — ${share.viewURL}`);

// Viewer page must serve.
const page = await fetch(share.viewURL);
if (!page.ok || !(await page.text()).includes("Live Meeting Transcript")) {
  fail("viewer page did not serve");
}
console.log("viewer page serves");

// Bad publish key must be rejected.
const badWS = new WebSocket(`${wsBase}/publish?token=${share.token}&key=wrong`);
const badResult = await new Promise((res) => {
  badWS.onopen = () => res("opened");
  badWS.onerror = () => res("rejected");
});
if (badResult !== "rejected") fail("publish with a wrong key was accepted");
console.log("wrong publish key rejected");

// 2. Publisher connects, sends snapshot with one entry.
let viewerCount = -1;
const pub = new WebSocket(`${wsBase}/publish?token=${share.token}&key=${share.publishKey}`);
pub.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "viewers") viewerCount = msg.count;
  if (msg.type === "ping") pub.send(JSON.stringify({ type: "pong" }));
};
await new Promise((res, rej) => {
  pub.onopen = res;
  pub.onerror = () => rej(fail("publisher socket refused"));
});
const entry1 = { id: "e1", label: "You", text: "Hello everyone", isFinal: true, ts: 1 };
pub.send(JSON.stringify({ type: "snapshot", entries: [entry1] }));
await wait(300);

// 3. Late viewer joins — must receive the snapshot including entry1.
const seen = [];
const viewer = new WebSocket(`${wsBase}/watch?token=${share.token}`);
viewer.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping") return viewer.send(JSON.stringify({ type: "pong" }));
  seen.push(msg);
};
await new Promise((res, rej) => {
  viewer.onopen = res;
  viewer.onerror = () => rej(fail("viewer socket refused"));
});
await wait(400);
const snapshot = seen.find((m) => m.type === "snapshot");
if (!snapshot || snapshot.entries?.[0]?.text !== "Hello everyone") {
  fail(`late viewer did not get the snapshot: ${JSON.stringify(seen)}`);
}
console.log("late viewer received snapshot");

// 4. Live upserts reach the viewer (interim then final).
pub.send(JSON.stringify({ type: "upsert", entry: { id: "e2", label: "Them", text: "Hi", isFinal: false, ts: 2 } }));
pub.send(JSON.stringify({ type: "upsert", entry: { id: "e2", label: "Them", text: "Hi there, how are you?", isFinal: true, ts: 2 } }));
await wait(400);
const upserts = seen.filter((m) => m.type === "upsert" && m.entry.id === "e2");
if (upserts.length !== 2 || !upserts[1].entry.isFinal) {
  fail(`viewer missed live upserts: ${JSON.stringify(upserts)}`);
}
console.log("live upserts flow to the viewer");

// 5. Publisher sees the viewer count.
if (viewerCount !== 1) fail(`publisher viewer count is ${viewerCount}, expected 1`);
console.log("publisher sees 1 viewer");

// 6. End: viewer notified, token dead.
const viewerEnded = new Promise((res) => {
  viewer.addEventListener("message", (e) => {
    if (JSON.parse(e.data).type === "ended") res(true);
  });
});
pub.send(JSON.stringify({ type: "end" }));
const gotEnd = await Promise.race([viewerEnded, wait(4000).then(() => false)]);
if (!gotEnd) fail("viewer was not notified of the end");
const deadWS = new WebSocket(`${wsBase}/watch?token=${share.token}`);
const deadResult = await new Promise((res) => {
  deadWS.onopen = () => res("opened");
  deadWS.onerror = () => res("rejected");
});
if (deadResult !== "rejected") fail("ended share still accepts viewers");
console.log("end propagated; dead token rejected");

console.log("\nPASS — live share path verified");
process.exit(0);
