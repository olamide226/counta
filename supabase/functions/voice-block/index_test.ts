import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "@std/assert";
import { handleVoiceBlock } from "./handler.ts";
import { RevenueCatBalanceProvider } from "./providers/balance.ts";
import { DeepgramTokenMinter } from "./providers/minter.ts";
import {
  CONFIG,
  FakeTokenMinter,
  GOOD_TOKEN,
  grantReq,
  harness,
  releaseReq,
  SESSION,
  USER,
} from "./testing/fakes.ts";
import { Deps, ProviderError } from "./types.ts";

async function call(deps: Deps, req: Request) {
  const res = await handleVoiceBlock(req, deps);
  return { status: res.status, body: await res.json() };
}

const BASE = "http://localhost:54321/functions/v1";
const BLOCK = "33333333-3333-4333-8333-000000000001";

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

Deno.test("grant: live block for the user is 409 with its expiry", async () => {
  const h = harness();
  const first = await call(h.deps, grantReq());
  assertEquals(first.status, 200);

  h.clock.now = new Date("2026-09-07T12:01:00.000Z");
  const second = await call(h.deps, grantReq());
  assertEquals(second.status, 409);
  assertEquals(second.body, {
    error: "block_in_flight",
    expires_at: first.body.expires_at,
  });
  assertEquals(h.balance.balances.get(USER), 15);
});

Deno.test("grant: a block inside its renewal overlap window does not 409", async () => {
  const h = harness();
  await call(h.deps, grantReq());
  // 270 s in = 90% of a 300 s block, the renewal point from req 3.9.
  h.clock.now = new Date("2026-09-07T12:04:30.000Z");
  const renewal = await call(h.deps, grantReq());
  assertEquals(renewal.status, 200);
  assertEquals(h.blocks.rows.length, 2);
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

Deno.test("grant: a rate-limited balance read fails fast to 503 without sleeping", async () => {
  let attempts = 0;
  const fetchStub: typeof fetch = () => {
    attempts++;
    return Promise.resolve(
      new Response("", { status: 429, headers: { "Retry-After": "60" } }),
    );
  };
  const sleeps: number[] = [];
  const balance = new RevenueCatBalanceProvider({
    secretKey: "test",
    projectId: "proj",
    currencyCode: "VOICE",
    fetch: fetchStub,
    sleep: (ms) => {
      sleeps.push(ms);
      return Promise.resolve();
    },
  });
  const h = harness({ balance });
  const { status, body } = await call(h.deps, grantReq());

  assertEquals(status, 503);
  assertEquals(body, { error: "provider_unavailable" });
  // The read happens before any money moves, so retrying it only burns the
  // seconds the client's token window has left.
  assertEquals(attempts, 1);
  assertEquals(sleeps, []);
  assertEquals(h.minter.minted, 0);
});

Deno.test("RevenueCat provider: a write retries a 429 twice with a capped backoff", async () => {
  let attempts = 0;
  const fetchStub: typeof fetch = () => {
    attempts++;
    return Promise.resolve(
      // A minute of Retry-After would outlive the token this request exists to
      // mint, so the backoff must clamp it.
      new Response("", { status: 429, headers: { "Retry-After": "60" } }),
    );
  };
  const sleeps: number[] = [];
  const provider = new RevenueCatBalanceProvider({
    secretKey: "test",
    projectId: "proj",
    currencyCode: "VOICE",
    fetch: fetchStub,
    sleep: (ms) => {
      sleeps.push(ms);
      return Promise.resolve();
    },
  });

  const error = await assertRejects(
    () => provider.spend(USER, BLOCK, 5),
    ProviderError,
  );
  assertEquals(error.reason, "rate_limited");
  assertEquals(attempts, 3); // 1 try + 2 retries
  assertEquals(sleeps, [2000, 2000]);
});

Deno.test("RevenueCat provider: recovers after a single 429 and parses the balance", async () => {
  let attempts = 0;
  const seen: Array<{ url: string; init?: RequestInit }> = [];
  const fetchStub: typeof fetch = (input, init) => {
    attempts++;
    seen.push({ url: String(input), init });
    if (attempts === 1) return Promise.resolve(new Response("", { status: 429 }));
    return Promise.resolve(
      new Response(
        JSON.stringify({
          object: "list",
          items: [
            { currency_code: "GEMS", balance: 99 },
            { currency_code: "VOICE", balance: 7 },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
  };
  const provider = new RevenueCatBalanceProvider({
    secretKey: "test",
    projectId: "proj",
    currencyCode: "VOICE",
    fetch: fetchStub,
    sleep: () => Promise.resolve(),
  });

  assertEquals(await provider.spend(USER, BLOCK, 5), 7);
  assertEquals(attempts, 2);
  assertStringIncludes(seen[1].url, `/projects/proj/customers/${USER}/virtual_currencies/transactions`);
  const sent = JSON.parse(String(seen[1].init?.body));
  assertEquals(sent.adjustments, { VOICE: -5 });
  assertEquals(sent.reference, `voice-block:${BLOCK}`);
  const headers = seen[1].init?.headers as Record<string, string>;
  assertEquals(headers["Idempotency-Key"], `voice-block:${BLOCK}`);
  assertEquals(headers["Authorization"], "Bearer test");
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
    fetch: () =>
      Promise.resolve(
        new Response("", { status: 429, headers: { "Retry-After": "3" } }),
      ),
  });

  const error = await assertRejects(() => minter.mint(30), ProviderError);
  assertEquals(error.reason, "rate_limited");
  assertEquals(error.retryAfterMs, 3000);
});

Deno.test("Deepgram minter: returns the access token from a successful grant", async () => {
  const seen: Array<{ url: string; init?: RequestInit }> = [];
  const minter = new DeepgramTokenMinter({
    apiKey: "master-key",
    fetch: (input, init) => {
      seen.push({ url: String(input), init });
      return Promise.resolve(
        new Response(JSON.stringify({ access_token: "dg-token", expires_in: 30 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
    },
  });

  assertEquals(await minter.mint(30), "dg-token");
  assertStringIncludes(seen[0].url, "https://api.deepgram.com/v1/auth/grant");
  assertEquals(JSON.parse(String(seen[0].init?.body)), { ttl_seconds: 30 });
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
  assertEquals(body, { refunded: false, balance: 15 });
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
  assertEquals(body, { refunded: false, balance: 15 });
});

Deno.test("release: is idempotent, a second release never refunds again", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());
  h.clock.now = new Date("2026-09-07T12:00:05.000Z");
  const req = () =>
    releaseReq({ block_id: granted.body.block_id, streamed_secs: 5, detections: 0 });

  assertEquals((await call(h.deps, req())).body, { refunded: true, balance: 20 });
  assertEquals((await call(h.deps, req())).body, { refunded: false, balance: 20 });
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
