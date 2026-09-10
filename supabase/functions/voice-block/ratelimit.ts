import type { RateLimiter } from "./types.ts";

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

  allow(key: string, now: Date): boolean {
    const cutoff = now.getTime() - this.windowMs;
    const kept = (this.hits.get(key) ?? []).filter((at) => at > cutoff);
    if (kept.length >= this.max) {
      // Recorded without the new hit: counting refusals of refusals would let
      // the window renew itself for as long as the caller kept knocking, so
      // the block could never lift (the same rule the voucher limiter follows).
      this.hits.set(key, kept);
      return false;
    }
    kept.push(now.getTime());
    this.hits.set(key, kept);
    if (this.hits.size > MAX_KEYS) this.sweep(cutoff);
    return true;
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
