// deno test supabase/functions — no network, no Stripe account.

import { formEncode, signPayload, verifyStripeSignature } from "./stripe.ts";
import { allowedOrigin } from "./http.ts";

function assert(condition: unknown, message = "assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

const secret = "whsec_test_local_only";
const payload = JSON.stringify({ id: "evt_1", type: "customer.subscription.updated" });
const now = 1_793_527_200;

Deno.test("accepts a signature made with the secret", async () => {
  assert(await verifyStripeSignature(payload, await signPayload(payload, secret, now), secret, 300, now));
});

Deno.test("matches Stripe's documented scheme (HMAC-SHA256 hex of 't.payload')", async () => {
  // Independently computed: printf '1793527200.{"a":1}' | openssl dgst -sha256 -hmac whsec_test_local_only
  const header = "t=1793527200,v1=f88b32e4e129555845af606c8a11964b4f8c657447d01319a4962ebe08ae8f00";
  assert(await signPayload('{"a":1}', secret, now) === header);
  assert(await verifyStripeSignature('{"a":1}', header, secret, 300, now));
});

Deno.test("accepts when any of several v1 signatures matches (secret rotation)", async () => {
  const good = (await signPayload(payload, secret, now)).split("v1=")[1];
  const header = `t=${now},v1=${"0".repeat(64)},v1=${good},v0=ignored`;
  assert(await verifyStripeSignature(payload, header, secret, 300, now));
});

Deno.test("rejects tampered payload, wrong secret, stale or future timestamp, junk headers", async () => {
  const header = await signPayload(payload, secret, now);
  assert(!(await verifyStripeSignature(payload + " ", header, secret, 300, now)), "tampered");
  assert(!(await verifyStripeSignature(payload, header, "whsec_other", 300, now)), "wrong secret");
  assert(!(await verifyStripeSignature(payload, header, secret, 300, now + 301)), "stale");
  assert(!(await verifyStripeSignature(payload, header, secret, 300, now - 301)), "future");
  assert(await verifyStripeSignature(payload, header, secret, 300, now + 299), "inside tolerance");
  for (const junk of [null, "", "t=abc,v1=00", `t=${now}`, "v1=00", "garbage"]) {
    assert(!(await verifyStripeSignature(payload, junk, secret, 300, now)), `junk ${junk}`);
  }
  assert(!(await verifyStripeSignature(payload, header, "", 300, now)), "empty secret");
});

Deno.test("formEncode uses Stripe bracket notation and skips null/undefined", () => {
  const body = formEncode({
    mode: "subscription",
    line_items: [{ price: "price_1", quantity: 1 }],
    subscription_data: { metadata: { user_id: "u" } },
    email: undefined,
    allow_promotion_codes: true,
  });
  const params = new URLSearchParams(body);
  assert(params.get("line_items[0][price]") === "price_1");
  assert(params.get("line_items[0][quantity]") === "1");
  assert(params.get("subscription_data[metadata][user_id]") === "u");
  assert(params.get("allow_promotion_codes") === "true");
  assert(!params.has("email"));
});

Deno.test("CORS: production SITE_URL allows only itself; localhost only when local or ALLOW_LOCALHOST", () => {
  const site = "https://clipsource.app";
  assert(allowedOrigin("https://clipsource.app", site) === "https://clipsource.app");
  assert(allowedOrigin("http://localhost:8000", site) === null, "localhost blocked in production");
  assert(allowedOrigin("http://127.0.0.1:3000", site) === null);
  assert(allowedOrigin("http://localhost:8000", site, true) === "http://localhost:8000", "ALLOW_LOCALHOST=1");
  assert(allowedOrigin("http://127.0.0.1:3000", "http://localhost:8000") === "http://127.0.0.1:3000", "local SITE_URL");
  assert(allowedOrigin("https://evil.example", site, true) === null);
  assert(allowedOrigin("https://clipsource.app.evil.example", site) === null);
  assert(allowedOrigin("http://localhost.evil.example", site, true) === null);
  assert(allowedOrigin(null, site) === null);
  assert(allowedOrigin("https://clipsource.app", "not a url") === null);
});
