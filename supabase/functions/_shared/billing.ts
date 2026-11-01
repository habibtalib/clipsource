// Stripe billing logic, kept pure so it is unit-tested without Stripe or a database.
// The plan is never taken from a single event: the webhook lists ALL of the customer's subscriptions and
// aggregates them, so cancelling one of two subscriptions, or events arriving out of order, cannot downgrade
// a paying user.

import { isUUID } from "./supabase.ts";

export interface StripeEvent {
  id?: string;
  type: string;
  /** Seconds since 1970, when Stripe created the event. */
  created?: number;
  // Stripe objects are only read field by field and every field is checked before use.
  // deno-lint-ignore no-explicit-any
  data: { object: Record<string, any> };
}

/** The fields of a Stripe subscription that matter here. */
export interface Subscription {
  id?: string;
  status: string;
  created?: number;
  current_period_end?: number;
  items?: { data?: { current_period_end?: number }[] };
}

export interface ProfilePatch {
  plan: "free" | "pro";
  subscription_status: string | null;
  current_period_end: string | null;
  stripe_customer_id: string;
  stripe_event_at?: string;
}

/** Which profile an event concerns (by user ID first, then by Stripe customer) and its ordering guard. */
export interface EventTarget {
  userId?: string;
  customerId: string;
  /** Apply only if the profile's stripe_event_at is null or not later than this (ISO); unset = always apply. */
  eventAt?: string;
  /** Subscription events move stripe_event_at forward; checkout events only respect it. */
  advancesEventAt: boolean;
}

export const HANDLED_EVENTS = [
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
];

/** Statuses that block a new checkout: the customer already pays, or owes, for a subscription. */
export const BLOCKING_STATUSES = ["active", "trialing", "past_due"];

/** Pro while the subscription is in good standing; everything else (past_due, canceled, unpaid, ...) is Free. */
export function planForStatus(status: string | null | undefined): "free" | "pro" {
  return status === "active" || status === "trialing" ? "pro" : "free";
}

function id(value: unknown): string | undefined {
  if (typeof value === "string" && value) return value;
  if (value && typeof value === "object" && typeof (value as { id?: unknown }).id === "string") {
    return (value as { id: string }).id;
  }
  return undefined;
}

function isoFromEpoch(value: unknown): string | null {
  return typeof value === "number" && Number.isFinite(value) ? new Date(value * 1000).toISOString() : null;
}

/** Newer API versions moved current_period_end from the subscription onto its items. */
export function periodEnd(sub: Subscription): number | undefined {
  return sub.current_period_end ?? sub.items?.data?.[0]?.current_period_end;
}

// Which non-Pro subscription to report when none is in good standing (lower = more relevant).
const STATUS_RANK: Record<string, number> = {
  past_due: 0,
  unpaid: 1,
  incomplete: 2,
  paused: 3,
  canceled: 4,
  incomplete_expired: 5,
};

/**
 * Plan, status and period end from all of a customer's subscriptions. Pro if any is active or trialing
 * (the one ending last is reported). Otherwise the most relevant other status, newest first.
 */
export function aggregateSubscriptions(
  subs: Subscription[],
): { plan: "free" | "pro"; subscription_status: string | null; current_period_end: string | null } {
  const good = subs.filter((s) => planForStatus(s.status) === "pro");
  if (good.length > 0) {
    const best = good.reduce((a, b) => ((periodEnd(b) ?? 0) > (periodEnd(a) ?? 0) ? b : a));
    return { plan: "pro", subscription_status: best.status, current_period_end: isoFromEpoch(periodEnd(best)) };
  }
  if (subs.length === 0) return { plan: "free", subscription_status: null, current_period_end: null };
  const rank = (s: Subscription) => STATUS_RANK[s.status] ?? 9;
  const best = [...subs].sort((a, b) => rank(a) - rank(b) || (b.created ?? 0) - (a.created ?? 0))[0];
  return { plan: "free", subscription_status: best.status, current_period_end: isoFromEpoch(periodEnd(best)) };
}

/** True if a new checkout must be refused (409 already_subscribed). */
export function hasBlockingSubscription(subs: Subscription[]): boolean {
  return subs.some((s) => BLOCKING_STATUSES.includes(s.status));
}

/** Null for events that do not concern a profile (or name no customer to look up). */
export function eventTarget(event: StripeEvent): EventTarget | null {
  const obj = event.data?.object ?? {};
  const eventAt = isoFromEpoch(event.created) ?? undefined;
  switch (event.type) {
    case "checkout.session.completed": {
      if (obj.mode !== "subscription") return null;
      const customerId = id(obj.customer);
      if (!customerId) return null;
      const userId = [obj.client_reference_id, obj.metadata?.user_id].find(isUUID);
      return { userId, customerId, eventAt, advancesEventAt: false };
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const customerId = id(obj.customer);
      if (!customerId) return null;
      const userId = isUUID(obj.metadata?.user_id) ? obj.metadata.user_id : undefined;
      return { userId, customerId, eventAt, advancesEventAt: eventAt !== undefined };
    }
    default:
      return null;
  }
}

/** The profiles update for `target`, given the customer's current subscriptions. */
export function profilePatch(target: EventTarget, subs: Subscription[]): ProfilePatch {
  const patch: ProfilePatch = { ...aggregateSubscriptions(subs), stripe_customer_id: target.customerId };
  if (target.advancesEventAt && target.eventAt) patch.stripe_event_at = target.eventAt;
  return patch;
}
