import { assertEquals } from "@std/assert";
import {
  call,
  CONFIG,
  FakeTokenMinter,
  grantReq,
  harness,
  OTHER_USER,
  releaseReq,
  SESSION,
  tokenFor,
  tokenReq,
  USER,
} from "./testing/fakes.ts";
import { ProviderError } from "./types.ts";

// POST /voice-block/token — a fresh Deepgram token for a block the caller
// already holds. The route exists because the token TTL governs connection
// establishment only: without it, a socket that drops more than 30 seconds
// into a 300-second block has no credential left to reconnect with.

const UNKNOWN_BLOCK = "44444444-4444-4444-8444-444444444444";

Deno.test("token: mints for the caller's live block and never debits", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());
  const spent = h.balance.balances.get(USER);

  h.clock.now = new Date("2026-09-07T12:02:00.000Z");
  const { status, body } = await call(
    h.deps,
    tokenReq({ block_id: granted.body.block_id }),
  );

  assertEquals(status, 200);
  assertEquals(body, { token: "fake-token-2", expires_in: 30 });
  // The whole point: a reconnect two minutes into a block costs a Deepgram
  // mint and nothing else. Charging per dropped socket would bill a user for
  // a bad network, and asking /voice-block for another grant would do exactly
  // that — the matching session_id reads as a renewal.
  assertEquals(h.balance.balances.get(USER), spent);
  assertEquals(h.balance.calls.filter((c) => c.op === "spend").length, 1);
  assertEquals(h.blocks.rows.length, 1);
  assertEquals(h.blocks.rows[0].reconciled, false);

  const logged = h.logs.find((l) => l.event === "block_token_minted");
  assertEquals(logged?.fields.user_id, USER);
  assertEquals(logged?.fields.block_id, granted.body.block_id);
  assertEquals(logged?.fields.expires_in, 30);
});

Deno.test("token: a malformed block_id is 400 before the limiter or the minter", async () => {
  const h = harness();

  for (const body of [{}, { block_id: "abc" }, { block_id: 42 }, { block_id: null }]) {
    const res = await call(h.deps, tokenReq(body));
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals(res.body, { error: "invalid_request" });
  }
  assertEquals(h.minter.minted, 0);
});

Deno.test("token: unknown, foreign, reconciled and expired blocks are one answer", async () => {
  // A block that is not the caller's must be indistinguishable from one that
  // does not exist, or the endpoint becomes an oracle for live block ids.
  const h = harness({ initialBalance: 100 });
  const mine = await call(h.deps, grantReq());

  const unknown = await call(h.deps, tokenReq({ block_id: UNKNOWN_BLOCK }));
  assertEquals(unknown.status, 404);
  assertEquals(unknown.body, { error: "block_not_found" });

  // The same live block id, asked for by somebody else.
  const foreign = await call(
    h.deps,
    tokenReq({ block_id: mine.body.block_id }, tokenFor(OTHER_USER)),
  );
  assertEquals(foreign.status, unknown.status);
  assertEquals(foreign.body, unknown.body);

  // Released: the block is over, so there is nothing to reconnect to.
  await call(
    h.deps,
    releaseReq({ block_id: mine.body.block_id, streamed_secs: 30, detections: 4 }),
  );
  const released = await call(h.deps, tokenReq({ block_id: mine.body.block_id }));
  assertEquals(released.status, 404);
  assertEquals(released.body, { error: "block_not_found" });

  // And an unreleased block that simply ran out of time.
  const second = await call(h.deps, grantReq({ session_id: SESSION }));
  h.clock.now = new Date("2026-09-07T12:06:00.000Z");
  const expired = await call(h.deps, tokenReq({ block_id: second.body.block_id }));
  assertEquals(expired.status, 404);
  assertEquals(expired.body, { error: "block_not_found" });

  // Not one of those four asked Deepgram for anything.
  assertEquals(h.minter.minted, 2);
});

Deno.test("token: the mint budget is per user and lifts with its window", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());
  const body = { block_id: granted.body.block_id };

  for (let i = 0; i < CONFIG.tokenMintMax; i++) {
    assertEquals((await call(h.deps, tokenReq(body))).status, 200, `mint ${i}`);
  }

  const limited = await call(h.deps, tokenReq(body));
  assertEquals(limited.status, 429);
  assertEquals(limited.body, { error: "rate_limited" });
  assertEquals(h.logs.some((l) => l.event === "token_rate_limited"), true);
  // Refused before Deepgram was asked: an unmetered mint route is an
  // unmetered path to provider credentials.
  assertEquals(h.minter.minted, CONFIG.tokenMintMax + 1); // +1 for the grant

  // Another caller has their own budget.
  const other = harness();
  const theirs = await call(other.deps, grantReq(undefined, tokenFor(OTHER_USER)));
  assertEquals(
    (await call(
      other.deps,
      tokenReq({ block_id: theirs.body.block_id }, tokenFor(OTHER_USER)),
    )).status,
    200,
  );

  // A refused request is not itself counted, so the window can clear.
  h.clock.now = new Date(
    h.clock.now.getTime() + CONFIG.tokenMintWindowMinutes * 60_000 + 1000,
  );
  // The block is long gone by then, but the limiter has let go: a 404 rather
  // than a 429 is what says the budget lifted.
  assertEquals((await call(h.deps, tokenReq(body))).status, 404);
});

Deno.test("token: a Deepgram failure is 503 and leaves the block alone", async () => {
  const minter = new FakeTokenMinter(
    new ProviderError("unavailable", "deepgram down"),
  );
  const h = harness({ minter });
  // Granted before Deepgram went down, which is the case this route is for.
  h.blocks.rows.push({
    id: UNKNOWN_BLOCK,
    user_id: USER,
    session_id: SESSION,
    credits: 5,
    granted_at: "2026-09-07T12:00:00.000Z",
    expires_at: "2026-09-07T12:05:00.000Z",
    reconciled: false,
    streamed_secs: null,
    detections: null,
  });

  const { status, body } = await call(h.deps, tokenReq({ block_id: UNKNOWN_BLOCK }));

  assertEquals(status, 503);
  assertEquals(body, { error: "provider_unavailable" });
  // The block still has time left on it; the client may retry.
  assertEquals(h.blocks.rows[0].reconciled, false);
  assertEquals(h.balance.calls.filter((c) => c.op === "refund").length, 0);
});

Deno.test("token: unauthenticated is 401 and touches nothing", async () => {
  const h = harness();
  const granted = await call(h.deps, grantReq());

  const anon = await call(
    h.deps,
    tokenReq({ block_id: granted.body.block_id }, null),
  );

  assertEquals(anon.status, 401);
  assertEquals(anon.body, { error: "unauthenticated" });
  assertEquals(h.minter.minted, 1);
});
