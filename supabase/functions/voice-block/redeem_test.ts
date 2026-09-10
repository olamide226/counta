import { assertEquals, assertNotEquals } from "@std/assert";
import { handleVoiceBlock } from "./handler.ts";
import {
  CONFIG,
  harness,
  OTHER_USER,
  redeemReq,
  tokenFor,
  USER,
  voucher,
  VOUCHER_ID,
} from "./testing/fakes.ts";
import { Deps } from "./types.ts";

// POST /voice-block/redeem — requirement 12. The two rules that bound the
// payout (one redemption per user, the campaign cap) are database constraints
// and are exercised against a real Postgres by the migration; what is tested
// here is the endpoint built on top of them.

async function call(deps: Deps, req: Request) {
  const res = await handleVoiceBlock(req, deps);
  return { status: res.status, body: await res.json() };
}

const THIRD_USER = "99999999-9999-4999-8999-999999999999";

Deno.test("redeem: a live code grants credits and records the redemption", async () => {
  const h = harness({ campaigns: [voucher()] });

  const { status, body } = await call(h.deps, redeemReq());

  assertEquals(status, 200);
  assertEquals(body, { redeemed: true, credits: 50, balance: 70 });
  assertEquals(h.vouchers.redemptions.length, 1);
  assertEquals(h.vouchers.vouchers[0].redeemed_count, 1);
  assertEquals(h.vouchers.attempts.length, 0);

  // 12.11, in the shape a block grant logs.
  const logged = h.logs.find((l) => l.event === "voucher_redeemed");
  assertEquals(logged?.fields.user_id, USER);
  assertEquals(logged?.fields.voucher_id, VOUCHER_ID);
  assertEquals(logged?.fields.credits, 50);
  assertEquals(logged?.fields.redeemed_at, "2026-09-07T12:00:00.000Z");
});

Deno.test("redeem: codes are matched without regard to case", async () => {
  const h = harness({ campaigns: [voucher()] });
  const { status, body } = await call(h.deps, redeemReq({ code: "  spring24 " }));
  assertEquals(status, 200);
  assertEquals(body.redeemed, true);
});

Deno.test("redeem: the same user redeeming again is told so and paid once", async () => {
  const h = harness({ campaigns: [voucher()] });
  await call(h.deps, redeemReq());

  const again = await call(h.deps, redeemReq());

  // 12.5: the original redemption is reported, and the keyed grant is
  // re-issued rather than doubled — so the balance does not move.
  assertEquals(again.status, 200);
  assertEquals(again.body, {
    redeemed: false,
    reason: "already_redeemed",
    credits: 50,
    balance: 70,
  });
  assertEquals(h.balance.balances.get(USER), 70);
  assertEquals(h.vouchers.redemptions.length, 1);
  // A repeat is not a failed attempt, so it does not eat the guess budget.
  assertEquals(h.vouchers.vouchers[0].redeemed_count, 1);
  assertEquals(h.vouchers.attempts.length, 0);
});

Deno.test("redeem: many users share a campaign up to its cap", async () => {
  const h = harness({ campaigns: [voucher()] }); // max_redemptions: 2

  assertEquals((await call(h.deps, redeemReq())).status, 200);
  assertEquals(
    (await call(h.deps, redeemReq(undefined, tokenFor(OTHER_USER)))).status,
    200,
  );

  const full = await call(h.deps, redeemReq(undefined, tokenFor(THIRD_USER)));

  // 12.7: a user holding a real code is told the campaign is full, not that
  // their code is fake.
  assertEquals(full.status, 409);
  assertEquals(full.body, { error: "voucher_exhausted" });
  assertEquals(h.vouchers.redemptions.length, 2);
  assertEquals(h.vouchers.vouchers[0].redeemed_count, 2);
  // Nothing moved for the caller who arrived too late.
  assertEquals(h.balance.balances.get(THIRD_USER), undefined);
  // The refusal is a failed attempt and is counted as one (12.8).
  assertEquals(h.vouchers.attempts.map((a) => a.user_id), [THIRD_USER]);
});

Deno.test("redeem: an expired code is refused and says which of the two applied", async () => {
  const h = harness({
    campaigns: [voucher({ expires_at: "2026-09-07T11:59:59.000Z" })],
  });

  const { status, body } = await call(h.deps, redeemReq());

  assertEquals(status, 409);
  assertEquals(body, { error: "voucher_expired" });
  assertEquals(h.vouchers.redemptions.length, 0);
  assertEquals(h.balance.calls.length, 0);
  assertEquals(h.vouchers.attempts.length, 1);
});

Deno.test("redeem: a null expiry never expires", async () => {
  const h = harness({ campaigns: [voucher({ expires_at: null })] });
  h.clock.now = new Date("2099-01-01T00:00:00.000Z");
  assertEquals((await call(h.deps, redeemReq())).status, 200);
});

Deno.test("redeem: an unknown and a disabled code are the same answer", async () => {
  const h = harness({ campaigns: [voucher({ code: "RETIRED", enabled: false })] });

  const unknown = await call(h.deps, redeemReq({ code: "NOSUCHCODE" }));
  const disabled = await call(h.deps, redeemReq({ code: "RETIRED" }));

  // 12.6: distinguishing them would turn the endpoint into an oracle for
  // discovering which campaigns are live.
  assertEquals(unknown.status, disabled.status);
  assertEquals(unknown.body, disabled.body);
  assertEquals(unknown.status, 404);
  assertEquals(unknown.body, { error: "voucher_invalid" });
  assertEquals(h.vouchers.redemptions.length, 0);
  assertEquals(h.balance.calls.length, 0);
  // Both cost a guess.
  assertEquals(h.vouchers.attempts.length, 2);
  // And neither log distinguishes them either.
  const refusals = h.logs.filter((l) => l.event === "voucher_refused");
  assertEquals(refusals[0].fields.outcome, refusals[1].fields.outcome);
});

Deno.test("redeem: failed attempts are rate limited, and the block can lift", async () => {
  const h = harness({ campaigns: [voucher()] });

  for (let i = 0; i < CONFIG.voucherAttemptMax; i++) {
    const res = await call(h.deps, redeemReq({ code: `GUESS${i}` }));
    assertEquals(res.status, 404, `guess ${i}`);
  }

  const limited = await call(h.deps, redeemReq({ code: "GUESS-AGAIN" }));
  assertEquals(limited.status, 429);
  assertEquals(limited.body, {
    error: "too_many_attempts",
    retry_after_seconds: CONFIG.voucherAttemptWindowMinutes * 60,
  });
  // A refused refusal records nothing: counting it would let the window renew
  // itself for as long as the caller kept knocking, so it could never lift.
  assertEquals(h.vouchers.attempts.length, CONFIG.voucherAttemptMax);
  // And a real code is not redeemable while the block stands.
  assertEquals((await call(h.deps, redeemReq())).status, 429);
  assertEquals(h.vouchers.redemptions.length, 0);

  h.clock.now = new Date(
    h.clock.now.getTime() + CONFIG.voucherAttemptWindowMinutes * 60_000 + 1000,
  );
  assertEquals((await call(h.deps, redeemReq())).status, 200);
});

Deno.test("redeem: the retry-after counts from the oldest attempt in the window", async () => {
  const h = harness();
  for (let i = 0; i < CONFIG.voucherAttemptMax; i++) {
    await call(h.deps, redeemReq({ code: `GUESS${i}` }));
    h.clock.now = new Date(h.clock.now.getTime() + 60_000);
  }

  const limited = await call(h.deps, redeemReq({ code: "GUESS-AGAIN" }));
  assertEquals(limited.status, 429);
  // Three minutes have passed since the first of three attempts, so the
  // window clears three minutes early.
  assertEquals(
    limited.body.retry_after_seconds,
    CONFIG.voucherAttemptWindowMinutes * 60 - CONFIG.voucherAttemptMax * 60,
  );
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

  // And a third attempt does not credit again.
  assertEquals((await call(h.deps, redeemReq())).body.balance, 70);
  assertEquals(h.balance.balances.get(USER), 70);
  assertEquals(h.vouchers.redemptions.length, 1);
});

Deno.test("redeem: the claimed slots and the redemption rows never disagree", async () => {
  // The invariant counta.redeem_voucher exists to hold. A leaked slot
  // under-grants a campaign; a redemption with no slot behind it lets the cap
  // be exceeded. Every outcome — success, repeat, exhaustion, refusal, a
  // ledger failure part way through — must leave the two equal.
  const h = harness({ campaigns: [voucher({ max_redemptions: 2 })] });
  const campaign = h.vouchers.vouchers[0];
  const agree = () =>
    assertEquals(campaign.redeemed_count, h.vouchers.redemptions.length);

  agree();
  await call(h.deps, redeemReq());
  agree();
  await call(h.deps, redeemReq()); // repeat by the same user
  agree();
  h.balance.failGrants = 1;
  await call(h.deps, redeemReq(undefined, tokenFor(OTHER_USER))); // 503
  agree();
  await call(h.deps, redeemReq(undefined, tokenFor(OTHER_USER))); // completes
  agree();
  await call(h.deps, redeemReq(undefined, tokenFor(THIRD_USER))); // exhausted
  agree();
  await call(h.deps, redeemReq({ code: "NOSUCHCODE" }, tokenFor(THIRD_USER)));
  agree();

  assertEquals(campaign.redeemed_count, 2);
  assertEquals(campaign.redeemed_count <= campaign.max_redemptions, true);
});

Deno.test("redeem: a malformed code is 400 and costs no guess", async () => {
  const h = harness({ campaigns: [voucher()] });

  for (const body of [{}, { code: "" }, { code: "   " }, { code: 42 }, { code: "x".repeat(65) }]) {
    const res = await call(h.deps, redeemReq(body));
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals(res.body, { error: "invalid_request" });
  }
  assertEquals(h.vouchers.attempts.length, 0);
  assertEquals(h.balance.calls.length, 0);
});

Deno.test("redeem: unauthenticated is 401 and touches nothing", async () => {
  const h = harness({ campaigns: [voucher()] });
  const anon = await call(h.deps, redeemReq(undefined, null));
  assertEquals(anon.status, 401);
  assertEquals(anon.body, { error: "unauthenticated" });
  assertEquals(h.vouchers.attempts.length, 0);
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
