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
  assertEquals(limited.body, { error: "rate_limited" });

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
  assertEquals(body, { refunded: true, balance: 20 });
  const row = h.blocks.rows[0];
  assertEquals(row.reconciled, true);
  assertEquals(row.streamed_secs, 18);
  assertEquals(row.detections, 0);
});

Deno.test("release: client assertion is ignored when detections > 0", async () => {
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
  assertEquals(body, { refunded: false });
  assertEquals(h.blocks.rows[0].reconciled, true);
});

Deno.test("release: after the 30 s window is not refunded even with zero detections", async () => {
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
  assertEquals(body, { refunded: false });
});

Deno.test("release: a missing detections count is not a refundable zero", async () => {
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
  assertEquals(body.refunded, false);
  assertEquals(h.balance.balances.get(USER), 15);
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

  assertEquals((await call(h.deps, req())).body, { refunded: true, balance: 20 });
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
  assertEquals(retried.body, { refunded: true, balance: 20 });
  assertEquals(h.blocks.rows[0].reconciled, true);

  // And a third attempt does not credit a second time.
  assertEquals((await call(h.deps, release())).body, { refunded: false });
  assertEquals(h.balance.balances.get(USER), 20);
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

Deno.test("RevenueCat provider: a grant is a positive adjustment keyed on its reference", async () => {
  const { provider, sent } = revenueCat([
    jsonResponse({ items: [{ currency_code: "VOICE", balance: 70 }] }),
  ]);

  assertEquals(await provider.grant(USER, `voucher:${BLOCK}`, 50), 70);
  assertStringIncludes(sent[0].url, "/virtual_currencies/transactions");
  assertEquals(sent[0].body.adjustments, { VOICE: 50 });
  assertEquals(sent[0].body.reference, `voucher:${BLOCK}`);
  // The reference is the idempotency key, which is what makes a retried
  // trial or redemption pay out once (reqs 11.8, 12.5).
  assertEquals(sent[0].headers["Idempotency-Key"], `voucher:${BLOCK}`);
});
