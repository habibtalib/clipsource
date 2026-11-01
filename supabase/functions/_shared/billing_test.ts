import {
  aggregateSubscriptions,
  eventTarget,
  hasBlockingSubscription,
  planForStatus,
  profilePatch,
  type Subscription,
} from "./billing.ts";

function assertEquals(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e}\n     got ${a}`);
}

const USER = "8b288d3d-0c80-4c51-a923-6b76df574ddd";
const T = 1_793_527_200; // 2026-11-01T10:00:00Z
const iso = (t: number) => new Date(t * 1000).toISOString();

Deno.test("planForStatus: only active and trialing are Pro", () => {
  for (const s of ["active", "trialing"]) assertEquals(planForStatus(s), "pro");
  for (const s of ["past_due", "unpaid", "canceled", "incomplete", "incomplete_expired", "paused", null, undefined]) {
    assertEquals(planForStatus(s), "free");
  }
});

Deno.test("aggregate: no subscriptions -> free, no status", () => {
  assertEquals(aggregateSubscriptions([]), { plan: "free", subscription_status: null, current_period_end: null });
});

Deno.test("aggregate: one active among canceled ones -> pro (a single canceled event cannot downgrade)", () => {
  const subs: Subscription[] = [
    { id: "a", status: "canceled", created: T + 50, current_period_end: T + 10 },
    { id: "b", status: "active", created: T, current_period_end: T + 100 },
    { id: "c", status: "incomplete_expired", created: T + 60 },
  ];
  assertEquals(aggregateSubscriptions(subs), {
    plan: "pro",
    subscription_status: "active",
    current_period_end: iso(T + 100),
  });
});

Deno.test("aggregate: several good ones -> pro with the latest period end; items-level period end is read", () => {
  const subs: Subscription[] = [
    { status: "trialing", items: { data: [{ current_period_end: T + 500 }] } },
    { status: "active", current_period_end: T + 100 },
  ];
  assertEquals(aggregateSubscriptions(subs), {
    plan: "pro",
    subscription_status: "trialing",
    current_period_end: iso(T + 500),
  });
});

Deno.test("aggregate: none good -> free, most relevant status (past_due before canceled), newest first", () => {
  assertEquals(
    aggregateSubscriptions([
      { status: "canceled", created: T + 9, current_period_end: T + 1 },
      { status: "past_due", created: T, current_period_end: T + 2 },
    ]),
    { plan: "free", subscription_status: "past_due", current_period_end: iso(T + 2) },
  );
  assertEquals(
    aggregateSubscriptions([
      { status: "canceled", created: T, current_period_end: T + 1 },
      { status: "canceled", created: T + 5, current_period_end: T + 3 },
    ]),
    { plan: "free", subscription_status: "canceled", current_period_end: iso(T + 3) },
  );
});

Deno.test("hasBlockingSubscription: active, trialing and past_due block a new checkout", () => {
  for (const s of ["active", "trialing", "past_due"]) assertEquals(hasBlockingSubscription([{ status: s }]), true);
  for (const s of ["canceled", "incomplete", "incomplete_expired", "unpaid", "paused"]) {
    assertEquals(hasBlockingSubscription([{ status: s }]), false);
  }
  assertEquals(hasBlockingSubscription([]), false);
});

Deno.test("eventTarget: subscription events carry user, customer and an advancing ordering guard", () => {
  assertEquals(
    eventTarget({
      type: "customer.subscription.deleted",
      created: T,
      data: { object: { customer: "cus_1", status: "canceled", metadata: { user_id: USER } } },
    }),
    { userId: USER, customerId: "cus_1", eventAt: iso(T), advancesEventAt: true },
  );
  assertEquals(
    eventTarget({ type: "customer.subscription.updated", data: { object: { customer: { id: "cus_2" } } } }),
    { userId: undefined, customerId: "cus_2", eventAt: undefined, advancesEventAt: false },
  );
});

Deno.test("eventTarget: checkout is guarded but does not advance; non-UUID references are dropped", () => {
  assertEquals(
    eventTarget({
      type: "checkout.session.completed",
      created: T,
      data: { object: { mode: "subscription", client_reference_id: USER, customer: "cus_1" } },
    }),
    { userId: USER, customerId: "cus_1", eventAt: iso(T), advancesEventAt: false },
  );
  assertEquals(
    eventTarget({
      type: "checkout.session.completed",
      data: { object: { mode: "subscription", client_reference_id: "eq.x&plan=pro", customer: "cus_2" } },
    })?.userId,
    undefined,
  );
});

Deno.test("eventTarget: ignores payment checkouts, events without a customer and unrelated events", () => {
  assertEquals(eventTarget({ type: "checkout.session.completed", data: { object: { mode: "payment" } } }), null);
  assertEquals(eventTarget({ type: "customer.subscription.updated", data: { object: { status: "active" } } }), null);
  assertEquals(eventTarget({ type: "invoice.paid", data: { object: { customer: "cus_1" } } }), null);
});

Deno.test("profilePatch: plan from all subscriptions; stripe_event_at only for subscription events", () => {
  const subs: Subscription[] = [{ status: "active", current_period_end: T + 100 }, { status: "canceled" }];
  assertEquals(
    profilePatch({ userId: USER, customerId: "cus_1", eventAt: iso(T), advancesEventAt: true }, subs),
    {
      plan: "pro",
      subscription_status: "active",
      current_period_end: iso(T + 100),
      stripe_customer_id: "cus_1",
      stripe_event_at: iso(T),
    },
  );
  assertEquals(
    profilePatch({ customerId: "cus_1", eventAt: iso(T), advancesEventAt: false }, [{ status: "canceled" }]),
    { plan: "free", subscription_status: "canceled", current_period_end: null, stripe_customer_id: "cus_1" },
  );
});
