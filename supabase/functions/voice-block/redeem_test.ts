import { assertEquals, assertNotEquals } from "@std/assert";
import {
  call,
  CONFIG,
  harness,
  MemoryVoucherStore,
  OTHER_USER,
  redeemReq,
  tokenFor,
  USER,
  voucher,
  VOUCHER_ID,
} from "./testing/fakes.ts";
import type {
  AttemptBudget,
  RedeemOutcome,
  VoucherStore,
} from "./types.ts";

// POST /voice-block/redeem — the endpoint, and only the endpoint.
//
// What a code is worth, whether it exists, whether it has expired, whether the
// campaign is full and whether the caller has guessed too often are all decided
// by counta.redeem_voucher in one transaction, and they are tested against a
// real database in supabase/tests/redeem_voucher_decisions.sql. Asserting them
// here meant asserting an in-memory re-implementation of the function, which
// stays green when the function changes.
//
// What is left is what this file decides: the HTTP shape of each answer, the
// wording of the refusals, and whether a redemption pays.

/** Answers with whatever the test says the transaction returned. */
class StubVoucherStore implements VoucherStore {
  readonly calls: Array<{ code: string; user_id: string; budget: AttemptBudget }> =
    [];
  readonly credited: string[] = [];

  constructor(private readonly outcome: RedeemOutcome) {}

  redeem(
    code: string,
    userId: string,
    budget: AttemptBudget,
  ): Promise<RedeemOutcome> {
    this.calls.push({ code, user_id: userId, budget });
    return Promise.resolve(this.outcome);
  }

  markCredited(redemptionId: string): Promise<void> {
    this.credited.push(redemptionId);
    return Promise.resolve();
  }
}

Deno.test("redeem: a live code grants credits and records the redemption", async () => {
  const h = harness({ campaigns: [voucher()] });

  const { status, body } = await call(h.deps, redeemReq());

  assertEquals(status, 200);
  assertEquals(body, { redeemed: true, credits: 50, balance: 70 });
  assertEquals(h.vouchers.redemptions.length, 1);
  assertEquals(h.vouchers.vouchers[0].redeemed_count, 1);

  // 12.11, in the shape a block grant logs.
  const logged = h.logs.find((l) => l.event === "voucher_redeemed");
  assertEquals(logged?.fields.user_id, USER);
  assertEquals(logged?.fields.voucher_id, VOUCHER_ID);
  assertEquals(logged?.fields.credits, 50);
  assertEquals(logged?.fields.first_redemption, true);
  assertEquals(logged?.fields.granted, true);
});

Deno.test("redeem: the code and the configured budget are what the transaction is asked for", async () => {
  // Trimming is the endpoint's job; folding the case is the function's, through
  // the unique index on upper(code). And the guess budget is configuration, so
  // it travels with the call rather than being hard-coded in the SQL.
  const vouchers = new StubVoucherStore({ outcome: "not_found" });
  const h = harness({ vouchers });

  await call(h.deps, redeemReq({ code: "  spring24 " }));

  assertEquals(vouchers.calls, [{
    code: "spring24",
    user_id: USER,
    budget: {
      windowMinutes: CONFIG.voucherAttemptWindowMinutes,
      maxAttempts: CONFIG.voucherAttemptMax,
    },
  }]);
});

Deno.test("redeem: every refusal the transaction returns has its own answer", async () => {
  // 12.6: unknown and disabled are already one outcome by the time they reach
  // here, so there is nothing left to leak. 12.7: expiry and exhaustion do get
  // their own wording — they reach a user holding a real code, and telling that
  // user their code is fake is worse than the little the distinction gives away.
  const cases: Array<
    { outcome: RedeemOutcome; status: number; body: Record<string, unknown> }
  > = [
    {
      outcome: { outcome: "not_found" },
      status: 404,
      body: { error: "voucher_invalid" },
    },
    {
      outcome: { outcome: "expired" },
      status: 409,
      body: { error: "voucher_expired" },
    },
    {
      outcome: { outcome: "exhausted" },
      status: 409,
      body: { error: "voucher_exhausted" },
    },
  ];

  for (const { outcome, status, body } of cases) {
    const h = harness({ vouchers: new StubVoucherStore(outcome) });
    const res = await call(h.deps, redeemReq());
    assertEquals(res.status, status, outcome.outcome);
    assertEquals(res.body, body, outcome.outcome);
    // Nothing was paid for a refusal, whichever one it was.
    assertEquals(h.balance.calls.length, 0, outcome.outcome);
    const refused = h.logs.find((l) => l.event === "voucher_refused");
    assertEquals(refused?.fields.outcome, outcome.outcome);
  }
});

Deno.test("redeem: too many guesses is the same 429 the other budgets answer", async () => {
  const h = harness({
    vouchers: new StubVoucherStore({
      outcome: "too_many_attempts",
      attempts: 7,
      retry_after_seconds: 900,
    }),
  });

  const { status, body, headers } = await call(h.deps, redeemReq());

  assertEquals(status, 429);
  // One vocabulary for all three budgets, and the hint in both places the
  // client might look (respond.ts).
  assertEquals(body, { error: "rate_limited", retry_after_seconds: 900 });
  assertEquals(headers.get("Retry-After"), "900");
  assertEquals(h.balance.calls.length, 0);
  const logged = h.logs.find((l) => l.event === "voucher_rate_limited");
  assertEquals(logged?.fields.attempts, 7);
});

Deno.test("redeem: the same user redeeming again is told so and paid once", async () => {
  const h = harness({ campaigns: [voucher()] });
  await call(h.deps, redeemReq());

  const again = await call(h.deps, redeemReq());

  // 12.5: the original redemption is reported, and nothing moves. No balance
  // either — it is echoed only when it changed, as a release reports a refund.
  assertEquals(again.status, 200);
  assertEquals(again.body, {
    redeemed: false,
    reason: "already_redeemed",
    credits: 50,
  });
  assertEquals(h.balance.balances.get(USER), 70);
  assertEquals(h.balance.calls.filter((c) => c.op === "grant").length, 1);
  assertEquals(h.vouchers.redemptions.length, 1);
  assertEquals(h.vouchers.vouchers[0].redeemed_count, 1);
});

Deno.test("redeem: a repeat pays nothing once the ledger has forgotten the key", async () => {
  const h = harness({ campaigns: [voucher()] });
  assertEquals((await call(h.deps, redeemReq())).body.redeemed, true);
  assertEquals(h.balance.balances.get(USER), 70);

  // Days later. RevenueCat's Idempotency-Key retention is a bounded window,
  // and "this voucher pays out once" must not rest on it: with the keys gone,
  // a re-issued grant is a second payment, and nothing counts the repeats
  // because the success path records no rate-limit attempt.
  h.balance.expireIdempotencyKeys();

  for (let i = 0; i < 3; i++) {
    const again = await call(h.deps, redeemReq());
    assertEquals(again.status, 200, `repeat ${i}`);
    assertEquals(again.body, {
      redeemed: false,
      reason: "already_redeemed",
      credits: 50,
    });
  }

  assertEquals(h.balance.balances.get(USER), 70);
  assertEquals(h.balance.calls.filter((c) => c.op === "grant").length, 1);
  assertEquals(h.vouchers.redemptions.length, 1);
  assertEquals(h.vouchers.vouchers[0].redeemed_count, 1);
});

Deno.test("redeem: a ledger failure completes on retry without paying twice", async () => {
  const h = harness({ campaigns: [voucher()] });
  h.balance.failGrants = 1;

  const failed = await call(h.deps, redeemReq());
  assertEquals(failed.status, 503);
  assertEquals(failed.body, { error: "provider_unavailable" });
  // The redemption row and the claimed slot are already there, which is what
  // lets the retry re-issue the *same* keyed grant instead of a second one.
  assertEquals(h.vouchers.redemptions.length, 1);
  assertEquals(h.vouchers.vouchers[0].redeemed_count, 1);
  assertEquals(h.balance.balances.get(USER), undefined);

  const retried = await call(h.deps, redeemReq());
  assertEquals(retried.status, 200);
  assertEquals(retried.body, {
    redeemed: false,
    reason: "already_redeemed",
    credits: 50,
    balance: 70,
  });
  assertEquals(h.vouchers.redemptions[0].credited, true);

  // And a third attempt does not credit again — not even with the ledger's
  // idempotency keys gone, because the row now says the payout landed.
  h.balance.expireIdempotencyKeys();
  const third = await call(h.deps, redeemReq());
  assertEquals(third.body, {
    redeemed: false,
    reason: "already_redeemed",
    credits: 50,
  });
  assertEquals(h.balance.balances.get(USER), 70);
  assertEquals(h.vouchers.redemptions.length, 1);
});

Deno.test("redeem: a payout that lands but is not recorded is re-issued, not doubled", async () => {
  // markCredited is the one write after the money moves. If it fails the row
  // stays unconfirmed, so the retry re-issues the *same* keyed grant — which
  // the ledger applies once — rather than the endpoint assuming a payout it
  // cannot see.
  const vouchers = new MemoryVoucherStore([voucher()]);
  vouchers.failCredited = 1;
  const h = harness({ vouchers });

  const failed = await call(h.deps, redeemReq());
  assertEquals(failed.status, 500);
  assertEquals(vouchers.redemptions[0].credited, false);

  const retried = await call(h.deps, redeemReq());
  assertEquals(retried.body, {
    redeemed: false,
    reason: "already_redeemed",
    credits: 50,
    balance: 70,
  });
  assertEquals(vouchers.redemptions[0].credited, true);
  assertEquals(h.balance.balances.get(USER), 70);
});

Deno.test("redeem: a malformed code is 400 and never reaches the transaction", async () => {
  const h = harness({ campaigns: [voucher()] });

  for (const body of [{}, { code: "" }, { code: "   " }, { code: 42 }, { code: "x".repeat(65) }]) {
    const res = await call(h.deps, redeemReq(body));
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals(res.body, { error: "invalid_request" });
  }
  // Refused before the round trip, so it costs no guess either: the attempt is
  // recorded by the transaction, and the transaction never ran.
  assertEquals(h.vouchers.calls.length, 0);
  assertEquals(h.balance.calls.length, 0);
});

Deno.test("redeem: unauthenticated is 401 and touches nothing", async () => {
  const h = harness({ campaigns: [voucher()] });
  const anon = await call(h.deps, redeemReq(undefined, null));
  assertEquals(anon.status, 401);
  assertEquals(anon.body, { error: "unauthenticated" });
  assertEquals(h.vouchers.calls.length, 0);
  assertEquals(h.vouchers.redemptions.length, 0);
});

Deno.test("redeem: two users of one campaign get distinct keyed grants", async () => {
  const h = harness({ campaigns: [voucher()] });

  await call(h.deps, redeemReq());
  await call(h.deps, redeemReq(undefined, tokenFor(OTHER_USER)));

  const grants = h.balance.calls.filter((c) => c.op === "grant");
  assertEquals(grants.length, 2);
  // Keyed on the redemption, not on the code: a shared key would make the
  // second user's payout a duplicate of the first and silently drop it.
  assertNotEquals(grants[0].blockId, grants[1].blockId);
  assertEquals(h.balance.balances.get(USER), 70);
  assertEquals(h.balance.balances.get(OTHER_USER), 70);
});
