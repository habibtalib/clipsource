// Stripe webhook (deployed with verify_jwt = false; authenticity comes from the Stripe-Signature header).
// Keeps profiles.plan / subscription_status / current_period_end in step with the subscription.

import { eventTarget, profilePatch, type StripeEvent } from "../_shared/billing.ts";
import { requireEnv } from "../_shared/http.ts";
import { listSubscriptions, verifyStripeSignature } from "../_shared/stripe.ts";
import { patchProfile } from "../_shared/supabase.ts";

const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const payload = await req.text();
  const valid = await verifyStripeSignature(
    payload,
    req.headers.get("Stripe-Signature"),
    requireEnv("STRIPE_WEBHOOK_SECRET"),
  );
  if (!valid) return reply(400, { error: "invalid_signature" });

  let event: StripeEvent;
  try {
    event = JSON.parse(payload);
  } catch {
    return reply(400, { error: "invalid_json" });
  }

  const target = eventTarget(event);
  if (!target) return reply(200, { received: true, ignored: event.type });

  try {
    // The plan comes from all of the customer's subscriptions as they are now, not from this event alone.
    const subs = await listSubscriptions(requireEnv("STRIPE_SECRET_KEY"), target.customerId);
    const patch = profilePatch(target, subs);
    let changed = 0;
    if (target.userId) changed = await patchProfile("user_id", target.userId, patch, target.eventAt);
    if (changed === 0) changed = await patchProfile("stripe_customer_id", target.customerId, patch, target.eventAt);
    // 200 either way: retrying cannot help a stale event or an unknown customer.
    if (changed === 0) {
      console.warn(`stripe-webhook: no profile, or a newer event already applied: ${event.type} ${event.id ?? ""}`);
    }
    return reply(200, { received: true, updated: changed });
  } catch (error) {
    // 500 makes Stripe retry later.
    console.error("stripe-webhook:", error instanceof Error ? error.message : error);
    return reply(500, { error: "update_failed" });
  }
});
