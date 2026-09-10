import { redeem } from "./redeem.ts";
import { secondsUntilClear } from "./ratelimit.ts";
import { isUuid, json, rateLimited, readJson } from "./respond.ts";
import { mintToken } from "./token.ts";
import { trial } from "./trial.ts";
import { BlockConflictError, Deps, ProviderError } from "./types.ts";

// Pure request handler for the five POST routes under /voice-block. No
// Deno.env, no network: everything arrives through `deps`, which is what makes
// index_test.ts possible without a running stack.
//
// Every route verifies the same JWT and every credit movement goes through the
// same BalanceProvider, so there is one code path that moves money and one
// place to audit it (design: Edge Function contract).

/** Suffix -> route. The bare function name is the block grant. */
const ROUTES: Record<
  string,
  (req: Request, deps: Deps, userId: string) => Promise<Response>
> = {
  "/voice-block": grant,
  "/release": release,
  "/token": mintToken,
  "/trial": trial,
  "/redeem": redeem,
};

function bearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1].trim() : null;
}

export async function handleVoiceBlock(
  req: Request,
  deps: Deps,
): Promise<Response> {
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const path = new URL(req.url).pathname.replace(/\/+$/, "");
  const suffix = Object.keys(ROUTES).find((s) => path.endsWith(s));
  if (!suffix) {
    return json(404, { error: "not_found" });
  }

  const token = bearerToken(req);
  const userId = token ? await deps.auth.userIdForToken(token) : null;
  if (!userId) {
    return json(401, { error: "unauthenticated" });
  }

  try {
    return await ROUTES[suffix](req, deps, userId);
  } catch (error) {
    if (error instanceof ProviderError) {
      deps.log("provider_unavailable", {
        user_id: userId,
        reason: error.reason,
      });
      return json(503, { error: "provider_unavailable" });
    }
    deps.log("internal_error", { user_id: userId, message: String(error) });
    return json(500, { error: "internal" });
  }
}

async function grant(req: Request, deps: Deps, userId: string): Promise<Response> {
  const { config, blocks, balance, minter } = deps;
  const now = deps.now();

  const body = await readJson(req);
  const sessionId = body?.session_id;
  if (typeof sessionId !== "string" || !isUuid(sessionId)) {
    return json(400, { error: "invalid_session_id" });
  }

  // Rate limit (8.7) before anything that costs money or touches a provider.
  // Both pre-checks read the same table and neither depends on the other, so
  // they go out together rather than as two sequential PostgREST round trips.
  const windowStart = new Date(
    now.getTime() - config.rateLimitWindowMinutes * 60_000,
  );
  const [grants, live] = await Promise.all([
    blocks.grantsSince(userId, windowStart),
    blocks.findLiveBlock(userId, now),
  ]);
  if (grants.count >= config.rateLimitMax) {
    // The oldest grant in the window is what says when it has room again —
    // the same arithmetic the mint budget does in memory and the redemption
    // transaction does in SQL, so all three publish one answer (respond.ts).
    const retryAfter = secondsUntilClear(
      (grants.oldest ?? now).getTime(),
      config.rateLimitWindowMinutes * 60_000,
      now.getTime(),
    );
    deps.log("rate_limited", {
      user_id: userId,
      recent: grants.count,
      retry_after_seconds: retryAfter,
    });
    return rateLimited(retryAfter);
  }

  // 3.8 / 3.9: one live block per user, with renewal identified rather than
  // guessed. A grant whose session_id matches the live block is that session
  // renewing itself and supersedes it; a grant from any other session is a
  // conflict however little life the live block has left. Treating "nearly
  // expired" as "not live" handed a *second* session a concurrent block for
  // the whole overlap window — the exact thing 3.8 exists to prevent.
  if (live && live.session_id !== sessionId) {
    return json(409, { error: "block_in_flight", expires_at: live.expires_at });
  }

  // 3.3 / 3.4
  const current = await balance.getBalance(userId);
  if (current < config.blockCredits) {
    return json(402, {
      error: "insufficient_credit",
      balance: current,
      required: config.blockCredits,
    });
  }

  // 3.5: debit before minting. The block id is minted here rather than by the
  // database so every ledger call for this block — the debit and any refund —
  // is keyed on the same stable identity. Keying on the attempt (a timestamp)
  // meant a retried grant looked like a new purchase and double-charged.
  const blockId = deps.newBlockId();
  const balanceAfter = await balance.spend(userId, blockId, config.blockCredits);

  // 3.6: any mint failure refunds the debit and reports 503.
  let token: string;
  try {
    token = await minter.mint(config.tokenTtlSeconds);
  } catch (error) {
    await refundQuietly(deps, userId, blockId, config.blockCredits);
    deps.log("mint_failed", { user_id: userId, message: String(error) });
    return json(503, { error: "provider_unavailable" });
  }

  // 3.7. A failed insert must refund on exactly the path a failed mint does:
  // without a row there is no block_id to return and no block to /release, so
  // letting this fall through to the outer 500 would charge the user for
  // nothing they could ever use or reclaim.
  const expiresAt = new Date(now.getTime() + config.blockSeconds * 1000);
  let row;
  try {
    if (live) {
      // Retire the block this one renews: two unreconciled blocks for one user
      // is the state 3.8 forbids, and the unique index would reject the row.
      await blocks.supersede(live.id);
    } else {
      // A client that died mid-block never released its row; left alone it
      // would collide with the unique index for ever.
      await blocks.retireExpired(userId, now);
    }
    row = await blocks.insert({
      id: blockId,
      user_id: userId,
      session_id: sessionId,
      credits: config.blockCredits,
      granted_at: now.toISOString(),
      expires_at: expiresAt.toISOString(),
    });
  } catch (error) {
    await refundQuietly(deps, userId, blockId, config.blockCredits);
    if (error instanceof BlockConflictError) {
      // Another request for this user won the race between the check above and
      // this insert. The database is the authority on 3.8, so honour its
      // answer with the same 409 the pre-check would have returned.
      const winner = await blocks.findLiveBlock(userId, now);
      deps.log("block_in_flight", { user_id: userId, block_id: blockId });
      return json(409, {
        error: "block_in_flight",
        ...(winner ? { expires_at: winner.expires_at } : {}),
      });
    }
    deps.log("block_insert_failed", {
      user_id: userId,
      block_id: blockId,
      message: String(error),
    });
    return json(503, { error: "provider_unavailable" });
  }

  // 10.1
  deps.log("block_granted", {
    user_id: userId,
    block_id: row.id,
    renewal_of: live?.id ?? null,
    session_id: sessionId,
    credits: config.blockCredits,
    granted_at: row.granted_at,
  });

  return json(200, {
    block_id: row.id,
    token,
    block_seconds: config.blockSeconds,
    expires_at: row.expires_at,
    balance_after: balanceAfter,
  });
}

async function release(req: Request, deps: Deps, userId: string): Promise<Response> {
  const { config, blocks, balance } = deps;
  const now = deps.now();

  const body = await readJson(req);
  const blockId = body?.block_id;
  if (typeof blockId !== "string" || !isUuid(blockId)) {
    return json(400, { error: "invalid_block_id" });
  }
  // A refund costs real money, so it may only be granted on a count the client
  // actually reported. clampInt() turned a missing or garbage `detections`
  // into 0, which meant "omit the field" was a reliable way to be refunded.
  const streamedSecs = parseCount(body?.streamed_secs);
  const detections = parseCount(body?.detections);
  if (streamedSecs === INVALID) {
    return json(400, { error: "invalid_streamed_secs" });
  }
  if (detections === INVALID) {
    return json(400, { error: "invalid_detections" });
  }
  // The client's own assertion is recorded for observability but never trusted.
  const clientClaimsRefund = body?.eligible_for_refund === true;

  const block = await blocks.findById(blockId, userId);
  if (!block) {
    return json(404, { error: "block_not_found" });
  }

  if (block.reconciled) {
    // Idempotent: a retried release neither refunds twice nor errors.
    return json(200, { refunded: false });
  }

  // 3.11, validated server-side against granted_at. An absent `detections` is
  // not "zero detections" — it is no report at all, so it is not refundable.
  const ageMs = now.getTime() - new Date(block.granted_at).getTime();
  const eligible = ageMs <= config.refundWindowSeconds * 1000 &&
    detections === 0;

  // The refund goes before the reconcile, and is keyed on the block id so the
  // ledger applies it once however many times it is attempted. Flipping the
  // row first made a failure here permanent: the block was reconciled, the
  // money had not moved, and the client's retry was answered refunded:false.
  // Failing before the flip leaves a retry able to finish the job.
  const balanceAfter = eligible
    ? await balance.refund(userId, block.id, block.credits)
    : undefined;

  const flipped = await blocks.reconcile(block.id, {
    streamed_secs: streamedSecs,
    detections,
  });

  deps.log("block_released", {
    user_id: userId,
    block_id: block.id,
    streamed_secs: streamedSecs,
    detections,
    client_claimed_refund: clientClaimsRefund,
    refunded: balanceAfter !== undefined,
    first_release: flipped,
  });

  // The balance is reported only when it moved: echoing an unchanged number
  // costs a RevenueCat round trip on every ordinary release.
  return balanceAfter === undefined
    ? json(200, { refunded: false })
    : json(200, { refunded: true, balance: balanceAfter });
}

/**
 * Returns the debit for a block that will never exist. Failing to refund
 * leaves the money wrong, so it is logged loudly rather than thrown: the
 * caller is already returning an error, and the reconciliation query (10.5)
 * is what catches this class of drift.
 */
async function refundQuietly(
  deps: Deps,
  userId: string,
  blockId: string,
  credits: number,
): Promise<void> {
  try {
    await deps.balance.refund(userId, blockId, credits);
  } catch (error) {
    deps.log("refund_failed", {
      user_id: userId,
      block_id: blockId,
      credits,
      message: String(error),
    });
  }
}

/** Marks a count the client sent but that is not a count. */
const INVALID = Symbol("invalid_count");

/**
 * Reads an optional usage count from a release body. Absent is null (recorded
 * as unknown, never treated as zero); present but not a non-negative integer
 * is a client bug and earns a 400 rather than a silently substituted value.
 */
function parseCount(value: unknown): number | null | typeof INVALID {
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    return INVALID;
  }
  return value;
}
