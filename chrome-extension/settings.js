// Settings in chrome.storage.sync, shared by the service worker, popup and options page.

export const HOST_NAME = "dev.habibtalib.clipsource";

export const DEFAULTS = {
  charDelay: 8,      // ms between characters
  enterDelay: 60,    // ms after each Enter, so the remote shell keeps up
  confirmChars: 500, // texts longer than this (or with more than one line) need confirmation
  sites: [],         // extra hosts (host[:port]) where typing is enabled
};

export async function getSettings() {
  const stored = await chrome.storage.sync.get(DEFAULTS);
  return {
    charDelay: clampInt(stored.charDelay, 0, 1000, DEFAULTS.charDelay),
    enterDelay: clampInt(stored.enterDelay, 0, 5000, DEFAULTS.enterDelay),
    confirmChars: clampInt(stored.confirmChars, 1, 20000, DEFAULTS.confirmChars),
    sites: Array.isArray(stored.sites) ? stored.sites.filter((s) => typeof s === "string" && s) : [],
  };
}

export function clampInt(value, min, max, fallback) {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? Math.min(Math.max(n, min), max) : fallback;
}

export async function setSiteEnabled(host, enabled) {
  const { sites } = await getSettings();
  const h = host.toLowerCase();
  const next = enabled ? [...new Set([...sites, h])] : sites.filter((s) => s !== h);
  await chrome.storage.sync.set({ sites: next });
  return next;
}

/** One request to the native host; rejects with a readable message. */
export function nativeRequest(request) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST_NAME, request, (response) => {
      const err = chrome.runtime.lastError;
      if (err) return reject(new Error(err.message || String(err)));
      if (!response || response.ok === false) return reject(new Error(response?.error || "no response from ClipSource"));
      resolve(response);
    });
  });
}

/** True when the error means the native host is not installed. */
export function isHostMissing(error) {
  return /not found|forbidden|exited/i.test(String(error?.message || error));
}
