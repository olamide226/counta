import { assertEquals } from "@std/assert";
import { MAX_KEYS, MemoryRateLimiter, secondsUntilClear } from "./ratelimit.ts";

// The in-memory budget behind /voice-block/token. Its whole justification is
// being cheaper than a database round trip, so what is pinned here is the
// answer it gives and the work it does to give it.

const START = new Date("2026-09-07T12:00:00.000Z");
const WINDOW_MS = 60_000;

const at = (offsetMs: number) => new Date(START.getTime() + offsetMs);

Deno.test("ratelimit: refuses at the budget and says when the window clears", () => {
  const limiter = new MemoryRateLimiter(3, WINDOW_MS);

  assertEquals(limiter.allow("u", at(0)), { allowed: true, retryAfterSeconds: 0 });
  assertEquals(limiter.allow("u", at(10_000)).allowed, true);
  assertEquals(limiter.allow("u", at(20_000)).allowed, true);

  // The oldest of the three hits is what has to fall out of the window, so a
  // caller 30s in waits the remaining 30, not another whole minute.
  assertEquals(limiter.allow("u", at(30_000)), {
    allowed: false,
    retryAfterSeconds: 30,
  });

  // A refusal is not itself recorded, so knocking cannot renew the block.
  assertEquals(limiter.allow("u", at(50_000)), {
    allowed: false,
    retryAfterSeconds: 10,
  });
  assertEquals(limiter.allow("u", at(61_000)).allowed, true);

  // And the budget is per key.
  assertEquals(limiter.allow("other", at(30_000)).allowed, true);
});

Deno.test("ratelimit: a hint is never zero seconds", () => {
  // A hint of zero invites an immediate retry that is refused again, and a
  // client that trusts it spins.
  assertEquals(secondsUntilClear(0, WINDOW_MS, WINDOW_MS), 1);
  assertEquals(secondsUntilClear(0, WINDOW_MS, WINDOW_MS + 5_000), 1);
});

Deno.test("ratelimit: a worker that sees a flood of keys does not grow with it", () => {
  // The regression. The old sweep deleted only keys whose whole window had
  // passed, so with more than MAX_KEYS keys all *inside* the window it deleted
  // nothing, the size stayed over the threshold, and every later call paid
  // another full scan — an O(n) walk on the route that exists to avoid a round
  // trip.
  const limiter = new MemoryRateLimiter(3, WINDOW_MS);
  for (let i = 0; i < MAX_KEYS + 2_000; i++) {
    assertEquals(limiter.allow(`user-${i}`, at(0)).allowed, true);
  }
  assertEquals(limiter.size, MAX_KEYS);
});

Deno.test("ratelimit: eviction takes the dead keys before the live ones", () => {
  const limiter = new MemoryRateLimiter(2, WINDOW_MS);
  for (let i = 0; i < MAX_KEYS; i++) limiter.allow(`stale-${i}`, at(0));

  // A whole window later, so every key above is dead, and one caller is busy.
  limiter.allow("busy", at(WINDOW_MS + 1_000));
  limiter.allow("busy", at(WINDOW_MS + 2_000));

  // Enough new keys to force thousands of evictions, but fewer than the dead
  // keys still held: nothing here should have to reach a live one.
  const fresh = MAX_KEYS - 1_000;
  for (let i = 0; i < fresh; i++) limiter.allow(`fresh-${i}`, at(WINDOW_MS + 3_000));

  assertEquals(limiter.size, MAX_KEYS);
  // The busy caller's two hits survived: it was touched more recently than any
  // of the dead keys, so the dead ones went first and its budget still holds.
  assertEquals(limiter.allow("busy", at(WINDOW_MS + 4_000)).allowed, false);
});
