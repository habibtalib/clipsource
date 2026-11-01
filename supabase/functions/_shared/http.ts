// CORS and JSON helpers shared by the browser-facing functions (billing-checkout, billing-portal).

const LOCAL_ORIGIN = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

/**
 * SITE_URL's origin. Any http://localhost / http://127.0.0.1 origin only when SITE_URL is itself local or
 * ALLOW_LOCALHOST=1 (local development), never in production.
 */
export function allowedOrigin(
  origin: string | null,
  siteURL: string | undefined,
  allowLocalhost = false,
): string | null {
  if (!origin) return null;
  let siteOrigin: string | null = null;
  try {
    siteOrigin = siteURL ? new URL(siteURL).origin : null;
  } catch {
    siteOrigin = null;
  }
  if (siteOrigin && origin === siteOrigin) return origin;
  const localSite = siteOrigin !== null && LOCAL_ORIGIN.test(siteOrigin);
  if ((localSite || allowLocalhost) && LOCAL_ORIGIN.test(origin)) return origin;
  return null;
}

export function corsHeaders(req: Request): Record<string, string> {
  const origin = allowedOrigin(
    req.headers.get("Origin"),
    Deno.env.get("SITE_URL"),
    Deno.env.get("ALLOW_LOCALHOST") === "1",
  );
  if (!origin) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

export function json(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(req) },
  });
}

/** Errors carry a short code for the client; details go to the function log only. */
export function fail(req: Request, status: number, error: string): Response {
  return json(req, { error }, status);
}

export function preflight(req: Request): Response | null {
  return req.method === "OPTIONS" ? new Response(null, { status: 204, headers: corsHeaders(req) }) : null;
}

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

/** SITE_URL without a trailing slash. */
export function siteURL(): string {
  return requireEnv("SITE_URL").replace(/\/+$/, "");
}
