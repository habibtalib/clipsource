// End-to-end sync crypto for the web viewer. WebCrypto only; mirrors Sources/ClipCore/Sync/SyncCrypto.swift.
// Tests/ClipCoreTests/Fixtures/sync-vector.json pins both sides (`node site/app/crypto.test.mjs`).

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();

export const DEFAULT_ITERATIONS = 600000;
/** Accepted PBKDF2 rounds in a server-provided key record: too few weakens the key, too many hangs the tab. */
export const MIN_ITERATIONS = 100000;
export const MAX_ITERATIONS = 10000000;

export function iterationsInRange(n) {
  return Number.isInteger(n) && n >= MIN_ITERATIONS && n <= MAX_ITERATIONS;
}
export const CHECK_PLAINTEXT = "clipsource-sync-check-v1";
const HKDF_SALT = enc.encode("clipsource");

export function b64encode(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function b64decode(b64) {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

async function hkdf(ikm, info, usage) {
  const bits = await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: HKDF_SALT, info: enc.encode(info) }, ikm, 256);
  return usage === "enc"
    ? subtle.importKey("raw", bits, { name: "AES-GCM" }, false, ["encrypt", "decrypt"])
    : subtle.importKey("raw", bits, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

/** Keys from the 32-byte PBKDF2 master (raw bytes or base64), e.g. one kept in sessionStorage. */
export async function keysFromMaster(master) {
  const bytes = typeof master === "string" ? b64decode(master) : master;
  const ikm = await subtle.importKey("raw", bytes, "HKDF", false, ["deriveBits"]);
  return {
    master: b64encode(bytes),
    encKey: await hkdf(ikm, "clipsource-enc-v1", "enc"),
    macKey: await hkdf(ikm, "clipsource-mac-v1", "mac"),
  };
}

/** PBKDF2-SHA256(NFC passphrase, salt) -> master, then HKDF split. `master` is base64. */
export async function deriveKey(passphrase, saltB64, iterations = DEFAULT_ITERATIONS) {
  const pw = await subtle.importKey("raw", enc.encode(passphrase.normalize("NFC")), "PBKDF2", false, ["deriveBits"]);
  const bits = await subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: b64decode(saltB64), iterations }, pw, 256);
  return keysFromMaster(new Uint8Array(bits));
}

/** Server-side dedup key: hex HMAC-SHA256 of the text. */
export async function hashText(keys, text) {
  const mac = new Uint8Array(await subtle.sign("HMAC", keys.macKey, enc.encode(text)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** AES-GCM, base64 of nonce (12) + ciphertext + tag (16). `nonce` is for test vectors only. */
export async function seal(keys, plaintext, nonce) {
  const iv = nonce ?? globalThis.crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv }, keys.encKey, plaintext));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv);
  out.set(ct, 12);
  return b64encode(out);
}

export async function open(keys, b64) {
  const data = b64decode(b64);
  if (data.length < 28) throw new Error("Cannot decrypt synced entry");
  const plain = await subtle.decrypt({ name: "AES-GCM", iv: data.subarray(0, 12) }, keys.encKey, data.subarray(12));
  return new Uint8Array(plain);
}

/** JSON matching Swift's JSONEncoder [.sortedKeys, .withoutEscapingSlashes]: sorted keys, nil fields omitted. */
export function canonicalJSON(value) {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value === null || typeof value !== "object") return value;
  const out = {};
  for (const k of Object.keys(value).sort()) {
    if (value[k] !== null && value[k] !== undefined) out[k] = sortKeys(value[k]);
  }
  return out;
}

export async function sealPayload(keys, obj, nonce) {
  return seal(keys, enc.encode(canonicalJSON(obj)), nonce);
}

export async function openPayload(keys, b64) {
  return JSON.parse(dec.decode(await open(keys, b64)));
}

/** True when `check` (from sync_keys.check_value) decrypts to the known plaintext. */
export async function verifyCheck(keys, check) {
  try {
    return dec.decode(await open(keys, check)) === CHECK_PLAINTEXT;
  } catch {
    return false;
  }
}
