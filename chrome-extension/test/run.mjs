// End-to-end check of the ClipSource typing engine against a real Guacamole.Keyboard.
//
//   cd chrome-extension/test && npm install && node run.mjs
//
// 1. keymap: dispatch the CDP key events produced by keymap.js into the test console
//    through a Playwright CDP session and compare the keysyms Guacamole receives.
// 2. extension: load the unpacked extension, check its ID, and have the real service worker
//    type into the console via chrome.debugger (the native host is not needed for this).
//    activeTab needs a real user gesture (toolbar click, shortcut), which automation cannot
//    give, so the extension is loaded from a temp copy whose manifest adds host access to
//    127.0.0.1 and localhost. The key is unchanged, so the ID is the real one.

import { createServer } from "node:http";
import { readFile, writeFile, mkdir, mkdtemp, cp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { textToEvents } from "../keymap.js";

const here = dirname(fileURLToPath(import.meta.url));
const sourceDir = join(here, "..");
const EXPECTED_ID = "kbaaegkcchoinnblhajbhjljpkgbckom";
const GUAC_URL = "https://cdn.jsdelivr.net/npm/guacamole-common-js@1.5.0/dist/esm/guacamole-common.js";
const GUAC_FILE = join(here, "vendor", "guacamole-common.js");

const MODIFIERS = new Set([0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe7, 0xffe8, 0xffe9, 0xffea, 0xffeb, 0xffec]);
const KEYSYM_FOR = { "\n": 0xff0d, "\t": 0xff09 };

/** Keysyms Guacamole should report for a text: code point for Latin-1, Unicode keysym above. */
function expectedKeysyms(text) {
  const out = [];
  for (const ch of text.replace(/\r/g, "")) {
    if (KEYSYM_FOR[ch]) out.push(KEYSYM_FOR[ch]);
    else {
      const cp = ch.codePointAt(0);
      out.push(cp <= 0xff ? cp : 0x01000000 | cp);
    }
  }
  return out;
}

const hex = (list) => list.map((k) => "0x" + k.toString(16).toUpperCase()).join(" ");

async function ensureGuacamole() {
  if (existsSync(GUAC_FILE)) return;
  const res = await fetch(GUAC_URL);
  if (!res.ok) throw new Error(`cannot download ${GUAC_URL}: ${res.status}`);
  await mkdir(dirname(GUAC_FILE), { recursive: true });
  await writeFile(GUAC_FILE, await res.text());
}

function startServer() {
  const files = {
    "/guacamole/index.html": [join(here, "index.html"), "text/html"],
    "/guacamole/guacamole-common.js": [GUAC_FILE, "text/javascript"],
  };
  const server = createServer(async (req, res) => {
    const entry = files[new URL(req.url, "http://x").pathname];
    if (!entry) return res.writeHead(404).end();
    res.writeHead(200, { "content-type": entry[1] }).end(await readFile(entry[0]));
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

let failures = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}`);
  if (!ok) console.log(`  expected ${hex(expected)}\n  actual   ${hex(actual)}`);
  else console.log(`  ${hex(actual)}`);
}

async function openConsole(page, url) {
  await page.goto(url);
  await page.waitForFunction(() => window.guacReady === true);
  await page.focus(".display");
}

const printable = (keysyms) => keysyms.filter((k) => !MODIFIERS.has(k));

const TEXT = "echo hi\tthere\nlína 2";
const PUNCT = "Echo \"A|b\" ~/x_1 && ls -la; (cd /tmp) <in >out {k=v} 100% @home #tag $HOME ^C *'?`!+[]\\,.";

await ensureGuacamole();
const server = await startServer();
const url = `http://127.0.0.1:${server.address().port}/guacamole/index.html`;
const extensionDir = await mkdtemp(join(tmpdir(), "clipsource-ext-"));
await cp(sourceDir, extensionDir, { recursive: true, filter: (src) => !src.startsWith(here) });
const manifest = JSON.parse(await readFile(join(extensionDir, "manifest.json"), "utf8"));
manifest.host_permissions = ["http://127.0.0.1/*", "http://localhost/*"];
await writeFile(join(extensionDir, "manifest.json"), JSON.stringify(manifest, null, 2));
let context;
try {
  // Chromium (not Chrome) with the new headless mode loads unpacked extensions.
  context = await chromium.launchPersistentContext("", {
    channel: "chromium",
    headless: true,
    args: [`--disable-extensions-except=${extensionDir}`, `--load-extension=${extensionDir}`],
  });

  // --- 1. keymap through a CDP session ---
  const page = await context.newPage();
  for (const [name, text] of [["keymap: echo/tab/enter/í", TEXT], ["keymap: shifted punctuation", PUNCT]]) {
    await openConsole(page, url);
    const cdp = await context.newCDPSession(page);
    for (const ev of textToEvents(text)) {
      await cdp.send("Input.dispatchKeyEvent", ev.down);
      await cdp.send("Input.dispatchKeyEvent", ev.up);
    }
    await cdp.detach();
    check(name, printable(await page.evaluate(() => window.keysyms)), expectedKeysyms(text));
  }

  // --- 2. the extension's own typing engine ---
  let [worker] = context.serviceWorkers();
  worker = worker || (await context.waitForEvent("serviceworker"));
  const id = new URL(worker.url()).host;
  const idOk = id === EXPECTED_ID;
  if (!idOk) failures += 1;
  console.log(`${idOk ? "PASS" : "FAIL"} extension ID is stable\n  ${id}`);

  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${id}/popup.html`);
  const host = new URL(url).host;

  /** Ask the service worker to type `text` into the tab showing `tabUrl`; resolves with the
   *  start response and, for a started run, the final "done" broadcast. Optional `stopAfter`
   *  ms sends a stop from the popup. */
  const typeVia = (tabUrl, text, { stopAfter } = {}) => popup.evaluate(async ({ tabUrl, text, stopAfter }) => {
    const tab = (await chrome.tabs.query({})).find((t) => t.url === tabUrl);
    const done = new Promise((resolve) => {
      const listener = (msg) => {
        if (msg.event !== "done") return;
        chrome.runtime.onMessage.removeListener(listener);
        resolve(msg);
      };
      chrome.runtime.onMessage.addListener(listener);
    });
    const started = await chrome.runtime.sendMessage({ cmd: "type", tabId: tab.id, text });
    if (started.ok && stopAfter) setTimeout(() => chrome.runtime.sendMessage({ cmd: "stop" }), stopAfter);
    return { started, done: started.ok ? await done : null };
  }, { tabUrl, text, stopAfter });
  const setSync = (values) => popup.evaluate((v) => chrome.storage.sync.set(v), values);
  const pass = (name, ok, detail = "") => {
    if (!ok) failures += 1;
    console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `\n  ${detail}` : ""}`);
  };

  // Consent: a /guacamole/ path only suggests the host; typing is refused until it is allowed.
  await openConsole(page, url);
  const before = await typeVia(url, "x");
  pass("console path alone does not allow the host", before.started.ok === false && /not allowed/.test(before.started.error),
    JSON.stringify(before.started));
  check("  nothing typed before consent", await page.evaluate(() => window.keysyms), []);
  await setSync({ sites: [host] });

  await page.bringToFront();
  const result = await typeVia(url, TEXT);
  console.log(`  start: ${JSON.stringify(result.started)}  done: ${JSON.stringify(result.done)}`);
  check("extension types via chrome.debugger after consent", printable(await page.evaluate(() => window.keysyms)), expectedKeysyms(TEXT));

  // Stop: a slow run stopped from the popup ends early.
  await setSync({ charDelay: 40 });
  await openConsole(page, url);
  const stop = (await typeVia(url, "x".repeat(200), { stopAfter: 400 })).done;
  pass("stop ends the run early", stop.stopped && stop.done > 0 && stop.done < stop.total,
    `${stop.done} of ${stop.total}, reason: ${stop.reason}`);

  // Navigation: when the console page is replaced mid-run, typing stops and nothing reaches the new page.
  await openConsole(page, url);
  const lines = Array.from({ length: 20 }, (_, i) => `echo secret-line-${i}`).join("\n");
  const navRun = typeVia(url, lines);
  await new Promise((r) => setTimeout(r, 500));
  const next = url + "?login=sso";
  await page.goto(next);
  await page.waitForFunction(() => window.guacReady === true);
  const nav = (await navRun).done;
  await new Promise((r) => setTimeout(r, 500));
  const afterNav = await page.evaluate(() => window.keysyms);
  pass("navigation mid-typing stops the run", nav?.stopped === true && nav.reason === "the page navigated" && nav.done < nav.total,
    `${nav?.done} of ${nav?.total}, reason: ${nav?.reason}`);
  check("  nothing typed into the new page", afterNav, []);

  // Concurrency: a second run while one is active is refused.
  await openConsole(page, url);
  const concurrent = await popup.evaluate(async (tabUrl) => {
    const tab = (await chrome.tabs.query({})).find((t) => t.url === tabUrl);
    const done = new Promise((resolve) => {
      chrome.runtime.onMessage.addListener((msg) => { if (msg.event === "done") resolve(msg); });
    });
    const [a, b] = await Promise.all([
      chrome.runtime.sendMessage({ cmd: "type", tabId: tab.id, text: "a".repeat(100) }),
      chrome.runtime.sendMessage({ cmd: "type", tabId: tab.id, text: "b".repeat(100) }),
    ]);
    await chrome.runtime.sendMessage({ cmd: "stop" });
    await done;
    return [a, b];
  }, url);
  const oks = concurrent.filter((r) => r.ok).length;
  const busy = concurrent.filter((r) => !r.ok && /Already typing/.test(r.error)).length;
  const typed = new Set(printable(await page.evaluate(() => window.keysyms)));
  pass("concurrent runs are rejected", oks === 1 && busy === 1 && typed.size <= 1,
    `${JSON.stringify(concurrent)}; distinct keysyms typed: ${hex([...typed])}`);
  await popup.evaluate(() => chrome.storage.sync.remove("charDelay"));

  // Site gate: another host is refused even with a console path, while only 127.0.0.1 is allowed.
  const otherUrl = url.replace("127.0.0.1", "localhost");
  const otherPage = await context.newPage();
  await openConsole(otherPage, otherUrl);
  const gate = (await typeVia(otherUrl, "x")).started;
  pass("site gate refuses a host that was not allowed", gate.ok === false && /not allowed/.test(gate.error), JSON.stringify(gate));
  await otherPage.close();

  // Popup without the native host shows the install command with this extension's ID.
  await popup.reload();
  await popup.waitForSelector("#hostMissing:not([hidden])", { timeout: 5000 }).catch(() => {});
  const install = await popup.textContent("#installCmd");
  pass("popup shows install command", install === `clipsrc native-host --install ${EXPECTED_ID}`, install);
} finally {
  await context?.close();
  server.close();
  await rm(extensionDir, { recursive: true, force: true });
}

console.log(failures ? `\n${failures} check(s) failed` : "\nAll checks passed");
process.exit(failures ? 1 : 0);
