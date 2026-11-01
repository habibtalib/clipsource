// Supabase access from Edge Functions without a client library: Auth to identify the caller, PostgREST with
// the service role (injected as SUPABASE_SERVICE_ROLE_KEY) to read and write profiles.

import { requireEnv } from "./http.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUUID(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

export interface AuthUser {
  id: string;
  email?: string;
}

/** The signed-in caller from the request's `Authorization: Bearer <user JWT>`, or null. */
export async function getUser(req: Request): Promise<AuthUser | null> {
  const auth = req.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return null;
  const res = await fetch(`${requireEnv("SUPABASE_URL")}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: requireEnv("SUPABASE_ANON_KEY") },
  });
  if (!res.ok) return null;
  const user = await res.json();
  return isUUID(user?.id) ? { id: user.id, email: user.email ?? undefined } : null;
}

export interface Profile {
  user_id: string;
  plan: string;
  stripe_customer_id: string | null;
  subscription_status: string | null;
  current_period_end: string | null;
}

async function admin(method: string, path: string, body?: unknown): Promise<unknown> {
  const key = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
  const res = await fetch(`${requireEnv("SUPABASE_URL")}/rest/v1/${path}`, {
    method,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`PostgREST ${method} ${path.split("?")[0]} failed: HTTP ${res.status}`);
  return res.status === 204 ? [] : await res.json();
}

export async function getProfile(userId: string): Promise<Profile | null> {
  const rows = await admin("GET", `profiles?user_id=eq.${encodeURIComponent(userId)}&select=*`) as Profile[];
  return rows[0] ?? null;
}

/**
 * Updates the profile matched by `column`; returns how many rows changed. With `notAfter` (ISO time) the row
 * changes only if its `stripe_event_at` is null or not later, so a late, older Stripe event cannot win.
 */
export async function patchProfile(
  column: "user_id" | "stripe_customer_id",
  value: string,
  patch: object,
  notAfter?: string,
): Promise<number> {
  let filter = `${column}=eq.${encodeURIComponent(value)}`;
  if (notAfter) filter += `&or=${encodeURIComponent(`(stripe_event_at.is.null,stripe_event_at.lte.${notAfter})`)}`;
  const rows = await admin("PATCH", `profiles?${filter}`, patch) as unknown[];
  return rows.length;
}

/** Creates the profile if the signup trigger has not (e.g. users that predate the migration). */
export async function ensureProfile(userId: string): Promise<Profile> {
  const existing = await getProfile(userId);
  if (existing) return existing;
  const rows = await admin("POST", "profiles?on_conflict=user_id", { user_id: userId }) as Profile[];
  return rows[0] ?? (await getProfile(userId))!;
}
