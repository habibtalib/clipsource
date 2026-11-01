// Shared by /account and /app: config resolution, the pinned Supabase client and storage helpers.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./config.js";

const SETTINGS_KEY = "clipsource.supabase";
export const DEVICE_KEY = "clipsource.deviceId";

// --- storage (may throw in private windows or with blocked site data) ---

export function storageGet(store, key) {
  try { return globalThis[store].getItem(key); } catch { return null; }
}
export function storageSet(store, key, value) {
  try { globalThis[store].setItem(key, value); } catch { /* not persisted */ }
}
export function storageRemove(store, key) {
  try { globalThis[store].removeItem(key); } catch { /* nothing to remove */ }
}

// --- config ---

/** config.js values, else a custom server saved in this browser, else null. */
export function loadConfig() {
  if (SUPABASE_URL && SUPABASE_ANON_KEY) return { url: SUPABASE_URL, anonKey: SUPABASE_ANON_KEY, fromFile: true };
  try {
    const saved = JSON.parse(storageGet("localStorage", SETTINGS_KEY) || "null");
    if (saved?.url && saved?.anonKey) return { url: saved.url, anonKey: saved.anonKey, fromFile: false };
  } catch { /* bad JSON: ask again */ }
  return null;
}

/** Validates and saves a custom server. Returns an error message, or null when saved. */
export function saveConfig(rawUrl, rawKey) {
  const url = rawUrl.trim().replace(/\/+$/, "");
  const anonKey = rawKey.trim();
  let parsed;
  try { parsed = new URL(url); } catch { return "Enter a valid URL."; }
  if (!(parsed.protocol === "https:" || (isLocalUrl(url) && parsed.protocol === "http:"))) {
    return "Use an https URL (http only for localhost).";
  }
  if (!anonKey) return "Enter the anon key.";
  storageSet("localStorage", SETTINGS_KEY, JSON.stringify({ url, anonKey }));
  return null;
}

/** True for a local Supabase (supabase start): enables the dev-only email sign-in. */
export function isLocalUrl(url) {
  try { return ["localhost", "127.0.0.1"].includes(new URL(url).hostname); } catch { return false; }
}

/** Wires a settings form (#settings-form, #settings-url, #settings-key) that reloads on save. */
export function bindSettingsForm(setStatus) {
  const existing = loadConfig();
  document.getElementById("settings-url").value = existing?.url || "";
  document.getElementById("settings-key").value = existing?.anonKey || "";
  document.getElementById("settings-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const error = saveConfig(document.getElementById("settings-url").value, document.getElementById("settings-key").value);
    if (error) return setStatus(error, true);
    location.reload();
  });
}

// --- client ---

/** Uses the vendored UMD build (/vendor, loaded with SRI by the page), which defines globalThis.supabase. */
export async function createSupabase(config) {
  const createClient = globalThis.supabase?.createClient;
  if (typeof createClient !== "function") throw new Error("supabase-js not loaded");
  return createClient(config.url, config.anonKey, {
    auth: { flowType: "pkce", detectSessionInUrl: true, persistSession: true, autoRefreshToken: true },
  });
}

/** Signed-in user after an OAuth return (the ?code is exchanged by the client), with the URL cleaned. */
export async function currentUser(supabase) {
  const params = new URLSearchParams(location.search);
  const oauthError = params.get("error_description") || params.get("error");
  const { data, error } = await supabase.auth.getSession();
  if (params.has("code") || oauthError) {
    params.delete("code");
    params.delete("error");
    params.delete("error_code");
    params.delete("error_description");
    const rest = params.toString();
    history.replaceState(null, "", location.pathname + (rest ? `?${rest}` : ""));
  }
  return { user: data?.session?.user ?? null, error: oauthError || error?.message || null };
}

export function signInWithProvider(supabase, provider) {
  return supabase.auth.signInWithOAuth({ provider, options: { redirectTo: location.origin + location.pathname } });
}

/** PostgREST "function not found" / "column not found": the server runs an older schema without ClipSource Cloud. */
export function isMissingSchema(error) {
  if (!error) return false;
  return ["PGRST202", "PGRST204", "42883", "42703"].includes(error.code) || error.status === 404;
}

export const OLD_SCHEMA_MESSAGE =
  "This sync server runs an older ClipSource schema without accounts and devices. Viewing works; update the server's migrations for device management.";

// --- this browser as a 'web' device ---

export function browserName() {
  const ua = navigator.userAgent;
  if (/Edg\//.test(ua)) return "Edge";
  if (/Firefox\//.test(ua)) return "Firefox";
  if (/Chrome\//.test(ua) || /CriOS\//.test(ua)) return "Chrome";
  if (/Safari\//.test(ua)) return "Safari";
  return "Browser";
}

/** Stable random ID for this browser, shared by /app and /account. */
export function deviceId() {
  let id = storageGet("localStorage", DEVICE_KEY);
  if (!id) {
    id = crypto.randomUUID();
    storageSet("localStorage", DEVICE_KEY, id);
  }
  return id;
}

/**
 * register_device(kind 'web'). The Cloud schema only lets a session that registered a device read or write
 * synced data. device_in_use means another live sign-in owns the stored ID: retry once with a fresh one.
 * Returns {ok} | {ok:false, error, missingSchema}.
 */
export async function registerWebDevice(supabase, retried = false) {
  const { data, error } = await supabase.rpc("register_device", {
    p_device_id: deviceId(),
    p_name: `Web (${browserName()})`,
    p_kind: "web",
  });
  if (error) return { ok: false, error: error.message, missingSchema: isMissingSchema(error) };
  if (data?.ok) return { ok: true, data };
  if (data?.error === "device_in_use" && !retried) {
    storageRemove("localStorage", DEVICE_KEY);
    return registerWebDevice(supabase, true);
  }
  return { ok: false, error: data?.error || "unknown error", missingSchema: false };
}
