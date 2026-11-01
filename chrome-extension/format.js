// Display helpers for the popup, matching ClipFormatter.shortAge and ClipSourceInfo.cleanWindowTitle.

/** Compact age: "now", "5m", "3h", "Yesterday", then "12 Oct" (with year when not this year). */
export function shortAge(date, now = new Date()) {
  const seconds = (now - date) / 1000;
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const sameDay = (a, b) => a.toDateString() === b.toDateString();
  if (sameDay(date, now)) return `${Math.floor(seconds / 3600)}h`;
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (sameDay(date, yesterday)) return "Yesterday";
  const opts = { day: "numeric", month: "short" };
  if (date.getFullYear() !== now.getFullYear()) opts.year = "numeric";
  return date.toLocaleDateString("en-GB", opts);
}

/** Window title without a trailing " - <App>"; null when nothing is left. */
export function cleanWindowTitle(title, app) {
  let t = (title || "").trim();
  if (!t) return null;
  if (app) {
    for (const sep of [" - ", " — ", " – "]) {
      const i = t.lastIndexOf(sep + app);
      if (i >= 0) {
        const rest = t.slice(i + sep.length + app.length);
        if (rest === "" || rest.startsWith(sep)) t = t.slice(0, i);
      }
    }
  }
  t = t.trim();
  return !t || t === app ? null : t;
}

const PALETTE = ["#E5483A", "#FF8A4C", "#2A9D8F", "#3D7BD9", "#8E5BD9", "#C2400D", "#4C9A2A", "#D94C8A"];

export function avatarColor(name) {
  let h = 0;
  for (const ch of name || "?") h = (h * 31 + ch.codePointAt(0)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

export function initial(name) {
  const first = [...(name || "?").trim()][0] || "?";
  return first.toUpperCase();
}
