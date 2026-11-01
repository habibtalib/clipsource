// POST {interval: "month" | "year"} with the user's JWT -> {url} of a Stripe Checkout session for ClipSource Pro.

import { fail, json, preflight, requireEnv, siteURL } from "../_shared/http.ts";
import { hasBlockingSubscription } from "../_shared/billing.ts";
import { listSubscriptions, stripe } from "../_shared/stripe.ts";
import { ensureProfile, getUser, patchProfile } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  if (req.method !== "POST") return fail(req, 405, "method_not_allowed");

  try {
    const user = await getUser(req);
    if (!user) return fail(req, 401, "not_signed_in");

    const { interval } = await req.json().catch(() => ({}));
    if (interval !== "month" && interval !== "year") return fail(req, 400, "invalid_interval");
    const price = requireEnv(interval === "month" ? "STRIPE_PRICE_MONTH" : "STRIPE_PRICE_YEAR");
    const secret = requireEnv("STRIPE_SECRET_KEY");

    const profile = await ensureProfile(user.id);
    let customer = profile.stripe_customer_id;
    // One subscription per customer: refuse while one is active, trialing or past due (manage it in the portal).
    if (customer && hasBlockingSubscription(await listSubscriptions(secret, customer))) {
      return fail(req, 409, "already_subscribed");
    }

    if (!customer) {
      const created = await stripe<{ id: string }>(secret, "POST", "/customers", {
        email: user.email,
        metadata: { user_id: user.id },
      }, `clipsource-customer-${user.id}`);
      customer = created.id;
      await patchProfile("user_id", user.id, { stripe_customer_id: customer });
    }

    const site = siteURL();
    const session = await stripe<{ url: string }>(secret, "POST", "/checkout/sessions", {
      mode: "subscription",
      customer,
      client_reference_id: user.id,
      line_items: [{ price, quantity: 1 }],
      subscription_data: { metadata: { user_id: user.id } },
      metadata: { user_id: user.id },
      allow_promotion_codes: true,
      success_url: `${site}/account?checkout=success`,
      cancel_url: `${site}/account`,
    });
    return json(req, { url: session.url });
  } catch (error) {
    console.error("billing-checkout:", error instanceof Error ? error.message : error);
    return fail(req, 500, "checkout_failed");
  }
});
