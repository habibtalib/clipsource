import type { Subscription } from "./billing.ts";

// Minimal Stripe client: form-encoded REST calls with fetch and webhook signature checks with WebCrypto.

type FormValue = string | number | boolean | null | undefined | FormValue[] | { [key: string]: FormValue };

/** Stripe's bracket encoding: {line_items: [{price: "p"}]} -> line_items[0][price]=p. */
export function formEncode(params: Record<string, FormValue>): string {
  const out = new URLSearchParams();
  const walk = (prefix: string, value: FormValue) => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) value.forEach((v, i) => walk(`${prefix}[${i}]`, v));
    else if (typeof value === "object") { for (const [k, v] of Object.entries(value)) walk(`${prefix}[${k}]`, v); }
    else out.append(prefix, String(value));
  };
  for (const [k, v] of Object.entries(params)) walk(k, v);
  return out.toString();
}

export class StripeError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export async function stripe<T = Record<string, unknown>>(
  secretKey: string,
  method: "GET" | "POST",
  path: string,
  params: Record<string, FormValue> = {},
  idempotencyKey?: string,
): Promise<T> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${secretKey}`,
    "Content-Type": "application/x-www-form-urlencoded",
  };
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
  const body = formEncode(params);
  const url = `${stripeBase()}/v1${path}${method === "GET" && body ? `?${body}` : ""}`;
  const res = await fetch(url, { method, headers, body: method === "POST" ? body : undefined });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new StripeError(res.status, data?.error?.message ?? `Stripe HTTP ${res.status}`);
  return data as T;
}

/** `STRIPE_API_BASE` points at a local Stripe stand-in for tests; unset means the real API. */
function stripeBase(): string {
  return (Deno.env.get("STRIPE_API_BASE") || "https://api.stripe.com").replace(/\/+$/, "");
}

/** Every subscription of `customer`, any status (follows pagination). */
export async function listSubscriptions(secretKey: string, customer: string): Promise<Subscription[]> {
  const all: Subscription[] = [];
  let startingAfter: string | undefined;
  for (let page = 0; page < 20; page++) {
    const res = await stripe<{ data: Subscription[]; has_more: boolean }>(secretKey, "GET", "/subscriptions", {
      customer,
      status: "all",
      limit: 100,
      starting_after: startingAfter,
    });
    all.push(...res.data);
    if (!res.has_more || res.data.length === 0) return all;
    startingAfter = res.data[res.data.length - 1].id;
  }
  throw new StripeError(500, "Too many subscriptions to list");
}

const encoder = new TextEncoder();

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** `Stripe-Signature` header value for `payload`, as Stripe would send it (tests and local runs). */
export async function signPayload(payload: string, secret: string, timestamp = Math.floor(Date.now() / 1000)) {
  return `t=${timestamp},v1=${await hmacHex(secret, `${timestamp}.${payload}`)}`;
}

/**
 * Checks `t=..,v1=..` against HMAC-SHA256(secret, "t.payload"). Any v1 may match (secret rotation);
 * the timestamp must be within `toleranceSec` of now.
 */
export async function verifyStripeSignature(
  payload: string,
  header: string | null,
  secret: string,
  toleranceSec = 300,
  now = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (!header || !secret) return false;
  let timestamp = NaN;
  const signatures: string[] = [];
  for (const part of header.split(",")) {
    const [k, v] = part.trim().split("=", 2);
    if (k === "t") timestamp = Number(v);
    else if (k === "v1" && v) signatures.push(v);
  }
  if (!Number.isFinite(timestamp) || signatures.length === 0) return false;
  if (Math.abs(now - timestamp) > toleranceSec) return false;
  const expected = await hmacHex(secret, `${timestamp}.${payload}`);
  return signatures.some((s) => timingSafeEqual(s, expected));
}
