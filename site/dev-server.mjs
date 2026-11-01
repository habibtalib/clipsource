// Local preview of the Vercel deployment: cleanUrls, directory index and the vercel.json headers.
// The CSP gets http/ws://localhost and 127.0.0.1 added to connect-src so the pages can reach a local
// Supabase (`supabase start`); production never allows them. Not deployed (.vercelignore).
// Run: node site/dev-server.mjs [port]
import http from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] || 8000);
const vercel = JSON.parse(readFileSync(join(root, "..", "vercel.json"), "utf8"));
const LOCAL = "http://localhost:* ws://localhost:* http://127.0.0.1:* ws://127.0.0.1:*";
const types = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css",
  ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".mp4": "video/mp4", ".json": "application/json",
};

function headersFor(path) {
  const out = {};
  for (const rule of vercel.headers) {
    const re = new RegExp(`^${rule.source.replace(/\(\.\*\)/g, ".*")}$`);
    if (!re.test(path)) continue;
    for (const h of rule.headers) out[h.key] = h.value;
  }
  delete out["Strict-Transport-Security"];
  if (out["Content-Security-Policy"]) {
    out["Content-Security-Policy"] = out["Content-Security-Policy"].replace(/connect-src ([^;]*)/, `connect-src $1 ${LOCAL}`);
  }
  return out;
}

http.createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
  if (path.endsWith(".html")) {
    res.writeHead(308, { Location: path.replace(/(index)?\.html$/, "") || "/" });
    return res.end();
  }
  let file = join(root, path);
  if (existsSync(file) && statSync(file).isDirectory()) file = join(file, "index.html");
  else if (!existsSync(file) && existsSync(`${file}.html`)) file = `${file}.html`;
  if (!file.startsWith(root) || !existsSync(file)) {
    res.writeHead(404, { "Content-Type": "text/plain" });
    return res.end("not found");
  }
  res.writeHead(200, { "Content-Type": types[extname(file)] || "application/octet-stream", ...headersFor(path) });
  res.end(readFileSync(file));
}).listen(port, "127.0.0.1", () => console.log(`ClipSource site on http://127.0.0.1:${port}`));
