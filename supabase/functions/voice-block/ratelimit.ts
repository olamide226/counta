import type { RateDecision, RateLimiter } from "./types.ts";

/**
 * A sliding-window counter held in the worker's memory.
 *
 * Deliberately not a database round trip. The block grant's limiter counts
 * rows in `counta.voice_blocks` because a grant already writes there and
 * because over-granting costs real money; a token mint writes nothing and
 * costs one Deepgram call, so paying a PostgREST round trip to meter it would
 * cost more than the thing being metered.
 *
 * The trade is that the budget is per worker rather than per user: a caller
 * spread across N warm workers gets N budgets, and a cold start forgets the
 * window. That is a loose bound, not no bound — and it sits behind a check
 * that the caller owns a live block, which is itself already limited to
 * `RATE_LIMIT_MAX` blocks per window. Tighten it into the database only if the
 * looseness ever shows up in the Deepgram bill.
 */
export class MemoryRateLimiter implements RateLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
  ) {}

  allow(key: string, now: Date): RateDecision {
    const at = now.getTime();
    const cutoff = at - this.windowMs;
    const kept = (this.hits.get(key) ?? []).filter((hit) => hit > cutoff);
    if (kept.length >= this.max) {
      // Recorded without the new hit: counting refusals of refusals would let
      // the window renew itself for as long as the caller kept knocking, so
      // the block could never lift (the same rule the voucher limiter follows).
      this.hits.set(key, kept);
      return {
        allowed: false,
        retryAfterSeconds: secondsUntilClear(kept[0], this.windowMs, at),
      };
    }
    kept.push(at);
    this.hits.set(key, kept);
    if (this.hits.size > MAX_KEYS) this.sweep(cutoff);
    return { allowed: true, retryAfterSeconds: 0 };
  }

  /**
   * Drops keys whose whole window has passed. Without it a worker that saw a
   * million user ids would hold a million entries for the life of the isolate,
   * which turns a rate limiter into a memory leak.
   */
  private sweep(cutoff: number): void {
    for (const [key, times] of this.hits) {
      if ((times.at(-1) ?? 0) <= cutoff) this.hits.delete(key);
    }
  }
}

/** Enough that a sweep is rare; small enough that a worker cannot bloat. */
const MAX_KEYS = 10_000;

/**
 * When a sliding window whose oldest hit is `oldestMs` has room again.
 *
 * Shared with the block-grant budget in handler.ts, which counts rows instead
 * of holding hits in memory but slides the same window over them, and it is
 * the arithmetic `counta.redeem_voucher` does in SQL for the third. Never
 * below a second: a hint of zero invites an immediate retry that is refused
 * again, and a client that trusts it spins.
 */
export function secondsUntilClear(
  oldestMs: number,
  windowMs: number,
  nowMs: number,
): number {
  return Math.max(1, Math.ceil((oldestMs + windowMs - nowMs) / 1000));
}
