// Checks site/app/sync-crypto.js against the Swift-produced vector. Run: node site/app/crypto.test.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { deriveKey, hashText, openPayload, sealPayload, verifyCheck, canonicalJSON, b64decode } from "./sync-crypto.js";

const vectorURL = new URL("../../Tests/ClipCoreTests/Fixtures/sync-vector.json", import.meta.url);
const v = JSON.parse(readFileSync(fileURLToPath(vectorURL), "utf8"));

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || !detail ? "" : `\n     ${detail}`}`);
  if (!ok) failed++;
}

const keys = await deriveKey(v.passphrase, v.salt, v.iterations);
check("master", keys.master === v.master, `got ${keys.master}`);

const hash = await hashText(keys, v.text);
check("hash", hash === v.hash, `got ${hash}`);

const opened = await openPayload(keys, v.payload);
check("open == payloadJSON", canonicalJSON(opened) === v.payloadJSON, `got ${canonicalJSON(opened)}`);

const sealed = await sealPayload(keys, opened, b64decode(v.nonce));
check("seal with nonce reproduces payload", sealed === v.payload, `got ${sealed}`);

// Same object with keys out of order and a null field still seals identically.
const shuffled = { v: 1, text: opened.text, deviceName: opened.deviceName, source: { ...opened.source, session: null },
  origin: opened.origin, createdAt: opened.createdAt, deviceId: opened.deviceId, extra: undefined };
check("seal is key-order and null independent", (await sealPayload(keys, shuffled, b64decode(v.nonce))) === v.payload);

check("check verifies", await verifyCheck(keys, v.check));

const wrong = await deriveKey(v.passphrase + "x", v.salt, v.iterations);
check("wrong passphrase rejected by check", !(await verifyCheck(wrong, v.check)));
let rejected = false;
try { await openPayload(wrong, v.payload); } catch { rejected = true; }
check("wrong passphrase cannot open payload", rejected);

// NFC: decomposed input derives the same key as precomposed.
const nfc = await deriveKey("café", v.salt, 10);
const nfd = await deriveKey("café", v.salt, 10);
check("passphrase NFC-normalised", nfc.master === nfd.master);

if (failed) {
  console.error(`${failed} check(s) failed`);
  process.exit(1);
}
console.log("all checks passed");
