// Replay the pinned reference program with a fake GATT peripheral. No physical device or ASR.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const url = "https://aipixdot.com/airecord/app.js?v=key-ack-1792409573820";
const bytes = process.argv[2] ? await readFile(process.argv[2]) : await download();
async function download() {
  const response = await fetch(url);
  if (!response.ok) throw new Error("Cannot load reference demo: " + response.status);
  return Buffer.from(await response.arrayBuffer());
}
assert.equal(createHash("sha256").update(bytes).digest("hex"),
  "f46f39f3646d76aa57e0eb75dde11897695441582b717b059c75ba1ad368e6b5",
  "Review the new demo before updating the conformance baseline");
const source = bytes.toString();
const end = source.lastIndexOf("})();");
assert.ok(end > 0);
const expose = "globalThis.demo = { state, els, UUID_PROFILES, openBleSession, runSafeSmoke, parsers, buildFrameWithSeq, sendImportRequest, releaseBleSession };";
function load() {
  const context = { document: { addEventListener() {} }, TextEncoder, TextDecoder,
    setTimeout(f, ms) { if (ms === 260) queueMicrotask(f); return 1; }, clearTimeout() {} };
  vm.runInNewContext(source.slice(0, end) + expose + source.slice(end), context, { timeout: 1000 });
  return context.demo;
}
for (const profileIndex of [0, 1]) {
  const demo = load();
  const profile = demo.UUID_PROFILES[profileIndex];
  const subscribed = [], writes = [], handlers = new Map();
  const chars = new Map([profile.write, profile.notify, profile.keyNotify].map(uuid => [uuid, {
    async startNotifications() { subscribed.push(uuid); },
    addEventListener(_, callback) { handlers.set(uuid, callback); },
    removeEventListener() { handlers.delete(uuid); },
    async writeValueWithoutResponse(bytes) { writes.push(Buffer.from(bytes)); },
  }]));
  const device = { removeEventListener() {}, gatt: { disconnect() {}, async connect() {
    return { connected: true, async getPrimaryService(uuid) {
      if (uuid !== profile.service) throw Object.assign(new Error("missing service"), {name: "NotFoundError"});
      return { async getCharacteristic(id) { return chars.get(id); } };
    } };
  } } };
  const session = { device, active: true, listeners: [], writeQueue: Promise.resolve() };
  Object.assign(demo.state, { device, bleSession: session, connected: true });
  Object.assign(demo.els, { bleState: {}, fileRows: {} });
  await demo.openBleSession(session);
  assert.deepEqual(subscribed, [profile.notify, profile.keyNotify]);
  for (const [i, key] of [1, 3, 5, 7].entries()) {
    const packet = demo.buildFrameWithSeq(128+i, Uint8Array.of(3, key));
    const receive = handlers.get(i % 2 ? profile.notify : profile.keyNotify);
    for (const chunk of [packet.slice(0,5), packet.slice(5)]) {
      receive({target: {value: new DataView(chunk.buffer)}});
    }
  }
  await session.writeQueue;
  assert.deepEqual(writes.map(b => b.toString("hex")), ["5a00c1c10300030201", "5a01676b0300030401", "5a02050d0300030601", "5a030a2e0300030801"]);
  writes.length = 0;
  await demo.runSafeSmoke();
  assert.deepEqual(writes.map(b => [...b.subarray(6)]), [[0,3],[0,1],[0,10],[0,12],[3,19],[3,21],[3,23],[3,25],[2,0]]);
  writes.length = 0;
  await demo.sendImportRequest("note20260710-162938.wav", 0x01020304);
  assert.equal(writes.length, 1);
  assert.equal(writes[0].length, 36);
  assert.equal(writes[0].subarray(6,12).toString("hex"), "020204030201");
  const stale = handlers.get(profile.keyNotify);
  demo.releaseBleSession(session);
  const packet = demo.buildFrameWithSeq(0, Uint8Array.of(3,1));
  stale({target:{value:new DataView(packet.buffer)}});
  await session.writeQueue;
  assert.equal(writes.length, 1);
  console.log(profile.name + " passed: subscriptions, keys, inspection, complete file request, stale notification");
}
