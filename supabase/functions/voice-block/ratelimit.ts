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
  /**
   * Hit times per key, and — because a Map iterates in insertion order and
   * every touch below re-inserts — least-recently-seen key first. That
   * ordering is what makes eviction cheap and, better, correct: a key is dead
   * exactly when its newest hit has left the window, and its newest hit is its
   * last touch, so every dead key sorts ahead of every live one. Evicting from
   * the front therefore takes the dead ones first and only reaches a live key
   * when there are no dead ones left.
   */
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
  ) {}

  /** Keys currently held. Bounded by MAX_KEYS; see evict(). */
  get size(): number {
    return this.hits.size;
  }

  allow(key: string, now: Date): RateDecision {
    const at = now.getTime();
    const cutoff = at - this.windowMs;

    // Pruned in place. Hits are appended in time order, so everything outside
    // the window is a prefix of the array; rebuilding it with .filter()
    // allocated a fresh array on every call to this route for nothing.
    const kept = this.hits.get(key) ?? [];
    let stale = 0;
    while (stale < kept.length && kept[stale] <= cutoff) stale++;
    if (stale > 0) kept.splice(0, stale);

    // Deleted and re-set even when it was already there: that is what moves
    // the key to the back and keeps the map in last-touch order.
    this.hits.delete(key);
    this.hits.set(key, kept);
    this.evict();

    if (kept.length >= this.max) {
      // Refused without recording the hit: counting refusals of refusals would
      // let the window renew itself for as long as the caller kept knocking,
      // so the block could never lift (the same rule the voucher limiter
      // follows).
      return {
        allowed: false,
        retryAfterSeconds: secondsUntilClear(kept[0], this.windowMs, at),
      };
    }
    kept.push(at);
    return { allowed: true, retryAfterSeconds: 0 };
  }

  /**
   * Holds the map to MAX_KEYS, one key per over-capacity insert.
   *
   * This used to be a sweep that deleted keys whose whole window had passed,
   * run whenever the map was over the threshold — which is fine on a cold
   * worker and useless on a busy one. With more than MAX_KEYS keys all inside
   * the live window it deleted nothing, the size stayed above the threshold,
   * and every subsequent call paid another full scan: an O(n) walk bolted onto
   * the one route whose whole justification is being cheaper than a round trip.
   *
   * Evicting from the front instead is O(1) amortised and actually brings the
   * size down. The cost is that a worker holding MAX_KEYS live windows drops
   * the least recently seen one, which hands that caller a fresh budget — this
   * limiter is a loose per-worker bound by construction (see above), and one
   * that fails open under a load that large is the same trade already made.
   */
  private evict(): void {
    while (this.hits.size > MAX_KEYS) {
      const oldest = this.hits.keys().next();
      if (oldest.done) return;
      this.hits.delete(oldest.value);
    }
  }
}

/** Big enough that eviction is rare; small enough that a worker cannot bloat. */
export const MAX_KEYS = 10_000;

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
