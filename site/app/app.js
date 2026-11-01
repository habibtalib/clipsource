// ClipSource web viewer. Clip text, labels and window titles are untrusted: render with textContent only.
import {
  deriveKey, keysFromMaster, hashText, sealPayload, openPayload, verifyCheck, iterationsInRange, MIN_ITERATIONS, MAX_ITERATIONS,
} from "./sync-crypto.js";
import {
  storageGet, storageSet, storageRemove, loadConfig, bindSettingsForm, isLocalUrl, createSupabase, currentUser,
  signInWithProvider, OLD_SCHEMA_MESSAGE, browserName, deviceId, registerWebDevice,
} from "../supabase.js";

const MASTER_PREFIX = "clipsource.master.";
const FETCH_LIMIT = 1000;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const $ = (id) => document.getElementById(id);
const views = ["view-settings", "view-signin", "view-nokey", "view-unlock", "view-clips"];

let supabase = null;
let user = null;
let keys = null;
let clips = [];
let channel = null;
let reloadTimer = null;
/** False on a self-hosted server without the Cloud schema: rows are then written without device_id. */
let deviceRegistered = false;
/** Registration was refused (limit, ID clash): the Cloud write policy would reject sends and deletes. */
let readOnly = false;

// --- ui helpers ---

function show(view) {
  for (const v of views) $(v).hidden = v !== view;
  $("sign-out").hidden = !user;
}

function setStatus(text, isError = false) {
  $("status").textContent = text;
  $("status").classList.toggle("error", isError);
}

let toastTimer = null;
function toast(text) {
  const el = $("toast");
  el.textContent = text;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 1800);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** now / 5m / 3h / Yesterday / 12 Oct (year added when not this year). */
export function compactAge(seconds, now = Date.now()) {
  const date = new Date(seconds * 1000);
  const diff = Math.max(0, (now - date.getTime()) / 1000);
  if (diff < 60) return "now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  const today = new Date(now);
  const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  if (date.getTime() >= startOfToday) return `${Math.floor(diff / 3600)}h`;
  if (date.getTime() >= startOfToday - 86400000) return "Yesterday";
  const label = `${date.getDate()} ${MONTHS[date.getMonth()]}`;
  return date.getFullYear() === today.getFullYear() ? label : `${label} ${date.getFullYear()}`;
}

/** Window title without a trailing " - <app>" (or " — <app>"). */
export function cleanTitle(title, app) {
  if (!title) return "";
  if (app) {
    for (const sep of [" - ", " — ", " – "]) {
      if (title.endsWith(sep + app)) return title.slice(0, -(sep.length + app.length));
    }
  }
  return title;
}


function platformName() {
  const p = navigator.userAgentData?.platform || navigator.platform || "";
  if (/iPhone|iPad|iOS/i.test(p) || /iPhone|iPad/.test(navigator.userAgent)) return "iOS";
  if (/Android/i.test(p) || /Android/.test(navigator.userAgent)) return "Android";
  if (/Mac/i.test(p)) return "macOS";
  if (/Win/i.test(p)) return "Windows";
  if (/Linux/i.test(p)) return "Linux";
  return p || "unknown";
}


// --- config ---

$("settings-open").addEventListener("click", () => {
  setStatus("");
  show("view-settings");
});

// --- auth ---

for (const button of document.querySelectorAll("[data-provider]")) {
  button.addEventListener("click", async () => {
    button.disabled = true;
    const { error } = await signInWithProvider(supabase, button.dataset.provider);
    if (error) {
      button.disabled = false;
      setStatus(error.message, true);
    }
  });
}

// Dev-only: shown when the server is a local Supabase, for generated test users.
$("dev-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const { data, error } = await supabase.auth.signInWithPassword({
    email: $("dev-email").value.trim(),
    password: $("dev-password").value,
  });
  if (error) return setStatus(error.message, true);
  user = data.user;
  afterSignIn();
});

$("sign-out").addEventListener("click", async () => {
  if (user) storageRemove("sessionStorage", MASTER_PREFIX + user.id);
  if (channel) await supabase.removeChannel(channel);
  channel = null;
  keys = null;
  clips = [];
  user = null;
  deviceRegistered = false;
  readOnly = false;
  await supabase.auth.signOut({ scope: "local" }); // global would also sign out the Macs
  setStatus("Signed out.");
  show("view-signin");
});

// --- unlock ---

async function loadKeyRecord() {
  const { data, error } = await supabase.from("sync_keys").select("salt, check_value, iterations").maybeSingle();
  if (error) throw error;
  return data;
}

async function afterSignIn() {
  setStatus("");
  let record;
  try {
    record = await loadKeyRecord();
  } catch (error) {
    setStatus(`Cannot read sync settings: ${error.message}`, true);
    return show("view-nokey");
  }
  if (!record) return show("view-nokey");
  if (!iterationsInRange(record.iterations)) {
    show(null);
    return setStatus(`Refusing this account's sync key: it asks for ${Number(record.iterations).toLocaleString("en")} PBKDF2 rounds, outside the accepted ${MIN_ITERATIONS.toLocaleString("en")}–${MAX_ITERATIONS.toLocaleString("en")}. Reset sync from your Mac.`, true);
  }

  const remembered = storageGet("sessionStorage", MASTER_PREFIX + user.id);
  if (remembered) {
    try {
      const restored = await keysFromMaster(remembered);
      if (await verifyCheck(restored, record.check_value)) {
        keys = restored;
        await registerDevice();
        return startClips();
      }
    } catch { /* fall through to the passphrase form */ }
    storageRemove("sessionStorage", MASTER_PREFIX + user.id);
  }

  show("view-unlock");
  $("unlock-pass").focus();
  $("unlock-form").onsubmit = async (event) => {
    event.preventDefault();
    const button = $("unlock-btn");
    button.disabled = true;
    button.textContent = "Unlocking…";
    setStatus("");
    // Let the label paint before PBKDF2 (600k iterations) runs.
    await new Promise((resolve) => setTimeout(resolve, 30));
    try {
      const derived = await deriveKey($("unlock-pass").value, record.salt, record.iterations);
      if (!(await verifyCheck(derived, record.check_value))) {
        setStatus("Wrong sync passphrase.", true);
        return;
      }
      keys = derived;
      $("unlock-pass").value = "";
      if ($("unlock-remember").checked) storageSet("sessionStorage", MASTER_PREFIX + user.id, derived.master);
      await registerDevice();
      startClips();
    } catch (error) {
      setStatus(`Unlock failed: ${error.message}`, true);
    } finally {
      button.disabled = false;
      button.textContent = "Unlock";
    }
  };
}

/** Registers this browser as a 'web' device (never counts toward the plan's Mac limit). */
async function registerDevice() {
  deviceRegistered = false;
  readOnly = false;
  const result = await registerWebDevice(supabase);
  if (result.ok) {
    deviceRegistered = true;
    return;
  }
  if (result.missingSchema) return noticeLater(OLD_SCHEMA_MESSAGE);
  readOnly = true;
  noticeLater(REGISTER_ERRORS[result.error] || `Cannot register this browser: ${result.error}`);
}

const REGISTER_ERRORS = {
  web_limit: "This account has reached its limit of web browsers, so this one is read-only. Remove an old browser on the Account page to send and delete here.",
  device_in_use: "This browser could not get a device ID for your account, so it is read-only. Clear this site's data and reload.",
  device_limit: "This account has reached its device limit. Remove a device on the Account page.",
};

/** Status line shown after the view switch (startClips clears the status). */
let pendingNotice = "";
function noticeLater(text) {
  pendingNotice = text;
}

// --- clips ---

async function loadClips() {
  const { data, error } = await supabase
    .from("clips")
    .select("hash, payload, created_at")
    .eq("deleted", false)
    .order("created_at", { ascending: false })
    .limit(FETCH_LIMIT);
  if (error) {
    setStatus(`Cannot load clips: ${error.message}`, true);
    return;
  }
  let skipped = 0;
  const opened = [];
  for (const row of data) {
    if (!row.payload) continue;
    try {
      const p = await openPayload(keys, row.payload);
      // The row's dedup hash must match its decrypted text; anything else was swapped or tampered with.
      if (typeof p?.text !== "string" || (await hashText(keys, p.text)) !== row.hash) {
        skipped++;
        continue;
      }
      opened.push({ hash: row.hash, p });
    } catch {
      skipped++;
    }
  }
  opened.sort((a, b) => (b.p.createdAt || 0) - (a.p.createdAt || 0));
  clips = opened;
  $("list-note").textContent = skipped ? `${skipped} clip(s) could not be decrypted or verified and are hidden.` : "";
  render();
}

function matches(clip, query) {
  if (!query) return true;
  const s = clip.p.source || {};
  return [clip.p.text, s.app, s.label, s.windowTitle, clip.p.deviceName]
    .some((v) => typeof v === "string" && v.toLowerCase().includes(query));
}

function render() {
  const query = $("search").value.trim().toLowerCase();
  const list = $("list");
  list.replaceChildren();
  const shown = clips.filter((c) => matches(c, query));
  if (!shown.length) {
    list.append(el("li", "muted", clips.length ? "No clips match." : "No clips yet. Copy something on a Mac."));
    return;
  }
  for (const clip of shown) list.append(renderRow(clip));
}

function renderRow(clip) {
  const p = clip.p;
  const s = p.source || {};
  const li = el("li", "row");
  li.tabIndex = 0;

  const head = el("div", "row-head");
  head.append(el("span", "app", s.app || "Unknown app"));
  if (s.label) head.append(el("span", "chip label", s.label));
  if (p.deviceName) head.append(el("span", "chip", p.deviceName));
  li.append(head, el("span", "age", compactAge(p.createdAt || 0)));

  const title = cleanTitle(s.windowTitle, s.app);
  if (title) li.append(el("div", "title", title));
  li.append(el("p", "preview", p.text || ""));

  if (!readOnly) {
    const actions = el("div", "row-actions");
    const del = el("button", "delete", "Delete");
    del.type = "button";
    del.addEventListener("click", (event) => {
      event.stopPropagation();
      deleteClip(clip);
    });
    actions.append(del);
    li.append(actions);
  }

  const copy = () => copyClip(clip);
  li.addEventListener("click", copy);
  li.addEventListener("keydown", (event) => {
    if (event.target === li && (event.key === "Enter" || event.key === " ")) {
      event.preventDefault();
      copy();
    }
  });
  return li;
}

async function copyClip(clip) {
  try {
    await navigator.clipboard.writeText(clip.p.text || "");
    toast("Copied");
  } catch {
    toast("Copy blocked by the browser");
  }
}

async function deleteClip(clip) {
  const { error } = await supabase.from("clips").update(withDevice({ deleted: true, payload: null })).eq("hash", clip.hash);
  if (error) return setStatus(`Delete failed: ${error.message}`, true);
  clips = clips.filter((c) => c !== clip);
  render();
  toast("Deleted");
}

/** Adds this browser's device_id to a row when the server knows it (required by the Cloud write policy). */
function withDevice(row) {
  return deviceRegistered ? { ...row, device_id: deviceId() } : row;
}

$("search").addEventListener("input", render);

$("send-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = $("send-text").value;
  if (!text.trim()) return;
  const button = $("send-btn");
  button.disabled = true;
  try {
    const browser = browserName();
    const payload = {
      v: 1,
      text,
      origin: "web",
      source: { app: "Web", windowTitle: `${browser} on ${platformName()}` },
      createdAt: Date.now() / 1000,
      deviceId: deviceId(),
      deviceName: `Web (${browser})`,
    };
    const row = withDevice({
      hash: await hashText(keys, text),
      payload: await sealPayload(keys, payload),
      created_at: new Date().toISOString(),
      deleted: false,
    });
    const { error } = await supabase.from("clips").upsert(row, { onConflict: "user_id,hash" });
    if (error) throw error;
    $("send-text").value = "";
    toast("Sent to your Macs");
    loadClips();
  } catch (error) {
    setStatus(`Send failed: ${error.message}`, true);
  } finally {
    button.disabled = false;
  }
});

function scheduleReload() {
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(loadClips, 300);
}

function startClips() {
  setStatus(pendingNotice);
  pendingNotice = "";
  $("send-form").hidden = readOnly;
  show("view-clips");
  loadClips();
  if (!channel) {
    channel = supabase
      .channel("clips-changes")
      // INSERT and UPDATE only: DELETE events carry no row filter, so they could leak other users' activity.
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "clips" }, scheduleReload)
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "clips" }, scheduleReload)
      .subscribe();
  }
}

// --- boot ---

async function boot() {
  const config = loadConfig();
  bindSettingsForm(setStatus);
  $("settings-open").hidden = !!config?.fromFile;
  if (!config) {
    setStatus("");
    return show("view-settings");
  }
  $("dev-signin").hidden = !isLocalUrl(config.url);

  setStatus("Loading…");
  try {
    supabase = await createSupabase(config);
  } catch {
    return setStatus("Cannot load the Supabase library. Check your connection and reload.", true);
  }
  const session = await currentUser(supabase);
  user = session.user;

  supabase.auth.onAuthStateChange((event, next) => {
    if (event === "SIGNED_OUT" && user) {
      user = null;
      keys = null;
      show("view-signin");
    }
    if (next?.user) user = next.user;
  });

  if (!user) {
    setStatus(session.error || "", !!session.error);
    return show("view-signin");
  }
  afterSignIn();
}

boot();
