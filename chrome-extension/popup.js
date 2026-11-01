import { hostOf, isAllowedUrl, isSuggestedUrl, lineCount, needsConfirm, MAX_CHARS } from "./keymap.js";
import { getSettings, isHostMissing, nativeRequest, setSiteEnabled } from "./settings.js";
import { avatarColor, cleanWindowTitle, initial, shortAge } from "./format.js";

const $ = (id) => document.getElementById(id);
const PREVIEW_LINES = 12;

const state = {
  tab: null,
  settings: null,
  enabled: false,
  entries: [],
  selected: 0,
  confirming: null,
  afterConsent: null, // entry to continue with once the host is allowed
};

// ---------- views ----------

function show(view) {
  for (const id of ["pickView", "consentView", "confirmView", "typingView"]) $(id).hidden = id !== view;
  if (view === "pickView") $("search").focus();
}

function message(text, isError = false) {
  const el = $("message");
  el.textContent = text;
  el.classList.toggle("error", isError);
  el.hidden = !text;
}

function renderList() {
  const list = $("list");
  list.replaceChildren();
  $("empty").hidden = state.entries.length > 0;
  state.entries.forEach((entry, i) => list.append(renderRow(entry, i)));
  updateSelection(false);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text; // untrusted text only ever goes through textContent
  return node;
}

function renderRow(entry, index) {
  const source = entry.source || {};
  const app = source.app || (entry.origin === "cli" ? "clipsrc" : entry.origin === "mcp" ? "MCP" : "Unknown");
  const row = el("li", "row");
  row.setAttribute("role", "option");
  row.dataset.index = String(index);

  const avatar = el("div", "avatar", initial(app));
  avatar.style.background = avatarColor(app);

  const body = el("div", "body");
  const meta = el("div", "meta");
  meta.append(el("span", "app", app));
  if (source.label) meta.append(el("span", "chip label", source.label));
  if (entry.device) meta.append(el("span", "chip", entry.device));
  meta.append(el("span", "age", shortAge(new Date(entry.createdAt))));
  if (index < 9) meta.append(el("span", "num", String(index + 1)));
  body.append(meta);
  body.append(el("div", "text", entry.text.length > 400 ? entry.text.slice(0, 400) : entry.text));
  const windowTitle = entry.windowClean || cleanWindowTitle(source.windowTitle, source.app);
  if (windowTitle) body.append(el("div", "window", windowTitle));

  row.append(avatar, body);
  row.addEventListener("mousemove", () => {
    if (state.selected !== index) {
      state.selected = index;
      updateSelection(false);
    }
  });
  row.addEventListener("click", () => choose(entry));
  return row;
}

function updateSelection(scroll = true) {
  const rows = $("list").children;
  for (const row of rows) row.setAttribute("aria-selected", String(Number(row.dataset.index) === state.selected));
  if (scroll) rows[state.selected]?.scrollIntoView({ block: "nearest" });
}

// ---------- history ----------

let searchTimer = null;
let searchSeq = 0;

async function load(query = "") {
  const seq = ++searchSeq;
  try {
    const { entries } = await nativeRequest({ op: "recent", limit: 50, query });
    if (seq !== searchSeq) return;
    $("hostMissing").hidden = true;
    state.entries = entries || [];
    state.selected = 0;
    renderList();
  } catch (e) {
    if (seq !== searchSeq) return;
    if (isHostMissing(e)) {
      $("installCmd").textContent = `clipsrc native-host --install ${chrome.runtime.id}`;
      $("hostError").textContent = e.message;
      $("hostMissing").hidden = false;
      $("pickView").hidden = true;
    } else {
      message(e.message, true);
    }
  }
}

// ---------- typing ----------

function choose(entry) {
  message("");
  if (!state.enabled) {
    if (hostOf(state.tab?.url)) showConsent(entry);
    else message("Typing is not available on this page.", true);
    return;
  }
  if ([...entry.text].length > MAX_CHARS) {
    message(`This entry is longer than ${MAX_CHARS} characters and cannot be typed.`, true);
    return;
  }
  if (needsConfirm(entry.text, state.settings.confirmChars)) showConfirm(entry);
  else startTyping(entry.text);
}

/** Ask before allowing typing on this host; continue with `entry` (if any) after Allow. */
function showConsent(entry = null) {
  const host = hostOf(state.tab?.url);
  state.afterConsent = entry;
  $("consentTitle").textContent = `Allow typing on ${host}?`;
  $("consentText").textContent = isSuggestedUrl(state.tab.url)
    ? "This looks like a Guacamole or XTAM console. Only allow it if you trust this host: ClipSource will type entries here as real keystrokes, and Enter runs each line."
    : "ClipSource will type entries here as real keystrokes, and Enter runs each line. Only allow hosts you trust.";
  show("consentView");
  $("consentNo").focus();
}

async function allowSite(allowed) {
  const host = hostOf(state.tab.url);
  state.settings.sites = await setSiteEnabled(host, allowed);
  state.enabled = isAllowedUrl(state.tab.url, state.settings.sites);
  $("siteToggle").checked = state.enabled;
}

function showConfirm(entry) {
  state.confirming = entry;
  const lines = lineCount(entry.text);
  const chars = [...entry.text].length;
  $("confirmTitle").textContent = lines > 1 ? `Type ${lines} lines into this page?` : `Type ${chars} characters into this page?`;
  $("confirmBtn").textContent = lines > 1 ? `Type ${lines} lines` : `Type ${chars} characters`;
  const all = entry.text.replace(/\r\n?/g, "\n").split("\n");
  const head = all.slice(0, PREVIEW_LINES).join("\n");
  $("confirmPreview").textContent = all.length > PREVIEW_LINES ? `${head}\n… ${all.length - PREVIEW_LINES} more lines` : head;
  show("confirmView");
  $("cancelBtn").focus(); // these lines run as commands: make Return cancel by default
}

async function startTyping(text) {
  showTyping({ done: 0, total: [...text].length });
  const response = await chrome.runtime.sendMessage({ cmd: "type", tabId: state.tab.id, text });
  if (!response?.ok) {
    show("pickView");
    message(response?.error || "Could not start typing.", true);
  }
}

function showTyping({ done, total }) {
  show("typingView");
  const pct = total ? Math.floor((done / total) * 100) : 0;
  $("barFill").style.width = `${pct}%`;
  $("typingText").textContent = `${done} of ${total} keys (${pct}%). Press Stop or ⌥⇧V to stop.`;
}

chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.event === "progress" && msg.tabId === state.tab?.id) showTyping(msg);
  if (msg?.event === "done") {
    show("pickView");
    if (msg.error) message(msg.error, true);
    else if (msg.stopped) message(`Stopped after ${msg.done} of ${msg.total} keys: ${msg.reason || "stopped"}.`, msg.reason !== "stopped by you");
    else message(`Typed ${msg.total} keys.`);
  }
});

// ---------- events ----------

$("search").addEventListener("input", (e) => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => load(e.target.value.trim()), 150);
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && (!$("confirmView").hidden || !$("consentView").hidden)) {
    e.preventDefault();
    (!$("confirmView").hidden ? $("cancelBtn") : $("consentNo")).click();
    return;
  }
  if ($("pickView").hidden) return;
  const n = state.entries.length;
  if (e.key === "ArrowDown" && n) {
    e.preventDefault();
    state.selected = (state.selected + 1) % n;
    updateSelection();
  } else if (e.key === "ArrowUp" && n) {
    e.preventDefault();
    state.selected = (state.selected - 1 + n) % n;
    updateSelection();
  } else if (e.key === "Enter" && n) {
    e.preventDefault();
    choose(state.entries[state.selected]);
  } else if (e.metaKey && /^[1-9]$/.test(e.key)) {
    const entry = state.entries[Number(e.key) - 1];
    if (entry) {
      e.preventDefault();
      choose(entry);
    }
  }
});

$("consentNo").addEventListener("click", () => {
  state.afterConsent = null;
  show("pickView");
});
$("consentYes").addEventListener("click", async () => {
  const entry = state.afterConsent;
  state.afterConsent = null;
  await allowSite(true);
  show("pickView");
  if (entry) choose(entry);
});
$("cancelBtn").addEventListener("click", () => {
  state.confirming = null;
  show("pickView");
});
$("confirmBtn").addEventListener("click", () => {
  const entry = state.confirming;
  state.confirming = null;
  if (entry) startTyping(entry.text);
});
$("stopBtn").addEventListener("click", () => chrome.runtime.sendMessage({ cmd: "stop" }));
$("copyCmd").addEventListener("click", async () => {
  await navigator.clipboard.writeText($("installCmd").textContent);
  $("copyCmd").textContent = "Copied";
});

$("siteToggle").addEventListener("change", async (e) => {
  await allowSite(e.target.checked);
  message("");
});

// ---------- startup ----------

async function init() {
  [state.tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  state.settings = await getSettings();
  const url = state.tab?.url || "";
  state.enabled = isAllowedUrl(url, state.settings.sites);

  const toggle = $("siteToggle");
  toggle.checked = state.enabled;
  if (!hostOf(url)) {
    toggle.disabled = true;
    $("siteNote").textContent = "Typing is not available on this page.";
    $("siteNote").hidden = false;
  }

  chrome.action.setBadgeText({ text: "", tabId: state.tab?.id }).catch(() => {});

  const { pending, lastError } = await chrome.storage.session.get(["pending", "lastError"]);
  await chrome.storage.session.remove(["pending", "lastError"]);
  if (lastError && Date.now() - lastError.at < 60_000) message(lastError.message, true);

  const status = await chrome.runtime.sendMessage({ cmd: "status" });
  if (status?.typing) showTyping(status);
  else show("pickView");

  await load();

  const fresh = pending && pending.tabId === state.tab?.id && Date.now() - pending.at < 120_000;
  if (status?.typing) return;
  if (fresh && pending.mode === "confirm") showConfirm(pending.entry);
  else if (fresh && pending.mode === "consent") showConsent(pending.entry);
  else if (!state.enabled && isSuggestedUrl(url)) showConsent();
}

init();
