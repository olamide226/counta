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

  // The redemption row exists and the slot is claimed. Whether this call also
  // *pays* is decided by the row, not by the ledger.
  //
  // The payout used to be re-issued on every repeat, on the strength of the
  // grant's Idempotency-Key deduplicating it. Those keys expire on a bounded
  // window, and after it a valid, already-redeemed code credited again every
  // time it was submitted — repeatedly, and uncounted, because the success
  // path records no attempt and so has no rate limit at all. `credited_at` is
  // what makes "pays out once" a property of this system rather than of
  // RevenueCat's key retention.
  //
  // An unconfirmed redemption is still re-issued, and that is the whole point
  // of the flag: the grant is keyed on the redemption id, so a redemption
  // whose ledger call died mid-flight completes on the next tap with the
  // *same* payout instead of being lost (12.5).
  const balanceAfter = result.credited ? undefined : await balance.grant(
    userId,
    redemptionReference(result.redemption_id),
    result.credits,
  );
  if (balanceAfter !== undefined) {
    // After the ledger, never before: a row marked credited by a payout that
    // then failed is a redemption nothing can ever complete. A failure here
    // leaves the row re-issuable, and the retry sends the same keyed grant.
    await vouchers.markCredited(result.redemption_id);
  }

  // 12.11, in the shape a block grant logs (10.1).
  deps.log("voucher_redeemed", {
    user_id: userId,
    voucher_id: result.voucher_id,
    redemption_id: result.redemption_id,
    credits: result.credits,
    first_redemption: result.outcome === "redeemed",
    // False on a repeat of a redemption that has already been paid for: the
    // answer is the same, but no credit moved.
    granted: balanceAfter !== undefined,
    redeemed_at: now.toISOString(),
  });

  // The balance is reported only when it moved, as a release reports a refund:
  // echoing an unchanged number costs a RevenueCat round trip on a request
  // that did nothing.
  return json(200, {
    ...(result.outcome === "redeemed"
      ? { redeemed: true }
      : { redeemed: false, reason: "already_redeemed" }),
    credits: result.credits,
    ...(balanceAfter === undefined ? {} : { balance: balanceAfter }),
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
