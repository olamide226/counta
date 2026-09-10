import { json, readJson } from "./respond.ts";
import { Deps, RedeemOutcome } from "./types.ts";

// POST /voice-block/redeem — campaign voucher codes (req 12).
//
// The interesting decisions are not here: one redemption per user and the
// campaign cap are database constraints, and the whole lookup-claim-insert is
// one Postgres function so the slot and the redemption row cannot come apart
// (design: Edge Function contract). What is left in this file is the order of
// the calls, the rate limit, and the wording of the refusals.

/** The ledger reference and idempotency key for a redemption's payout. */
export function redemptionReference(redemptionId: string): string {
  return `voucher:${redemptionId}`;
}

export async function redeem(
  req: Request,
  deps: Deps,
  userId: string,
): Promise<Response> {
  const { config, vouchers, balance } = deps;
  const now = deps.now();

  const body = await readJson(req);
  const raw = body?.code;
  const code = typeof raw === "string" ? raw.trim() : "";
  if (code.length === 0 || code.length > MAX_CODE_LENGTH) {
    return json(400, { error: "invalid_request" });
  }

  // 12.8, before the lookup: the attempt counter is the only thing that
  // actually bounds guessing, however carefully the refusals are worded.
  const windowMs = config.voucherAttemptWindowMinutes * 60_000;
  const attempts = await vouchers.attemptsSince(
    userId,
    new Date(now.getTime() - windowMs),
  );
  if (attempts.count >= config.voucherAttemptMax) {
    deps.log("voucher_rate_limited", {
      user_id: userId,
      attempts: attempts.count,
    });
    // A rate-limited request records nothing: counting refusals of refusals
    // would let the window renew itself for as long as the caller kept
    // knocking, so the block could never lift.
    return json(429, {
      error: "too_many_attempts",
      retry_after_seconds: retryAfterSeconds(attempts.oldest, windowMs, now),
    });
  }

  const result = await vouchers.redeem(code, userId);

  if (result.outcome !== "redeemed" && result.outcome !== "already_redeemed") {
    // Nothing was written — a failed attempt is never a redemption (12.8).
    await vouchers.recordAttempt(userId);
    deps.log("voucher_refused", { user_id: userId, outcome: result.outcome });
    return refusal(result.outcome);
  }

  // The redemption row exists and the slot is claimed. The payout is keyed on
  // the redemption id, so this is the *same* grant however many times it is
  // attempted: a retry after a ledger failure completes it, and a retry after
  // a success is a no-op (12.5). That is why the already-redeemed answer
  // re-issues rather than skipping — a redemption whose credits never landed
  // heals on the next tap instead of being lost.
  const balanceAfter = await balance.grant(
    userId,
    redemptionReference(result.redemption_id),
    result.credits,
  );

  // 12.11, in the shape a block grant logs (10.1).
  deps.log("voucher_redeemed", {
    user_id: userId,
    voucher_id: result.voucher_id,
    redemption_id: result.redemption_id,
    credits: result.credits,
    first_redemption: result.outcome === "redeemed",
    redeemed_at: now.toISOString(),
  });

  return result.outcome === "redeemed"
    ? json(200, { redeemed: true, credits: result.credits, balance: balanceAfter })
    : json(200, {
      redeemed: false,
      reason: "already_redeemed",
      credits: result.credits,
      balance: balanceAfter,
    });
}

/**
 * Unknown and disabled are one answer with no way to tell them apart, so the
 * endpoint cannot be used to discover which codes exist (12.6). The store
 * collapses them before they get here, so there is nothing to leak by timing
 * either. Expiry and exhaustion do get their own answers (12.7): they reach a
 * user holding a real code, and telling that user their code is fake is worse
 * than the little the distinction gives away.
 */
function refusal(outcome: RedeemOutcome["outcome"]): Response {
  switch (outcome) {
    case "expired":
      return json(409, { error: "voucher_expired" });
    case "exhausted":
      return json(409, { error: "voucher_exhausted" });
    default:
      return json(404, { error: "voucher_invalid" });
  }
}

/** When the oldest attempt in the window falls out of it, at the earliest. */
function retryAfterSeconds(
  oldest: Date | null,
  windowMs: number,
  now: Date,
): number {
  const clearsAt = (oldest?.getTime() ?? now.getTime()) + windowMs;
  return Math.max(1, Math.ceil((clearsAt - now.getTime()) / 1000));
}

/** Longer than any code a human types off a card; a probe, not a redemption. */
const MAX_CODE_LENGTH = 64;
