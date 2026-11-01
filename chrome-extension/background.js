// ClipSource service worker: reads history from the native host and types an entry into
// the active tab as real key events through the Chrome debugger protocol.

import { isAllowedUrl, isSuggestedUrl, needsConfirm, textToEvents, MAX_CHARS } from "./keymap.js";
import { getSettings, nativeRequest } from "./settings.js";

const MENU_LATEST = "clipsource-type-latest";
const MENU_PICK = "clipsource-type-pick";

/** The typing run in progress, or null. */
let session = null;

// ---------- typing engine ----------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function broadcast(message) {
  chrome.runtime.sendMessage(message).catch(() => {}); // no popup open: ignore
}

function setBadge(tabId, text, color = "#FF8A4C") {
  chrome.action.setBadgeBackgroundColor({ color }).catch(() => {});
  chrome.action.setBadgeText({ text, ...(tabId ? { tabId } : {}) }).catch(() => {});
}

function status() {
  return session
    ? { typing: true, tabId: session.tabId, done: session.done, total: session.total }
    : { typing: false };
}

async function focusConsole(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        const el = document.querySelector(".guac-display, .display, canvas");
        if (el && typeof el.focus === "function") el.focus();
      },
    });
  } catch {
    // No scripting access to this page (e.g. activeTab not granted): typing still works.
  }
}

/** Why the current run must stop, or null to keep going. */
async function lineCheck(run) {
  let tab;
  try {
    tab = await chrome.tabs.get(run.tabId);
  } catch {
    return "the tab was closed";
  }
  if (tab.url !== run.url) return "the page navigated";
  const { sites } = await getSettings();
  if (!isAllowedUrl(tab.url, sites)) return "typing is no longer allowed on this site";
  return null;
}

function stopRun(run, reason) {
  if (!run.stop) run.reason = reason;
  run.stop = true;
}

async function typeText(tabId, text, onStarted = () => {}) {
  // Claim the session before the first await so two runs can never interleave.
  if (session) throw new Error("Already typing. Stop the current run first.");
  const run = { tabId, url: null, stop: false, reason: null, detached: false, attached: false,
    mainFrameId: null, done: 0, total: 0 };
  session = run;
  const target = { tabId };
  let started = false;
  let error = null;
  try {
    if ([...text].length > MAX_CHARS) throw new Error(`Entry is longer than ${MAX_CHARS} characters; not typed.`);
    const tab = await chrome.tabs.get(tabId);
    const settings = await getSettings();
    // tab.url is only visible after a user gesture on the tab (popup, shortcut, menu): activeTab.
    if (!tab.url) throw new Error("ClipSource has no access to this tab. Open the popup or use the shortcut on it.");
    if (!isAllowedUrl(tab.url, settings.sites)) throw new Error("Typing is not allowed on this site yet.");
    run.url = tab.url;

    const events = textToEvents(text);
    run.total = events.length;
    await focusConsole(tabId);
    if (run.stop) throw new Error(`Not typed: ${run.reason}.`);
    try {
      await chrome.debugger.attach(target, "1.3");
    } catch (e) {
      throw new Error(`Cannot attach to the tab: ${e.message || e}`);
    }
    run.attached = true;
    // Watch main-frame navigation from the protocol too: it fires before tabs.onUpdated.
    await chrome.debugger.sendCommand(target, "Page.enable");
    const { frameTree } = await chrome.debugger.sendCommand(target, "Page.getFrameTree");
    run.mainFrameId = frameTree.frame.id;
    if (frameTree.frame.url !== run.url) stopRun(run, "the page navigated");
    if (run.stop) throw new Error(`Not typed: ${run.reason}.`);

    started = true;
    onStarted();
    let lastPct = -1;
    let lineStart = true;
    for (const ev of events) {
      if (lineStart && !run.stop) {
        const reason = await lineCheck(run);
        if (reason) stopRun(run, reason);
      }
      if (run.stop) break;
      await chrome.debugger.sendCommand(target, "Input.dispatchKeyEvent", ev.down);
      await chrome.debugger.sendCommand(target, "Input.dispatchKeyEvent", ev.up);
      run.done += 1;
      lineStart = ev.enter;
      const pct = Math.floor((run.done / run.total) * 100);
      if (pct !== lastPct) {
        lastPct = pct;
        setBadge(tabId, `${pct}%`);
        broadcast({ event: "progress", ...status() });
      }
      const delay = ev.enter ? settings.enterDelay : settings.charDelay;
      if (delay > 0) await sleep(delay);
    }
  } catch (e) {
    if (!run.detached || !started) error = e.message || String(e);
  } finally {
    if (run.attached && !run.detached) await chrome.debugger.detach(target).catch(() => {});
    if (session === run) session = null;
    if (started) {
      setBadge(tabId, "");
      broadcast({ event: "done", done: run.done, total: run.total, stopped: run.stop, reason: run.reason, error });
    }
  }
  if (error) throw new Error(error);
  return { done: run.done, total: run.total, stopped: run.stop, reason: run.reason };
}

function stopTyping() {
  if (session) stopRun(session, "stopped by you");
}

// The user closed the "started debugging" bar, or the tab went away: treat as stop.
chrome.debugger.onDetach.addListener((source) => {
  if (session && source.tabId === session.tabId) {
    session.detached = true;
    stopRun(session, "the debugger was detached");
  }
});

// Any navigation of the tab being typed into stops the run at once, so the rest of the text
// (maybe secrets) never reaches a login or other page that replaced the console.
chrome.debugger.onEvent.addListener((source, method, params) => {
  const run = session;
  if (!run || source.tabId !== run.tabId) return;
  const frameId = params?.frame?.id ?? params?.frameId;
  const mainFrame = method === "Page.frameNavigated" ? !params.frame.parentId : frameId === run.mainFrameId;
  if (mainFrame && ["Page.frameStartedLoading", "Page.frameNavigated", "Page.navigatedWithinDocument",
    "Page.frameRequestedNavigation"].includes(method)) {
    stopRun(run, "the page navigated");
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (session && tabId === session.tabId && session.url && (changeInfo.url || changeInfo.status)) {
    stopRun(session, "the page navigated");
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (session && tabId === session.tabId) stopRun(session, "the tab was closed");
});

// ---------- entry points ----------

/** Type now, or hand over to the popup for consent to the host or confirmation of the text. */
async function typeOrConfirm(tab, entry) {
  const settings = await getSettings();
  if (!isAllowedUrl(tab.url || "", settings.sites)) {
    // A console path only suggests the host: ask in the popup, never type straight away.
    if (isSuggestedUrl(tab.url || "")) return openPopupWith({ mode: "consent", tabId: tab.id, entry });
    setBadge(tab.id, "off", "#8A8F9E");
    setTimeout(() => setBadge(tab.id, ""), 2000);
    return;
  }
  if (needsConfirm(entry.text, settings.confirmChars)) {
    await openPopupWith({ mode: "confirm", tabId: tab.id, entry });
    return;
  }
  typeText(tab.id, entry.text).catch((e) => showError(tab.id, e));
}

/** Open the popup with a pending request (consent to the host, confirm an entry, or pick one). */
async function openPopupWith(pending) {
  await chrome.storage.session.set({ pending: { ...pending, at: Date.now() } });
  try {
    await chrome.action.openPopup();
  } catch {
    // openPopup unavailable or no user gesture: leave a marker for the next popup open.
    setBadge(pending.tabId, "!");
  }
}

function showError(tabId, e) {
  console.warn("ClipSource:", e);
  chrome.storage.session.set({ lastError: { message: e.message || String(e), at: Date.now() } });
  setBadge(tabId, "err", "#C2400D");
  setTimeout(() => setBadge(tabId, ""), 4000);
}

async function typeLatest(tab) {
  if (session) return stopTyping(); // pressing the shortcut again stops the run
  if (!tab?.id) return;
  try {
    const { entry } = await nativeRequest({ op: "latest" });
    await typeOrConfirm(tab, entry);
  } catch (e) {
    showError(tab.id, e);
  }
}

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (command !== "type-latest") return;
  tab = tab || (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  await typeLatest(tab);
});

// ---------- context menus ----------

async function rebuildMenus() {
  const { sites } = await getSettings();
  const patterns = ["*://*/xtam/*", "*://*/*/xtam/*", "*://*/guacamole/*", "*://*/*/guacamole/*",
    ...sites.map((h) => `*://${h.split(":")[0]}/*`)];
  await chrome.contextMenus.removeAll();
  const base = { contexts: ["page", "frame", "editable", "selection"], documentUrlPatterns: patterns };
  chrome.contextMenus.create({ ...base, id: MENU_LATEST, title: "Type latest ClipSource entry" });
  chrome.contextMenus.create({ ...base, id: MENU_PICK, title: "Type from ClipSource…" });
}

chrome.runtime.onInstalled.addListener(rebuildMenus);
chrome.runtime.onStartup.addListener(rebuildMenus);
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "sync" && changes.sites) rebuildMenus();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === MENU_LATEST) await typeLatest(tab);
  if (info.menuItemId === MENU_PICK && tab?.id) await openPopupWith({ mode: "pick", tabId: tab.id });
});

// ---------- popup messages ----------

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.cmd === "status") {
    sendResponse(status());
  } else if (msg?.cmd === "stop") {
    stopTyping();
    sendResponse({ ok: true });
  } else if (msg?.cmd === "type") {
    // Respond once the run has started (or failed to start); progress and the result
    // of a started run arrive as broadcasts.
    let started = false;
    typeText(msg.tabId, String(msg.text ?? ""), () => {
      started = true;
      sendResponse({ ok: true, ...status() });
    }).catch((e) => {
      if (!started) sendResponse({ ok: false, error: e.message || String(e) });
    });
    return true;
  }
  return false;
});
