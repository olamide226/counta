import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "@std/assert";
import { handleVoiceBlock } from "./handler.ts";
import { RevenueCatBalanceProvider } from "./providers/balance.ts";
import { DeepgramTokenMinter } from "./providers/minter.ts";
import {
  call,
  CONFIG,
  FakeTokenMinter,
  GOOD_TOKEN,
  BALANCE_READ,
  balanceReq,
  grantReq,
  harness,
  jsonResponse,
  MemoryBlockStore,
  recorder,
  releaseReq,
  SESSION,
  USER,
} from "./testing/fakes.ts";
import { ProviderError } from "./types.ts";

const BASE = "http://localhost:54321/functions/v1";
const BLOCK = "33333333-3333-4333-8333-000000000001";
const OTHER_SESSION = "55555555-5555-4555-8555-555555555555";

/** A fresh 429 per attempt: a Response body can only be read once. */
const throttled = (retryAfter?: string) => () =>
  new Response("", {
    status: 429,
    ...(retryAfter ? { headers: { "Retry-After": retryAfter } } : {}),
  });

/** The provider under test, pointed at a scripted fetch. */
function revenueCat(responses: Parameters<typeof recorder>[0], sleeps?: number[]) {
  const { sent, fetchFn } = recorder(responses);
  const provider = new RevenueCatBalanceProvider({
    secretKey: "test",
    projectId: "proj",
    currencyCode: "VOICE",
    fetch: fetchFn,
    sleep: (ms) => {
      sleeps?.push(ms);
      return Promise.resolve();
    },
  });
  return { provider, sent };
}

// ---------------------------------------------------------------------------
// Grant

Deno.test("grant: happy path debits, mints, records and logs", async () => {
  const h = harness();
  const { status, body } = await call(h.deps, grantReq());

  assertEquals(status, 200);
  assertEquals(body.token, "fake-token-1");
  assertEquals(body.block_seconds, 300);
  assertEquals(body.balance_after, 15);
  assertEquals(body.expires_at, "2026-09-07T12:05:00.000Z");
  assertEquals(h.blocks.rows.length, 1);
  assertEquals(h.blocks.rows[0].id, body.block_id);
  assertEquals(h.blocks.rows[0].credits, 5);

  const granted = h.logs.find((l) => l.event === "block_granted");
  assertEquals(granted?.fields.user_id, USER);
  assertEquals(granted?.fields.block_id, body.block_id);
  assertEquals(granted?.fields.credits, 5);
  assertEquals(granted?.fields.granted_at, "2026-09-07T12:00:00.000Z");

  // Debit happened exactly once and before the mint.
  assertEquals(h.balance.calls.map((c) => c.op), ["get", "spend"]);
});

Deno.test("grant: missing or invalid JWT is 401 and touches nothing", async () => {
  const h = harness();
  assertEquals((await call(h.deps, grantReq(undefined, null))).status, 401);
  const bad = await call(h.deps, grantReq(undefined, "nope"));
  assertEquals(bad.status, 401);
  assertEquals(bad.body.error, "unauthenticated");
  assertEquals(h.balance.calls.length, 0);
  assertEquals(h.minter.minted, 0);
});

Deno.test("grant: insufficient balance is 402 with balance and required, no mint", async () => {
  const h = harness({ initialBalance: 2 });
  const { status, body } = await call(h.deps, grantReq());
  assertEquals(status, 402);
  assertEquals(body, { error: "insufficient_credit", balance: 2, required: 5 });
  assertEquals(h.minter.minted, 0);
  assertEquals(h.balance.calls.map((c) => c.op), ["get"]);
});

Deno.test("grant: the same session renewing supersedes its own block", async () => {
  const h = harness();
  const first = await call(h.deps, grantReq());

  // 270 s in = 90% of a 300 s block, the renewal point from req 3.9.
  h.clock.now = new Date("2026-09-07T12:04:30.000Z");
  const renewal = await call(h.deps, grantReq());

  assertEquals(renewal.status, 200);
  assertEquals(h.blocks.rows.length, 2);
  // Exactly one live block survives the renewal (req 3.8).
  assertEquals(h.blocks.rows.filter((r) => !r.reconciled).length, 1);
  assertEquals(h.blocks.rows[0].id, first.body.block_id);
  assertEquals(h.blocks.rows[0].reconciled, true);
  const granted = h.logs.filter((l) => l.event === "block_granted");
  assertEquals(granted[1].fields.renewal_of, first.body.block_id);
});

Deno.test("grant: a different session is 409 even inside the renewal window", async () => {
  const h = harness();
  const first = await call(h.deps, grantReq());

  // Nearly expired, but a second session must never hold a concurrent block:
  // remaining life is not what makes a grant a renewal, identity is.
  h.clock.now = new Date("2026-09-07T12:04:59.000Z");
  const other = await call(
    h.deps,
    grantReq({ session_id: OTHER_SESSION }),
  );

  assertEquals(other.status, 409);
  assertEquals(other.body, {
    error: "block_in_flight",
    expires_at: first.body.expires_at,
  });
  assertEquals(h.blocks.rows.length, 1);
  assertEquals(h.balance.balances.get(USER), 15);
});

Deno.test("grant: concurrent grants cannot both pass the one-live-block rule", async () => {
  const h = harness();

  // Both requests read "no live block" before either inserts; only the unique
  // index can break the tie.
  const [first, second] = await Promise.all([
    call(h.deps, grantReq({ session_id: SESSION })),
    call(h.deps, grantReq({ session_id: OTHER_SESSION })),
  ]);

  assertEquals([first.status, second.status].sort(), [200, 409]);
  assertEquals(h.blocks.rows.filter((r) => !r.reconciled).length, 1);
  // The loser's debit came back, so exactly one block was paid for.
  assertEquals(h.balance.balances.get(USER), 15);
  assertEquals(h.balance.calls.filter((c) => c.op === "refund").length, 1);
});

Deno.test("grant: an abandoned block stops blocking once it expires", async () => {
  const h = harness();
  // A client that was killed mid-block never calls /release, so its row stays
  // unreconciled; without retiring it the unique index would 409 for ever.
  await call(h.deps, grantReq());

  h.clock.now = new Date("2026-09-07T12:10:00.000Z");
  const next = await call(h.deps, grantReq({ session_id: OTHER_SESSION }));

  assertEquals(next.status, 200);
  assertEquals(h.blocks.rows.length, 2);
  assertEquals(h.blocks.rows.filter((r) => !r.reconciled).length, 1);
});

Deno.test("grant: mint failure refunds the debit and returns 503", async () => {
  const minter = new FakeTokenMinter(new ProviderError("unavailable", "deepgram down"));
  const h = harness({ minter });
  const { status, body } = await call(h.deps, grantReq());

  assertEquals(status, 503);
  assertEquals(body, { error: "provider_unavailable" });
  assertEquals(h.balance.balances.get(USER), 20);
  assertEquals(h.balance.calls.map((c) => c.op), ["get", "spend", "refund"]);
  assertEquals(h.blocks.rows.length, 0);
  assertEquals(h.logs.some((l) => l.event === "mint_failed"), true);
});

Deno.test("grant: a failed block insert refunds the debit and returns 503", async () => {
  const blocks = new MemoryBlockStore(new Error("counta.voice_blocks insert: boom"));
  const h = harness({ blocks });
  const { status, body } = await call(h.deps, grantReq());

  assertEquals(status, 503);
  assertEquals(body, { error: "provider_unavailable" });
  // Charged and handed nothing: without a row there is no block_id to return
  // and nothing to /release, so the debit has to come back here.
  assertEquals(h.balance.balances.get(USER), 20);
  assertEquals(h.balance.calls.map((c) => c.op), ["get", "spend", "refund"]);
  assertEquals(blocks.rows.length, 0);
  assertEquals(h.logs.some((l) => l.event === "block_insert_failed"), true);
});

Deno.test("grant: a rate-limited balance read fails fast to 503 without sleeping", async () => {
  const sleeps: number[] = [];
  const { provider, sent } = revenueCat([throttled("60")], sleeps);
  const h = harness({ balance: provider });
  const { status, body } = await call(h.deps, grantReq());

  assertEquals(status, 503);
  assertEquals(body, { error: "provider_unavailable" });
  // The read happens before any money moves, so retrying it only burns the
  // seconds the client's token window has left.
  assertEquals(sent.length, 1);
  assertEquals(sleeps, []);
  assertEquals(h.minter.minted, 0);
});

Deno.test("RevenueCat provider: a write retries a 429 twice with a capped backoff", async () => {
  const sleeps: number[] = [];
  // A minute of Retry-After would outlive the token this request exists to
  // mint, so the backoff must clamp it.
  const { provider, sent } = revenueCat([throttled("60")], sleeps);

  const error = await assertRejects(
    () => provider.spend(USER, BLOCK, 5),
    ProviderError,
  );
  assertEquals(error.reason, "rate_limited");
  assertEquals(sent.length, 3); // 1 try + 2 retries
  assertEquals(sleeps, [2000, 2000]);
});

Deno.test("RevenueCat provider: recovers after a single 429 and parses the balance", async () => {
  const { provider, sent } = revenueCat([
    throttled(),
    jsonResponse({
      object: "list",
      items: [
        { currency_code: "GEMS", balance: 99 },
        { currency_code: "VOICE", balance: 7 },
      ],
    }),
  ]);

  assertEquals(await provider.spend(USER, BLOCK, 5), 7);
  assertEquals(sent.length, 2);
  assertStringIncludes(
    sent[1].url,
    `/projects/proj/customers/${USER}/virtual_currencies/transactions`,
  );
  assertEquals(sent[1].body.adjustments, { VOICE: -5 });
  assertEquals(sent[1].body.reference, `voice-block:${BLOCK}`);
  assertEquals(sent[1].headers["Idempotency-Key"], `voice-block:${BLOCK}`);
  assertEquals(sent[1].headers["Authorization"], "Bearer test");
});

Deno.test("grant: every ledger call for a block is keyed on the block id", async () => {
  const h = harness();
  const { body } = await call(h.deps, grantReq());

  const spend = h.balance.calls.find((c) => c.op === "spend");
  assertEquals(spend?.blockId, body.block_id);

  // A retried mint failure for the same block refunds once, not once per
  // attempt: the debit and the refund share the block's identity, so the
  // ledger can deduplicate them. Keying on `now` made every attempt distinct.
  await h.deps.balance.spend(USER, String(body.block_id), 5);
  await h.deps.balance.spend(USER, String(body.block_id), 5);
  assertEquals(h.balance.balances.get(USER), 15);
});

Deno.test("grant: per-user rate limit returns 429", async () => {
  // Enough credit that the limiter, not the balance, is what stops us.
  const h = harness({ initialBalance: 100 });
  for (let i = 0; i < CONFIG.rateLimitMax; i++) {
    const res = await call(h.deps, grantReq());
    assertEquals(res.status, 200, `grant ${i}`);
    // Reconcile immediately so the next grant is not a 409.
    await call(
      h.deps,
      releaseReq({ block_id: res.body.block_id, streamed_secs: 10, detections: 3 }),
    );
    h.clock.now = new Date(h.clock.now.getTime() + 30_000);
  }

  const limited = await call(h.deps, grantReq());
  assertEquals(limited.status, 429);
  // The window runs from the oldest grant in it, and the hint says so in both
  // places: the header the client reads and the body a JSON-only caller does.
  const elapsed = CONFIG.rateLimitMax * 30;
  const retryAfter = CONFIG.rateLimitWindowMinutes * 60 - elapsed;
  assertEquals(limited.body, {
    error: "rate_limited",
    retry_after_seconds: retryAfter,
  });
  assertEquals(limited.headers.get("Retry-After"), String(retryAfter));

  // Outside the window the limit lifts.
  h.clock.now = new Date(h.clock.now.getTime() + CONFIG.rateLimitWindowMinutes * 60_000);
  assertEquals((await call(h.deps, grantReq())).status, 200);
});

Deno.test("grant: malformed session_id is 400 before any provider call", async () => {
  const h = harness();
  const { status, body } = await call(h.deps, grantReq({ session_id: "abc" }));
  assertEquals(status, 400);
  assertEquals(body.error, "invalid_session_id");
  assertEquals(h.balance.calls.length, 0);
});

Deno.test("Deepgram minter: 429 classifies as rate limited, like RevenueCat's", async () => {
  const minter = new DeepgramTokenMinter({
    apiKey: "master-key",
    fetch: recorder([throttled("3")]).fetchFn,
  });

  const error = await assertRejects(() => minter.mint(30), ProviderError);
  assertEquals(error.reason, "rate_limited");
  assertEquals(error.retryAfterMs, 3000);
});

Deno.test("Deepgram minter: returns the access token from a successful grant", async () => {
  const { sent, fetchFn } = recorder([
    jsonResponse({ access_token: "dg-token", expires_in: 30 }),
  ]);
  const minter = new DeepgramTokenMinter({ apiKey: "master-key", fetch: fetchFn });

  assertEquals(await minter.mint(30), "dg-token");
  assertStringIncludes(sent[0].url, "https://api.deepgram.com/v1/auth/grant");
  assertEquals(sent[0].body, { ttl_seconds: 30 });
});

// ---------------------------------------------------------------------------
// Release

Deno.test("release: within 30 s with zero detections refunds", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());

  h.clock.now = new Date("2026-09-07T12:00:20.000Z");
  const { status, body } = await call(
    h.deps,
    releaseReq({
      block_id: granted.body.block_id,
      streamed_secs: 18,
      detections: 0,
      eligible_for_refund: true,
    }),
  );

  assertEquals(status, 200);
  assertEquals(body, {
    refunded: true,
    balance: 20,
    used_credits: 0,
    refunded_credits: 5,
  });
  const row = h.blocks.rows[0];
  assertEquals(row.reconciled, true);
  assertEquals(row.streamed_secs, 18);
  assertEquals(row.detections, 0);
});

Deno.test("release: a session that counted is charged for the minute it ran", async () => {
  // It was a real session, so the never-started refund does not apply, and
  // the client asserting otherwise changes nothing. It ran ten seconds: one
  // minute is charged and the other four come back.
  const h = harness();
  const granted = await call(h.deps, grantReq());

  h.clock.now = new Date("2026-09-07T12:00:10.000Z");
  const { status, body } = await call(
    h.deps,
    releaseReq({
      block_id: granted.body.block_id,
      streamed_secs: 9,
      detections: 2,
      eligible_for_refund: true,
    }),
  );

  assertEquals(status, 200);
  assertEquals(body, {
    refunded: true,
    balance: 19,
    used_credits: 1,
    refunded_credits: 4,
  });
  assertEquals(h.blocks.rows[0].reconciled, true);
});

Deno.test("release: past the 30 s window a silent session still pays for its minute", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());

  h.clock.now = new Date("2026-09-07T12:00:31.000Z");
  const { body } = await call(
    h.deps,
    releaseReq({
      block_id: granted.body.block_id,
      streamed_secs: 31,
      detections: 0,
      eligible_for_refund: true,
    }),
  );
  // Not the full refund: that is only for a session that never started.
  assertEquals(body, {
    refunded: true,
    balance: 19,
    used_credits: 1,
    refunded_credits: 4,
  });
});

Deno.test("release: a missing detections count does not earn the full refund", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());

  h.clock.now = new Date("2026-09-07T12:00:10.000Z");
  const { status, body } = await call(
    h.deps,
    releaseReq({
      block_id: granted.body.block_id,
      eligible_for_refund: true,
    }),
  );

  assertEquals(status, 200);
  // Omitting the field must not be a way to be refunded in full: no report
  // is not a report of zero. The minute that ran is still charged.
  assertEquals(body.used_credits, 1);
  assertEquals(h.balance.balances.get(USER), 19);
  assertEquals(h.blocks.rows[0].detections, null);
});

Deno.test("release: a detections value that is not a count is 400", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());

  for (const detections of ["0", -1, 1.5, true]) {
    const { status, body } = await call(
      h.deps,
      releaseReq({ block_id: granted.body.block_id, detections }),
    );
    assertEquals(status, 400, `detections=${detections}`);
    assertEquals(body.error, "invalid_detections");
  }
  // Nothing was reconciled or refunded by a rejected report.
  assertEquals(h.blocks.rows[0].reconciled, false);
  assertEquals(h.balance.balances.get(USER), 15);
});

Deno.test("release: is idempotent, a second release never refunds again", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());
  h.clock.now = new Date("2026-09-07T12:00:05.000Z");
  const req = () =>
    releaseReq({ block_id: granted.body.block_id, streamed_secs: 5, detections: 0 });

  assertEquals((await call(h.deps, req())).body, {
    refunded: true,
    balance: 20,
    used_credits: 0,
    refunded_credits: 5,
  });
  assertEquals((await call(h.deps, req())).body, { refunded: false });
});

Deno.test("release: a failed refund leaves a retry able to finish it, exactly once", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());
  h.clock.now = new Date("2026-09-07T12:00:05.000Z");
  const release = () =>
    releaseReq({
      block_id: granted.body.block_id,
      streamed_secs: 5,
      detections: 0,
    });

  h.balance.failRefunds = 1;
  const failed = await call(h.deps, release());
  assertEquals(failed.status, 503);
  // Still unreconciled, so the retry runs the refund path again instead of
  // being answered "already released, nothing refunded".
  assertEquals(h.blocks.rows[0].reconciled, false);
  assertEquals(h.balance.balances.get(USER), 15);

  const retried = await call(h.deps, release());
  assertEquals(retried.body, {
    refunded: true,
    balance: 20,
    used_credits: 0,
    refunded_credits: 5,
  });
  assertEquals(h.blocks.rows[0].reconciled, true);

  // And a third attempt does not credit a second time.
  assertEquals((await call(h.deps, release())).body, { refunded: false });
  assertEquals(h.balance.balances.get(USER), 20);
});

// --- Stopping early returns the minutes that were not used ---------------

/** Grants a block at 12:00:00 and releases it `seconds` later. */
async function releasedAfter(seconds: number, detections = 3) {
  const h = harness();
  const granted = await call(h.deps, grantReq());
  h.clock.now = new Date(Date.parse("2026-09-07T12:00:00.000Z") + seconds * 1000);
  const { body } = await call(
    h.deps,
    releaseReq({
      block_id: granted.body.block_id,
      streamed_secs: seconds,
      detections,
    }),
  );
  return { h, body };
}

Deno.test("release: 37 seconds costs one minute and returns four", async () => {
  // The case that prompted this: a short session used to cost a whole
  // five-minute block.
  const { h, body } = await releasedAfter(37);
  assertEquals(body, {
    refunded: true,
    balance: 19,
    used_credits: 1,
    refunded_credits: 4,
  });
  assertEquals(h.balance.balances.get(USER), 19);
});

Deno.test("release: a started minute is charged whole", async () => {
  assertEquals((await releasedAfter(60)).body.used_credits, 1);
  assertEquals((await releasedAfter(61)).body.used_credits, 2);
  assertEquals((await releasedAfter(181)).body.used_credits, 4);
});

Deno.test("release: a block run to its end returns nothing", async () => {
  const { h, body } = await releasedAfter(299);
  assertEquals(body, { refunded: false, used_credits: 5, refunded_credits: 0 });
  // Nothing moved, so the ledger was not asked.
  assertEquals(h.balance.calls.map((c) => c.op), ["get", "spend"]);
});

Deno.test("release: a release after the block expired is never worth more than the block", async () => {
  const { body } = await releasedAfter(900);
  assertEquals(body.used_credits, 5);
  assertEquals(body.refunded_credits, 0);
});

Deno.test("release: the client's own streamed_secs decides nothing", async () => {
  // Two minutes ran on the server's clock. Claiming one second streamed must
  // not buy a bigger refund.
  const h = harness();
  const granted = await call(h.deps, grantReq());
  h.clock.now = new Date("2026-09-07T12:02:00.000Z");
  const { body } = await call(
    h.deps,
    releaseReq({ block_id: granted.body.block_id, streamed_secs: 1, detections: 3 }),
  );
  assertEquals(body.used_credits, 2);
});

Deno.test("release: the amount is fixed by the first attempt, however late the retry", async () => {
  // The refund is keyed on the block, so a retry that worked out a different
  // amount would be asking the ledger to apply one key twice with two
  // bodies. The first attempt's moment is stamped and read back instead.
  const h = harness();
  const granted = await call(h.deps, grantReq());
  const release = () =>
    releaseReq({ block_id: granted.body.block_id, streamed_secs: 50, detections: 3 });

  h.clock.now = new Date("2026-09-07T12:00:50.000Z");
  h.balance.failRefunds = 1;
  assertEquals((await call(h.deps, release())).status, 503);
  assertEquals(h.balance.balances.get(USER), 15);

  // Well over a minute later: a naive recomputation would now charge three.
  h.clock.now = new Date("2026-09-07T12:02:10.000Z");
  const retried = await call(h.deps, release());
  assertEquals(retried.body, {
    refunded: true,
    balance: 19,
    used_credits: 1,
    refunded_credits: 4,
  });
});

// --- Balance ---------------------------------------------------------------

Deno.test("balance: reports what the user has and what a session needs", async () => {
  const h = harness({ initialBalance: 23 });
  const { status, body } = await call(h.deps, balanceReq());
  assertEquals(status, 200);
  assertEquals(body, { balance: 23, required: 5 });
  // A read moves nothing.
  assertEquals(h.balance.calls.map((c) => c.op), ["get"]);
});

Deno.test("balance: needs a signed-in user", async () => {
  const h = harness();
  assertEquals((await call(h.deps, balanceReq(null))).status, 401);
  assertEquals(h.balance.calls.length, 0);
});

Deno.test("balance: is metered, because every read is a ledger round trip", async () => {
  const h = harness();
  for (let i = 0; i < BALANCE_READ.max; i++) {
    assertEquals((await call(h.deps, balanceReq())).status, 200);
  }
  const limited = await call(h.deps, balanceReq());
  assertEquals(limited.status, 429);
  assertEquals(limited.body.error, "rate_limited");
  // The refused read never reached the ledger.
  assertEquals(h.balance.calls.length, BALANCE_READ.max);
});

Deno.test("release: unknown or foreign block is 404, unauthenticated is 401", async () => {
  const h = harness();
  const unknown = await call(
    h.deps,
    releaseReq({ block_id: "44444444-4444-4444-8444-444444444444", streamed_secs: 0, detections: 0 }),
  );
  assertEquals(unknown.status, 404);

  const anon = await call(h.deps, releaseReq({ block_id: SESSION }, null));
  assertEquals(anon.status, 401);
});

// ---------------------------------------------------------------------------
// Routing

Deno.test("routing: non-POST is 405, unknown path is 404", async () => {
  const h = harness();
  const get = await handleVoiceBlock(
    new Request(`${BASE}/voice-block`, { method: "GET" }),
    h.deps,
  );
  assertEquals(get.status, 405);

  const other = await handleVoiceBlock(
    new Request(`${BASE}/voice-block/other`, {
      method: "POST",
      headers: { Authorization: `Bearer ${GOOD_TOKEN}` },
    }),
    h.deps,
  );
  assertEquals(other.status, 404);
});

Deno.test("RevenueCat provider: follows the balance cursor rather than reading a zero", async () => {
  // The list is paginated. A currency that fell onto page two would read as a
  // zero balance, which 402s every grant and no amount of buying credit fixes.
  const { provider, sent } = revenueCat([
    jsonResponse({
      object: "list",
      items: [{ currency_code: "GEMS", balance: 99 }],
      next_page:
        `/v2/projects/proj/customers/${USER}/virtual_currencies?starting_after=abc`,
    }),
    jsonResponse({
      object: "list",
      items: [{ currency_code: "VOICE", balance: 12 }],
      next_page: null,
    }),
  ]);

  assertEquals(await provider.getBalance(USER), 12);
  assertEquals(sent.length, 2);
  assertStringIncludes(sent[0].url, "include_empty_balances=true&limit=100");
  // next_page already carries the /v2 the base URL supplies; it must not be
  // doubled.
  assertEquals(
    sent[1].url,
    `https://api.revenuecat.com/v2/projects/proj/customers/${USER}/virtual_currencies?starting_after=abc`,
  );
});

Deno.test("RevenueCat provider: a currency on no page is a zero balance", async () => {
  const { provider } = revenueCat([jsonResponse({ object: "list", items: [] })]);
  assertEquals(await provider.getBalance(USER), 0);
});

// The bodies below are RevenueCat's own, captured from a live project on
// 2 Oct 2026 rather than written from the reference.
const customerMissing = () =>
  jsonResponse({
    object: "error",
    type: "resource_missing",
    message: "Customer could not be found",
    param: "customer_id",
    retryable: false,
  }, 404);
const customerCreated = () =>
  jsonResponse({ object: "customer", id: USER }, 201);
const customerExists = () =>
  jsonResponse({
    object: "error",
    type: "resource_already_exists",
    message: "id is already taken",
    param: "id",
    retryable: false,
  }, 409);

Deno.test("RevenueCat provider: a grant is a positive adjustment keyed on its reference", async () => {
  const { provider, sent } = revenueCat([
    customerCreated,
    jsonResponse({ items: [{ currency_code: "VOICE", balance: 70 }] }),
  ]);

  assertEquals(await provider.grant(USER, `voucher:${BLOCK}`, 50), 70);
  assertStringIncludes(sent[1].url, "/virtual_currencies/transactions");
  assertEquals(sent[1].body.adjustments, { VOICE: 50 });
  assertEquals(sent[1].body.reference, `voucher:${BLOCK}`);
  // The reference is the idempotency key, which is what makes a retried
  // trial or redemption pay out once (reqs 11.8, 12.5).
  assertEquals(sent[1].headers["Idempotency-Key"], `voucher:${BLOCK}`);
});

Deno.test("RevenueCat provider: a customer it has never seen has no credits", async () => {
  // Every first-time user is unknown to RevenueCat until something creates
  // them. This was answered as an outage, so a new user asking for a block
  // got 503 `provider_unavailable` instead of 402 — found on the first real
  // request against a live project.
  const { provider, sent } = revenueCat([customerMissing]);

  assertEquals(await provider.getBalance(USER), 0);
  // A balance check must not write to the ledger.
  assertEquals(sent.length, 1);
  assertEquals(sent[0].init.method, "GET");
});

Deno.test("RevenueCat provider: any other 404 is a failure, not an empty balance", async () => {
  // A wrong project id also answers 404. Reading that as zero would 402
  // every user and hide a misconfiguration behind a plausible answer.
  const { provider } = revenueCat([
    () =>
      jsonResponse({
        object: "error",
        type: "resource_missing",
        message: "Project could not be found",
        param: "project_id",
      }, 404),
  ]);

  const error = await assertRejects(
    () => provider.getBalance(USER),
    ProviderError,
  );
  assertEquals(error.reason, "unavailable");
});

Deno.test("RevenueCat provider: a grant creates the customer before crediting them", async () => {
  // RevenueCat refuses a transaction for an unknown customer, and a trial or
  // a voucher is usually the first thing a new user does.
  const { provider, sent } = revenueCat([
    customerCreated,
    jsonResponse({ items: [{ currency_code: "VOICE", balance: 20 }] }),
  ]);

  assertEquals(await provider.grant(USER, `trial:${USER}`, 20), 20);
  assertEquals(sent.length, 2);
  assertEquals(
    sent[0].url,
    "https://api.revenuecat.com/v2/projects/proj/customers",
  );
  assertEquals(sent[0].init.method, "POST");
  assertEquals(sent[0].body, { id: USER });
  assertStringIncludes(
    sent[1].url,
    `/customers/${USER}/virtual_currencies/transactions`,
  );
});

Deno.test("RevenueCat provider: a customer who already exists is still credited", async () => {
  const { provider, sent } = revenueCat([
    customerExists,
    jsonResponse({ items: [{ currency_code: "VOICE", balance: 45 }] }),
  ]);

  assertEquals(await provider.grant(USER, `voucher:${BLOCK}`, 25), 45);
  assertEquals(sent.length, 2);
});

Deno.test("RevenueCat provider: no credit moves when the customer cannot be created", async () => {
  const { provider, sent } = revenueCat([
    () => new Response("", { status: 500 }),
  ]);

  await assertRejects(
    () => provider.grant(USER, `trial:${USER}`, 20),
    ProviderError,
  );
  // Stopped at the create: the transaction was never attempted.
  assertEquals(sent.length, 1);
});

Deno.test("RevenueCat provider: a debit for a customer who vanished is a failure", async () => {
  // A debit only follows a balance that customer was found to have, so a
  // missing customer here means the ledger disagrees with what was just
  // read. That is something to report, never a zero to assume.
  const { provider } = revenueCat([customerMissing]);

  const error = await assertRejects(
    () => provider.spend(USER, BLOCK, 5),
    ProviderError,
  );
  assertEquals(error.reason, "unavailable");
});
