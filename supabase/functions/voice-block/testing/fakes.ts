// Test doubles for the voice-block handler.
//
// Deliberately NOT imported by index.ts: a fake balance provider reachable from
// the deployed bundle is one env typo away from giving every caller free
// streaming, and a fake attestor there would hand the trial to every device
// that asked. The deployed function can only ever construct the real adapters.
// Nothing outside index_test.ts should import this file.

import { handleVoiceBlock } from "../handler.ts";
import { MemoryRateLimiter } from "../ratelimit.ts";
import { BlockConflictError, ProviderError } from "../types.ts";
import type {
  Authenticator,
  BalanceProvider,
  BlockStore,
  Deps,
  DeviceAttestation,
  DeviceAttestor,
  HandlerConfig,
  RedeemOutcome,
  TokenMinter,
  TrialGate,
  TrialGrantRow,
  TrialStore,
  VoiceBlockRow,
  VoucherStore,
} from "../types.ts";

export const USER = "11111111-1111-4111-8111-111111111111";
export const SESSION = "22222222-2222-4222-8222-222222222222";
export const GOOD_TOKEN = "good-jwt";

/** A bearer token for any other caller; see FakeAuth. */
export const tokenFor = (userId: string) => `user:${userId}`;

/** Hands out obviously-fake tokens. Never talks to Deepgram. */
export class FakeTokenMinter implements TokenMinter {
  minted = 0;
  constructor(private readonly failWith?: Error) {}

  mint(_ttlSeconds: number): Promise<string> {
    if (this.failWith) return Promise.reject(this.failWith);
    this.minted++;
    return Promise.resolve(`fake-token-${this.minted}`);
  }
}

export class FakeAuth implements Authenticator {
  userIdForToken(token: string): Promise<string | null> {
    if (token === GOOD_TOKEN) return Promise.resolve(USER);
    // A campaign cap needs more callers than one; tokenFor() mints them.
    const match = /^user:(.+)$/.exec(token);
    return Promise.resolve(match ? match[1] : null);
  }
}

/**
 * In-memory balances. State lives for the life of the instance.
 *
 * Applies each (op, blockId) pair at most once, mirroring the Idempotency-Key
 * contract the RevenueCat adapter relies on — without that, a test could not
 * tell a genuinely exactly-once refund from one that just happened to run
 * twice.
 */
export class FakeBalanceProvider implements BalanceProvider {
  readonly balances = new Map<string, number>();
  readonly calls: Array<
    { op: string; userId: string; blockId?: string; credits?: number }
  > = [];
  private applied = new Set<string>();

  /** While positive, the next refund rejects and this decrements. */
  failRefunds = 0;

  /**
   * Forgets every idempotency key, the way RevenueCat does once its retention
   * window has passed.
   *
   * Without this the double is *more* idempotent than the thing it stands in
   * for — `applied` never expired — and a caller that re-issued a grant on
   * every repeat looked exactly like one that paid out once. That is precisely
   * the bug it hid: after the real window closes, a re-issue is a second
   * payment.
   */
  expireIdempotencyKeys(): void {
    this.applied = new Set<string>();
  }

  constructor(private readonly initialBalance = 20) {}

  getBalance(userId: string): Promise<number> {
    this.calls.push({ op: "get", userId });
    return Promise.resolve(this.current(userId));
  }

  spend(userId: string, blockId: string, credits: number): Promise<number> {
    this.calls.push({ op: "spend", userId, blockId, credits });
    return this.apply(userId, `spend:${blockId}`, -credits);
  }

  refund(userId: string, blockId: string, credits: number): Promise<number> {
    this.calls.push({ op: "refund", userId, blockId, credits });
    if (this.failRefunds > 0) {
      this.failRefunds--;
      return Promise.reject(new ProviderError("unavailable", "refund failed"));
    }
    return this.apply(userId, `refund:${blockId}`, credits);
  }

  /** While positive, the next grant rejects and this decrements. */
  failGrants = 0;

  grant(userId: string, reference: string, credits: number): Promise<number> {
    this.calls.push({ op: "grant", userId, blockId: reference, credits });
    if (this.failGrants > 0) {
      this.failGrants--;
      return Promise.reject(new ProviderError("unavailable", "grant failed"));
    }
    return this.apply(userId, `grant:${reference}`, credits);
  }

  private apply(userId: string, key: string, delta: number): Promise<number> {
    if (!this.applied.has(key)) {
      this.applied.add(key);
      this.balances.set(userId, this.current(userId) + delta);
    }
    return Promise.resolve(this.current(userId));
  }

  private current(userId: string): number {
    return this.balances.get(userId) ?? this.initialBalance;
  }
}

/** In-memory stand-in for the Supabase-backed store. */
export class MemoryBlockStore implements BlockStore {
  rows: VoiceBlockRow[] = [];

  /** When set, every insert rejects with it (the failed-write paths). */
  constructor(private readonly failInsertWith?: Error) {}

  findLiveBlock(userId: string, now: Date): Promise<VoiceBlockRow | null> {
    const live = this.rows
      .filter((r) =>
        r.user_id === userId && !r.reconciled &&
        new Date(r.expires_at).getTime() > now.getTime()
      )
      .sort((a, b) => b.expires_at.localeCompare(a.expires_at))[0];
    return Promise.resolve(live ?? null);
  }

  retireExpired(userId: string, now: Date): Promise<void> {
    for (const row of this.rows) {
      if (
        row.user_id === userId && !row.reconciled &&
        new Date(row.expires_at).getTime() <= now.getTime()
      ) {
        row.reconciled = true;
      }
    }
    return Promise.resolve();
  }

  supersede(blockId: string): Promise<void> {
    const row = this.rows.find((r) => r.id === blockId);
    if (row) row.reconciled = true;
    return Promise.resolve();
  }

  countGrantsSince(userId: string, since: Date): Promise<number> {
    return Promise.resolve(
      this.rows.filter((r) =>
        r.user_id === userId &&
        new Date(r.granted_at).getTime() >= since.getTime()
      ).length,
    );
  }

  insert(
    row: Omit<VoiceBlockRow, "reconciled" | "streamed_secs" | "detections">,
  ): Promise<VoiceBlockRow> {
    if (this.failInsertWith) return Promise.reject(this.failInsertWith);
    // Mirrors the partial unique index on (user_id) where not reconciled.
    if (this.rows.some((r) => r.user_id === row.user_id && !r.reconciled)) {
      return Promise.reject(new BlockConflictError());
    }
    const full: VoiceBlockRow = {
      ...row,
      reconciled: false,
      streamed_secs: null,
      detections: null,
    };
    this.rows.push(full);
    return Promise.resolve(full);
  }

  findById(blockId: string, userId: string): Promise<VoiceBlockRow | null> {
    return Promise.resolve(
      this.rows.find((r) => r.id === blockId && r.user_id === userId) ?? null,
    );
  }

  reconcile(
    blockId: string,
    patch: { streamed_secs: number | null; detections: number | null },
  ): Promise<boolean> {
    const row = this.rows.find((r) => r.id === blockId);
    if (!row || row.reconciled) return Promise.resolve(false);
    Object.assign(row, patch, { reconciled: true });
    return Promise.resolve(true);
  }
}

export const CONFIG: HandlerConfig = {
  blockCredits: 5,
  blockSeconds: 300,
  tokenTtlSeconds: 30,
  refundWindowSeconds: 30,
  rateLimitMax: 6,
  rateLimitWindowMinutes: 10,
  // Small on purpose: a test that has to mint twenty tokens to reach the
  // limit is a test nobody reads.
  tokenMintMax: 4,
  tokenMintWindowMinutes: 5,
  trialCredits: 20,
  voucherAttemptMax: 3,
  voucherAttemptWindowMinutes: 60,
};

export interface Harness {
  deps: Deps;
  balance: FakeBalanceProvider;
  minter: FakeTokenMinter;
  blocks: MemoryBlockStore;
  trials: MemoryTrialStore;
  vouchers: MemoryVoucherStore;
  ios: FakeAttestor;
  android: FakeAttestor;
  logs: Array<{ event: string; fields: Record<string, unknown> }>;
  clock: { now: Date };
  /**
   * Waits for the work the handler deferred past the response (the DeviceCheck
   * bit write). A test that asserts on a claim without calling this is
   * asserting that the response did not wait for it.
   */
  settle: () => Promise<void>;
}

/**
 * A handler wired entirely to fakes. `initialBalance` seeds the default
 * balance provider and `campaigns` the default voucher store; every other key
 * overrides the corresponding dep, so an explicit `balance` and an
 * `initialBalance` cannot silently disagree.
 */
export function harness(
  options:
    & Partial<Deps>
    & { initialBalance?: number; campaigns?: MemoryVoucher[] } = {},
): Harness {
  const { initialBalance = 20, campaigns = [], ...overrides } = options;
  const balance = new FakeBalanceProvider(initialBalance);
  const minter = new FakeTokenMinter();
  const blocks = new MemoryBlockStore();
  const trials = new MemoryTrialStore();
  const logs: Harness["logs"] = [];
  const clock = { now: new Date("2026-09-07T12:00:00.000Z") };
  const pending: Array<Promise<unknown>> = [];
  const vouchers = new MemoryVoucherStore(campaigns, clock);
  const ios = new FakeAttestor("devicecheck");
  const android = androidAttestor();
  let seq = 0;
  const deps: Deps = {
    auth: new FakeAuth(),
    balance,
    minter,
    blocks,
    tokenLimiter: new MemoryRateLimiter(
      CONFIG.tokenMintMax,
      CONFIG.tokenMintWindowMinutes * 60_000,
    ),
    trials,
    vouchers,
    attestors: { ios, android },
    config: CONFIG,
    now: () => clock.now,
    newBlockId: () => `33333333-3333-4333-8333-${String(++seq).padStart(12, "0")}`,
    afterResponse: (work) => {
      pending.push(work);
    },
    log: (event, fields) => logs.push({ event, fields }),
    ...overrides,
  };
  // Read back off `deps`, not off the locals above. Returning the originals
  // meant an override was silently ignored by the harness — `h.ios.checks` in
  // a test that passed its own attestor asserted against a fake nothing had
  // called, and passed vacuously. The casts are the price: every override in
  // this suite is one of these doubles, and a test that overrides with
  // something else simply does not read the field back.
  return {
    deps,
    balance: deps.balance as FakeBalanceProvider,
    minter: deps.minter as FakeTokenMinter,
    blocks: deps.blocks as MemoryBlockStore,
    trials: deps.trials as MemoryTrialStore,
    vouchers: deps.vouchers as MemoryVoucherStore,
    ios: deps.attestors.ios as FakeAttestor,
    android: deps.attestors.android as FakeAttestor,
    logs,
    clock,
    settle: async () => {
      // Drained in a loop: deferred work may defer more.
      while (pending.length > 0) await Promise.all(pending.splice(0));
    },
  };
}

/**
 * Drives the router and reads the body — what every endpoint test does first,
 * declared identically in four of them before it lived here.
 */
export async function call(deps: Deps, req: Request) {
  const res = await handleVoiceBlock(req, deps);
  // deno-lint-ignore no-explicit-any -- test bodies are asserted field by field
  return { status: res.status, body: (await res.json()) as any };
}

/** A recorded outbound request. */
export interface Sent {
  url: string;
  init: RequestInit;
  /** The parsed JSON body, or {} for a form-encoded or empty one. */
  body: Record<string, unknown>;
  headers: Record<string, string>;
}

/** A canned answer, or a factory for one when the same call repeats. */
export type StubResponse = Response | (() => Response);

/**
 * A fetch stub that records what it was asked and answers from a script.
 *
 * Responses are returned in order and the last one repeats, which is what a
 * retry test wants — pass a factory for those, since a Response body can only
 * be read once. Five hand-rolled stubs counting their own calls and pushing
 * their own {url, init} pairs wanted exactly this.
 */
export function recorder(responses: readonly StubResponse[]) {
  const sent: Sent[] = [];
  const fetchFn: typeof fetch = (input, init) => {
    let body: Record<string, unknown> = {};
    try {
      // The token endpoint is form-encoded; every other call is JSON.
      body = JSON.parse(String(init?.body ?? "{}"));
    } catch {
      body = {};
    }
    sent.push({
      url: String(input),
      init: init ?? {},
      body,
      headers: (init?.headers ?? {}) as Record<string, string>,
    });
    const next = responses[sent.length - 1] ?? responses.at(-1)!;
    return Promise.resolve(typeof next === "function" ? next() : next);
  };
  return { sent, fetchFn };
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const BASE = "http://localhost:54321/functions/v1";

/** One request builder for both routes. Pass `null` for an anonymous call. */
export function req(
  path: string,
  body: unknown = {},
  token: string | null = GOOD_TOKEN,
): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

export const grantReq = (
  body: unknown = { session_id: SESSION },
  token: string | null = GOOD_TOKEN,
) => req("/voice-block", body, token);

export const releaseReq = (
  body: unknown,
  token: string | null = GOOD_TOKEN,
) => req("/voice-block/release", body, token);

export const tokenReq = (
  body: unknown,
  token: string | null = GOOD_TOKEN,
) => req("/voice-block/token", body, token);

// ---------------------------------------------------------------------------
// Trial (req 11) and vouchers (req 12)

export const OTHER_USER = "66666666-6666-4666-8666-666666666666";
export const DEVICE_TOKEN = "fake-device-token";
export const INTEGRITY_TOKEN = "fake-integrity-token";

/**
 * A gate that answers from memory.
 *
 * `claimed` stands in for whatever the platform durably holds — Apple's bit
 * for a device, nothing at all on Android — so a test can assert that a claim
 * actually reached it. `failWith` is how the refusal paths are exercised:
 * an AttestationError for a verdict, a ProviderError for an unreachable one.
 */
export class FakeAttestor implements DeviceAttestor {
  /** Whatever the real adapter for this gate reads (types.ts). */
  readonly tokenField: string;
  readonly checks: string[] = [];
  readonly claims: string[] = [];
  /** Devices that have already taken the trial (iOS: the bit is set). */
  readonly claimed = new Set<string>();

  constructor(
    readonly gate: TrialGate = "devicecheck",
    private readonly options: {
      failWith?: Error;
      /** While positive, the next claim() rejects and this decrements. */
      failClaims?: number;
      /** Android has nowhere to write a claim, so claim() records nothing. */
      records?: boolean;
      /**
       * claim() does not settle until releaseClaims() is called — which is
       * how "the bit was written *after* the response" is provable rather
       * than merely likely. A handler that awaited it would never answer.
       */
      hold?: boolean;
    } = {},
  ) {
    this.tokenField = gate === "devicecheck" ? "device_token" : "integrity_token";
  }

  /** Lets a held claim finish; see the `hold` option. */
  releaseClaims(): void {
    this.release?.();
    this.release = undefined;
  }

  private release?: () => void;

  check(attestation: string): Promise<DeviceAttestation> {
    this.checks.push(attestation);
    if (this.options.failWith) return Promise.reject(this.options.failWith);
    return Promise.resolve({
      eligible: !this.claimed.has(attestation),
      claim: async () => {
        this.claims.push(attestation);
        if (this.options.hold) {
          await new Promise<void>((resolve) => {
            this.release = resolve;
          });
        }
        if ((this.options.failClaims ?? 0) > 0) {
          this.options.failClaims!--;
          throw new Error("bit write failed");
        }
        if (this.options.records !== false) this.claimed.add(attestation);
      },
    });
  }
}

/** Play Integrity's shape: a verdict, and nowhere to record a claim. */
export function androidAttestor(options: { failWith?: Error } = {}) {
  return new FakeAttestor("play_integrity", { ...options, records: false });
}

export class MemoryTrialStore implements TrialStore {
  rows: TrialGrantRow[] = [];

  constructor(private readonly failInsertWith?: Error) {}

  find(userId: string): Promise<TrialGrantRow | null> {
    return Promise.resolve(this.rows.find((r) => r.user_id === userId) ?? null);
  }

  insert(row: Omit<TrialGrantRow, "granted_at">): Promise<TrialGrantRow | null> {
    if (this.failInsertWith) return Promise.reject(this.failInsertWith);
    // Mirrors the primary key on user_id, which is what makes a retried grant
    // idempotent (req 11.8).
    if (this.rows.some((r) => r.user_id === row.user_id)) {
      return Promise.resolve(null);
    }
    const full: TrialGrantRow = {
      ...row,
      granted_at: "2026-09-07T12:00:00.000Z",
    };
    this.rows.push(full);
    return Promise.resolve(full);
  }
}

export interface MemoryVoucher {
  id: string;
  code: string;
  credits: number;
  max_redemptions: number;
  redeemed_count: number;
  expires_at: string | null;
  enabled: boolean;
}

/**
 * In-memory stand-in for counta.redeem_voucher.
 *
 * It reproduces the *decisions* the SQL function makes and the order it makes
 * them in, not the transaction — a single-threaded fake cannot tear a
 * transaction apart, so the ordering assertions here are about which answer
 * comes out and what is left behind, and the atomicity itself is the
 * database's job (design: Edge Function contract).
 */
export class MemoryVoucherStore implements VoucherStore {
  readonly attempts: Array<{ user_id: string; at: Date }> = [];
  readonly redemptions: Array<
    {
      id: string;
      voucher_id: string;
      user_id: string;
      credits: number;
      credited: boolean;
    }
  > = [];
  private seq = 0;

  constructor(
    readonly vouchers: MemoryVoucher[] = [],
    private readonly clock: { now: Date } = { now: new Date() },
  ) {}

  attemptsSince(
    userId: string,
    since: Date,
  ): Promise<{ count: number; oldest: Date | null }> {
    const inWindow = this.attempts
      .filter((a) => a.user_id === userId && a.at.getTime() >= since.getTime())
      .sort((a, b) => a.at.getTime() - b.at.getTime());
    return Promise.resolve({
      count: inWindow.length,
      oldest: inWindow[0]?.at ?? null,
    });
  }

  recordAttempt(userId: string): Promise<void> {
    this.attempts.push({ user_id: userId, at: this.clock.now });
    return Promise.resolve();
  }

  redeem(code: string, userId: string): Promise<RedeemOutcome> {
    const voucher = this.vouchers.find(
      (v) => v.code.toUpperCase() === code.toUpperCase(),
    );
    if (!voucher) return Promise.resolve({ outcome: "not_found" });

    const existing = this.redemptions.find(
      (r) => r.voucher_id === voucher.id && r.user_id === userId,
    );
    if (existing) {
      return Promise.resolve({
        outcome: "already_redeemed",
        voucher_id: voucher.id,
        redemption_id: existing.id,
        credits: existing.credits,
        credited: existing.credited,
      });
    }

    // Disabled is indistinguishable from unknown (req 12.6), and is checked
    // after the existing redemption for the same reason the SQL does.
    if (!voucher.enabled) return Promise.resolve({ outcome: "not_found" });

    if (
      voucher.expires_at !== null &&
      new Date(voucher.expires_at).getTime() <= this.clock.now.getTime()
    ) {
      return Promise.resolve({ outcome: "expired" });
    }

    if (voucher.redeemed_count >= voucher.max_redemptions) {
      return Promise.resolve({ outcome: "exhausted" });
    }

    // Slot first, then the row: the order the function takes, and the one that
    // errs towards under-granting if they ever come apart.
    voucher.redeemed_count++;
    const redemption = {
      id: `77777777-7777-4777-8777-${String(++this.seq).padStart(12, "0")}`,
      voucher_id: voucher.id,
      user_id: userId,
      credits: voucher.credits,
      credited: false,
    };
    this.redemptions.push(redemption);
    return Promise.resolve({
      outcome: "redeemed",
      voucher_id: voucher.id,
      redemption_id: redemption.id,
      credits: redemption.credits,
      credited: false,
    });
  }

  /** While positive, the next markCredited rejects and this decrements. */
  failCredited = 0;

  markCredited(redemptionId: string): Promise<void> {
    if (this.failCredited > 0) {
      this.failCredited--;
      return Promise.reject(
        new Error("counta.voucher_redemptions credited: boom"),
      );
    }
    const row = this.redemptions.find((r) => r.id === redemptionId);
    if (row) row.credited = true;
    return Promise.resolve();
  }
}

export const VOUCHER_ID = "88888888-8888-4888-8888-888888888888";

/** A live campaign: 50 credits, 2 redemptions, no expiry. */
export function voucher(overrides: Partial<MemoryVoucher> = {}): MemoryVoucher {
  return {
    id: VOUCHER_ID,
    code: "SPRING24",
    credits: 50,
    max_redemptions: 2,
    redeemed_count: 0,
    expires_at: null,
    enabled: true,
    ...overrides,
  };
}

export const trialReq = (
  body: unknown = { platform: "ios", device_token: DEVICE_TOKEN },
  token: string | null = GOOD_TOKEN,
) => req("/voice-block/trial", body, token);

export const redeemReq = (
  body: unknown = { code: "SPRING24" },
  token: string | null = GOOD_TOKEN,
) => req("/voice-block/redeem", body, token);
