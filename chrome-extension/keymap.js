// Text -> CDP Input.dispatchKeyEvent parameters, US keyboard layout.
// Pure module: used by the service worker and by test/run.mjs.

export const SHIFT = 8;
export const MAX_CHARS = 20000;

// Unshifted character -> [code, windowsVirtualKeyCode]
const BASE = {
  " ": ["Space", 32],
  "-": ["Minus", 189], "=": ["Equal", 187], "[": ["BracketLeft", 219], "]": ["BracketRight", 221],
  "\\": ["Backslash", 220], ";": ["Semicolon", 186], "'": ["Quote", 222], ",": ["Comma", 188],
  ".": ["Period", 190], "/": ["Slash", 191], "`": ["Backquote", 192],
};
// Shifted character -> the unshifted character on the same key
const SHIFTED = {
  "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
  "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
};

function baseKey(ch) {
  if (ch >= "a" && ch <= "z") return [`Key${ch.toUpperCase()}`, ch.toUpperCase().charCodeAt(0)];
  if (ch >= "0" && ch <= "9") return [`Digit${ch}`, ch.charCodeAt(0)];
  return BASE[ch] || null;
}

/** keyDown/keyUp parameters for one character, or null for characters that are dropped ("\r"). */
export function keyEventsFor(ch) {
  if (ch === "\r") return null;
  if (ch === "\n") {
    const k = { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 };
    return { down: { type: "keyDown", ...k, text: "\r", unmodifiedText: "\r" }, up: { type: "keyUp", ...k }, enter: true };
  }
  if (ch === "\t") {
    const k = { key: "Tab", code: "Tab", windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 };
    return { down: { type: "rawKeyDown", ...k }, up: { type: "keyUp", ...k }, enter: false };
  }
  let modifiers = 0;
  let unshifted = ch;
  if (ch >= "A" && ch <= "Z") {
    modifiers = SHIFT;
    unshifted = ch.toLowerCase();
  } else if (SHIFTED[ch]) {
    modifiers = SHIFT;
    unshifted = SHIFTED[ch];
  }
  const mapped = baseKey(unshifted);
  if (!mapped) {
    // Other Unicode: no physical key on a US layout; key + text only.
    return {
      down: { type: "keyDown", key: ch, text: ch, unmodifiedText: ch },
      up: { type: "keyUp", key: ch },
      enter: false,
    };
  }
  const [code, vk] = mapped;
  const k = { key: ch, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers };
  return { down: { type: "keyDown", ...k, text: ch, unmodifiedText: unshifted }, up: { type: "keyUp", ...k }, enter: false };
}

/** Event pairs for a whole text, iterating by code point. "\r\n" becomes one Enter. */
export function textToEvents(text) {
  const out = [];
  for (const ch of text) {
    const ev = keyEventsFor(ch);
    if (ev) out.push(ev);
  }
  return out;
}

export function lineCount(text) {
  return text.replace(/\r\n?/g, "\n").replace(/\n+$/, "").split("\n").length;
}

/** Multi-line or long text must be confirmed in the popup before typing. */
export function needsConfirm(text, confirmChars = 500) {
  return lineCount(text) > 1 || [...text].length > confirmChars;
}

function httpUrl(url) {
  try {
    const u = new URL(url);
    return /^https?:$/.test(u.protocol) ? u : null;
  } catch {
    return null;
  }
}

/** Host (with port) of an http(s) URL in lower case, or null. */
export function hostOf(url) {
  return httpUrl(url)?.host.toLowerCase() || null;
}

/** Typing is allowed only on hosts the user consented to (the sites list). */
export function isAllowedUrl(url, sites = []) {
  const host = hostOf(url);
  return !!host && sites.map((s) => String(s).toLowerCase()).includes(host);
}

/** Guacamole / XTAM console paths are only suggested: the popup asks before allowing the host. */
export function isSuggestedUrl(url) {
  const path = httpUrl(url)?.pathname.toLowerCase() || "";
  return path.includes("/xtam/") || path.includes("/guacamole/");
}
