// ClipSource account page: plan, billing and devices. Device names are user data: render with textContent only.
import {
  storageGet, storageRemove, loadConfig, bindSettingsForm, isLocalUrl, createSupabase, currentUser, signInWithProvider, isMissingSchema,
  DEVICE_KEY, deviceId, registerWebDevice,
} from "../supabase.js";

const $ = (id) => document.getElementById(id);
const views = ["view-settings", "view-signin", "view-account"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

let supabase = null;
let user = null;

// --- ui helpers ---

function show(view) {
  for (const v of views) $(v).hidden = v !== view;
  $("sign-out").hidden = !user;
}

function setStatus(text, kind = "") {
  $("status").textContent = text;
  $("status").className = `status ${kind === true ? "error" : kind}`;
}

let toastTimer = null;
function toast(text) {
  const t = $("toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 2200);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function formatDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return `${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

function lastSeen(iso) {
  if (!iso) return "never";
  const diff = (Date.now() - new Date(iso).getTime()) / 1000;
  if (diff < 120) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)} min ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} h ago`;
  if (diff < 7 * 86400) return `${Math.floor(diff / 86400)} d ago`;
  return formatDate(iso);
}

/** Accepts only https URLs (or http on localhost) from the billing functions before navigating. */
function safeRedirect(url) {
  try {
    const u = new URL(url);
    return u.protocol === "https:" || (u.protocol === "http:" && isLocalUrl(url)) ? u.href : null;
  } catch {
    return null;
  }
}

const BILLING_ERRORS = {
  already_subscribed: "You already have a subscription. Use Manage billing to change or cancel it.",
};

async function functionError(error) {
  // FunctionsHttpError carries the Response; FunctionsFetchError means the function is not deployed or unreachable.
  if (error?.context && typeof error.context.json === "function") {
    try {
      const body = await error.context.json();
      if (body?.error) return BILLING_ERRORS[body.error] || `Billing could not start (${body.error}). Try again in a moment.`;
    } catch { /* not JSON */ }
    if (error.context.status === 404) return "Billing is not available on this server.";
  }
  if (error?.name === "FunctionsFetchError" || error?.name === "FunctionsRelayError") return "Billing is not available on this server.";
  return error?.message || "Unknown error";
}

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
  setStatus("");
  loadAccount();
});

$("sign-out").addEventListener("click", async () => {
  await supabase.auth.signOut({ scope: "local" }); // global would also sign out the Macs
  user = null;
  setStatus("Signed out.");
  show("view-signin");
});

// --- account ---

async function loadAccount() {
  const { data, error } = await supabase.rpc("account_status");
  if (error) {
    show(null);
    return setStatus(isMissingSchema(error)
      ? "This server runs an older ClipSource schema without accounts. Plans and devices are only available on ClipSource Cloud or an updated self-hosted server."
      : `Cannot load your account: ${error.message}`, true);
  }
  if (!data || data.ok === false) return setStatus(`Cannot load your account: ${data?.error || "no profile"}`, true);
  renderAccount(data);
  show("view-account");
}

function renderAccount(a) {
  const pro = a.plan === "pro";
  $("acct-email").textContent = user?.email || "";
  $("acct-plan").textContent = pro ? "Pro" : "Free";
  $("acct-plan").classList.toggle("pro", pro);

  const macs = (a.devices || []).filter((d) => d.kind === "mac").length;
  $("acct-devices").textContent = a.device_limit == null ? `${macs} (unlimited)` : `${macs} of ${a.device_limit}`;
  $("acct-retention").textContent = `${a.retention_days} days`;

  const status = a.subscription_status;
  $("acct-sub-row").hidden = !status;
  if (status) {
    const end = formatDate(a.current_period_end);
    const ending = ["canceled", "unpaid", "incomplete_expired"].includes(status);
    $("acct-sub").textContent = end ? `${status} · ${ending ? "ends" : "renews"} ${end}` : status;
  }

  $("card-upgrade").hidden = pro;
  $("card-billing").hidden = !pro && !status;
  if (!pro && new URLSearchParams(location.search).has("upgrade")) $("card-upgrade").classList.add("highlight");

  renderDevices(a.devices || []);
}

function renderDevices(devices) {
  const list = $("device-list");
  list.replaceChildren();
  if (!devices.length) {
    list.append(el("li", "muted", "No devices yet. Turn on sync in ClipSource on your Mac."));
    return;
  }
  const thisBrowser = storageGet("localStorage", DEVICE_KEY);
  for (const d of devices) list.append(renderDevice(d, d.device_id === thisBrowser));
}

function renderDevice(d, isThisBrowser) {
  const li = el("li", "device");
  const info = el("div", "device-info");
  const head = el("div", "device-head");
  const name = el("span", "device-name", d.name);
  head.append(name, el("span", "chip", d.kind === "mac" ? "Mac" : "Web"));
  if (isThisBrowser) head.append(el("span", "chip accent", "This browser"));
  info.append(head, el("span", "muted small", `Last seen ${lastSeen(d.last_seen_at)}`));

  const actions = el("div", "device-actions");
  const rename = el("button", "link", "Rename");
  rename.type = "button";
  rename.addEventListener("click", () => startRename(li, info, actions, d));
  const remove = el("button", "link remove", "Remove");
  remove.type = "button";
  remove.addEventListener("click", () => removeDevice(d));
  actions.append(rename, remove);

  li.append(info, actions);
  return li;
}

function startRename(li, info, actions, d) {
  const form = el("form", "rename-form");
  const input = el("input");
  input.type = "text";
  input.value = d.name;
  input.maxLength = 100;
  input.setAttribute("aria-label", "Device name");
  const save = el("button", "primary", "Save");
  save.type = "submit";
  const cancel = el("button", "link", "Cancel");
  cancel.type = "button";
  form.append(input, save, cancel);
  info.hidden = true;
  actions.hidden = true;
  li.prepend(form);
  input.focus();
  input.select();

  cancel.addEventListener("click", () => {
    form.remove();
    info.hidden = false;
    actions.hidden = false;
  });
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = input.value.trim();
    if (!name) return;
    save.disabled = true;
    const { data, error } = await supabase.rpc("rename_device", { p_device_id: d.device_id, p_name: name });
    if (error || data?.ok === false) {
      save.disabled = false;
      return setStatus(`Rename failed: ${error?.message || data.error}`, true);
    }
    toast("Renamed");
    loadAccount();
  });
}

async function removeDevice(d) {
  if (!confirm(`Remove "${d.name}"? It is signed out and loses access to your synced clips immediately.`)) return;
  const { data, error } = await supabase.rpc("remove_device", { p_device_id: d.device_id });
  if (error || data?.ok === false) return setStatus(`Remove failed: ${error?.message || data.error}`, true);
  toast("Device removed and signed out");
  loadAccount();
}

// --- billing ---

for (const button of document.querySelectorAll("[data-interval]")) {
  button.addEventListener("click", () => openBilling("billing-checkout", { interval: button.dataset.interval }, button));
}
$("billing-portal").addEventListener("click", (event) => openBilling("billing-portal", {}, event.currentTarget));

async function openBilling(fn, body, button) {
  button.disabled = true;
  setStatus("Opening Stripe…");
  const { data, error } = await supabase.functions.invoke(fn, { body });
  const url = !error && safeRedirect(data?.url);
  if (!url) {
    button.disabled = false;
    return setStatus(error ? await functionError(error) : "Billing returned no link.", true);
  }
  location.assign(url);
}

// --- delete synced data ---

$("delete-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if ($("delete-confirm").value.trim() !== "DELETE") return setStatus("Type DELETE to confirm.", true);
  const button = $("delete-btn");
  button.disabled = true;
  try {
    // Synced rows are only visible to a session with a registered device, so this browser registers first.
    const reg = await registerWebDevice(supabase);
    if (!reg.ok && !reg.missingSchema) throw new Error(reg.error === "web_limit"
      ? "this account has reached its web browser limit. Remove an old browser above, then try again"
      : reg.error);
    const clipsDel = await supabase.from("clips").delete().gte("created_at", "1970-01-01T00:00:00Z");
    if (clipsDel.error) throw clipsDel.error;
    const keyDel = await supabase.from("sync_keys").delete().eq("user_id", user.id);
    if (keyDel.error) throw keyDel.error;
    // RLS turns a refused delete into "0 rows", so confirm nothing is left before reporting success.
    const left = await supabase.from("clips").select("hash", { count: "exact", head: true });
    const keyLeft = await supabase.from("sync_keys").select("user_id", { count: "exact", head: true });
    if (left.error || keyLeft.error || left.count || keyLeft.count) throw new Error("the server kept some data. Try again");
    // Other devices first: removing this browser revokes this session.
    const { data } = await supabase.rpc("account_status");
    const self = reg.ok ? deviceId() : null;
    for (const d of (data?.devices || []).filter((x) => x.device_id !== self)) {
      const { error } = await supabase.rpc("remove_device", { p_device_id: d.device_id });
      if (error) throw error;
    }
    $("delete-confirm").value = "";
    if (self) {
      await supabase.rpc("remove_device", { p_device_id: self });
      // Local only (never global, which would sign out the Macs). The session is already revoked by remove_device,
      // so even signOut({ scope: "local" }) would only get a 403 from /logout; clear the stored session instead.
      supabase.auth.stopAutoRefresh();
      storageRemove("localStorage", supabase.auth.storageKey);
      user = null;
      show("view-signin");
      return setStatus("Synced data deleted and all devices signed out. Set a new passphrase on your Mac to sync again.", "ok");
    }
    setStatus("Synced data deleted. Set a new passphrase on your Mac to sync again.", "ok");
    loadAccount();
  } catch (error) {
    setStatus(`Delete failed: ${error.message}`, true);
  } finally {
    button.disabled = false;
  }
});

// --- boot ---

async function boot() {
  const config = loadConfig();
  bindSettingsForm(setStatus);
  if (!config) return show("view-settings");
  $("dev-signin").hidden = !isLocalUrl(config.url);

  const params = new URLSearchParams(location.search);
  const checkout = params.get("checkout");
  if (checkout) {
    params.delete("checkout");
    const rest = params.toString();
    history.replaceState(null, "", location.pathname + (rest ? `?${rest}` : ""));
  }

  setStatus("Loading…");
  try {
    supabase = await createSupabase(config);
  } catch {
    return setStatus("Cannot load the Supabase library. Check your connection and reload.", true);
  }
  const session = await currentUser(supabase);
  user = session.user;
  if (!user) {
    setStatus(session.error || "", session.error ? "error" : "");
    return show("view-signin");
  }
  setStatus(checkout === "success" ? "Thanks! Pro turns on as soon as Stripe confirms the payment. Refresh in a moment if it still says Free." : "",
    checkout === "success" ? "ok" : "");
  loadAccount();
}

boot();
