import { DEFAULTS, clampInt, getSettings } from "./settings.js";

const $ = (id) => document.getElementById(id);
let sites = [];

function renderSites() {
  const list = $("sites");
  list.replaceChildren();
  if (!sites.length) {
    const li = document.createElement("li");
    li.className = "muted";
    li.textContent = "No sites allowed yet.";
    list.append(li);
  }
  for (const host of sites) {
    const li = document.createElement("li");
    const name = document.createElement("code");
    name.textContent = host;
    const remove = document.createElement("button");
    remove.className = "btn small";
    remove.textContent = "Remove";
    remove.addEventListener("click", () => {
      sites = sites.filter((s) => s !== host);
      renderSites();
    });
    li.append(name, remove);
    list.append(li);
  }
}

/** Accepts "host", "host:port" or a full URL; returns host[:port] in lower case, or null. */
function parseHost(value) {
  const v = value.trim();
  if (!v) return null;
  try {
    return new URL(v.includes("://") ? v : `https://${v}`).host.toLowerCase() || null;
  } catch {
    return null;
  }
}

$("addForm").addEventListener("submit", (e) => {
  e.preventDefault();
  const host = parseHost($("newSite").value);
  if (!host) return;
  if (!sites.includes(host)) sites.push(host);
  $("newSite").value = "";
  renderSites();
});

$("save").addEventListener("click", async () => {
  await chrome.storage.sync.set({
    charDelay: clampInt($("charDelay").value, 0, 1000, DEFAULTS.charDelay),
    enterDelay: clampInt($("enterDelay").value, 0, 5000, DEFAULTS.enterDelay),
    confirmChars: clampInt($("confirmChars").value, 1, 20000, DEFAULTS.confirmChars),
    sites,
  });
  $("saved").textContent = "Saved.";
  setTimeout(() => ($("saved").textContent = ""), 1500);
});

const settings = await getSettings();
$("charDelay").value = settings.charDelay;
$("enterDelay").value = settings.enterDelay;
$("confirmChars").value = settings.confirmChars;
sites = settings.sites;
renderSites();
