// POST with the user's JWT -> {url} of a Stripe Billing Portal session (change plan, cancel, invoices).

import { fail, json, preflight, requireEnv, siteURL } from "../_shared/http.ts";
import { stripe } from "../_shared/stripe.ts";
import { getProfile, getUser } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  if (req.method !== "POST") return fail(req, 405, "method_not_allowed");

  try {
    const user = await getUser(req);
    if (!user) return fail(req, 401, "not_signed_in");

    const profile = await getProfile(user.id);
    if (!profile?.stripe_customer_id) return fail(req, 404, "no_billing_account");

    const session = await stripe<{ url: string }>(requireEnv("STRIPE_SECRET_KEY"), "POST", "/billing_portal/sessions", {
      customer: profile.stripe_customer_id,
      return_url: `${siteURL()}/account`,
    });
    return json(req, { url: session.url });
  } catch (error) {
    console.error("billing-portal:", error instanceof Error ? error.message : error);
    return fail(req, 500, "portal_failed");
  }
});
