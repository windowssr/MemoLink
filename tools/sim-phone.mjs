/**
 * MemoLink phone simulator (Node.js) — same LAN protocol as the Flutter app.
 * Usage:
 *   node tools/sim-phone.mjs [pairing.json] ["memo body"]
 * Default pairing file: %APPDATA%/MemoLink/pairing.json
 */
import net from "node:net";
import crypto from "node:crypto";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const defaultPairing = path.join(process.env.APPDATA || "", "MemoLink", "pairing.json");
const arg1 = process.argv[2];
const arg2 = process.argv[3];

let pairingPath = defaultPairing;
let noteBody = `Sim note ${new Date().toLocaleString()}`;

if (arg1 && arg1.trim().startsWith("{")) {
  // raw JSON string
  var payload = JSON.parse(arg1);
  if (arg2) noteBody = arg2;
} else {
  if (arg1) pairingPath = arg1;
  if (arg2) noteBody = arg2;
  if (!fs.existsSync(pairingPath)) {
    console.error("pairing file not found:", pairingPath);
    console.error("Start desktop app first, or pass a path / JSON.");
    process.exit(1);
  }
  var payload = JSON.parse(fs.readFileSync(pairingPath, "utf8"));
}

if (!payload?.lan?.host || !payload?.ticket) {
  console.error("Invalid pairing payload");
  process.exit(1);
}

console.log("pairing", payload.lan.host, payload.lan.port, payload.displayName);

// Prefer loopback when simulating on the same machine
const host =
  process.env.MEMOLINK_HOST ||
  (payload.lan.host.startsWith("127.") ? payload.lan.host : "127.0.0.1");
console.log("connecting to", host, payload.lan.port);

const deviceId = randomUUID();
const displayName = "SimPhone";
const secret = crypto.randomBytes(32).toString("base64url");
const publicKey = crypto
  .createHash("sha256")
  .update(secret)
  .digest("base64url");

function authToken(sharedSecret, id, ts) {
  return crypto
    .createHash("sha256")
    .update(`${sharedSecret}|${id}|${ts}`)
    .digest("base64url");
}

function writeFrame(socket, obj) {
  const data = Buffer.from(JSON.stringify(obj), "utf8");
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  socket.write(Buffer.concat([len, data]));
}

function readFrames(socket, onMsg) {
  let buf = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 4) {
      const len = buf.readUInt32BE(0);
      if (buf.length < 4 + len) return;
      const body = buf.subarray(4, 4 + len);
      buf = buf.subarray(4 + len);
      onMsg(JSON.parse(body.toString("utf8")));
    }
  });
}

const socket = net.connect(
  { host, port: payload.lan.port },
  () => console.log("connected"),
);

let step = "wait_hello";
let sharedSecret = null;
let sessionId = null;

readFrames(socket, (msg) => {
  console.log("<<", msg.type);
  if (step === "wait_hello" && msg.type === "hello") {
    writeFrame(socket, {
      type: "hello",
      protoVersion: 1,
      deviceId,
      displayName,
      publicKey,
      caps: ["sync.v1"],
      role: "mobile",
    });
    writeFrame(socket, {
      type: "pair_request",
      ticket: payload.ticket,
      nonce: crypto.randomBytes(16).toString("base64url"),
      ts: Date.now(),
    });
    step = "wait_pair";
    return;
  }
  if (step === "wait_pair" && msg.type === "pair_ok") {
    sharedSecret = msg.sharedSecret;
    const ts = Date.now();
    writeFrame(socket, {
      type: "auth",
      deviceId,
      token: authToken(sharedSecret, deviceId, ts),
      ts,
    });
    step = "wait_auth";
    return;
  }
  if (step === "wait_pair" && msg.type === "pair_reject") {
    console.error("pair rejected", msg.reason);
    process.exit(1);
  }
  if (step === "wait_auth" && msg.type === "auth_ok") {
    sessionId = msg.sessionId;
    step = "wait_snap";
    return;
  }
  if (step === "wait_snap" && msg.type === "sync_snapshot") {
    const now = Date.now();
    const memo = {
      id: randomUUID(),
      body: noteBody,
      color: "pink",
      pinned: true,
      done: false,
      archived: false,
      deleted: false,
      desktopX: 120,
      desktopY: 120,
      desktopW: 240,
      desktopH: 180,
      createdAt: now,
      updatedAt: now,
      revision: 1,
      originDeviceId: deviceId,
    };
    writeFrame(socket, {
      type: "sync_snapshot",
      sessionId,
      memos: [memo],
    });
    console.log("pushed memo:", memo.body);
    step = "online";
    return;
  }
  if (msg.type === "sync_caught_up") {
    console.log("sync caught up — keep alive 5s then exit");
    setTimeout(() => process.exit(0), 5000);
  }
  if (msg.type === "ping") {
    writeFrame(socket, { type: "pong", ts: Date.now(), echo: msg.ts });
  }
});

socket.on("error", (err) => {
  console.error(err);
  process.exit(1);
});
