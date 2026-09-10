// Ports the voice-block handler depends on. The handler is a pure function of
// (request, deps) so every collaborator here has a fake for tests and a real
// adapter for production (see providers/ and store.ts).

/** Why an upstream provider call failed. */
export type ProviderFailure = "rate_limited" | "unavailable";

/**
 * Any upstream failure the handler surfaces as 503 rather than as a credit
 * error (design: Security). One class rather than two because the handler
 * treats every failure identically; `reason` exists for the caller that does
 * care — the RevenueCat write path, which retries a 429 and nothing else.
 */
export class ProviderError extends Error {
  constructor(
    readonly reason: ProviderFailure,
    message: string,
    /** `Retry-After` in milliseconds, when the upstream sent one. */
    readonly retryAfterMs?: number,
  ) {
    super(message);
    this.name = "ProviderError";
  }
}

/**
 * Thrown by BlockStore.insert when the database's one-live-block unique index
 * rejects the row: another request won the race. Distinct from a ProviderError
 * because the caller's answer is 409, not 503.
 */
export class BlockConflictError extends Error {
  constructor(message = "block already in flight") {
    super(message);
    this.name = "BlockConflictError";
  }
}

export interface BalanceProvider {
  /** Current credit balance for the user. */
  getBalance(userId: string): Promise<number>;
  /**
   * Debits a block's cost. Resolves to the balance after the debit.
   *
   * Keyed on `blockId`, not on the attempt: the ledger call carries it as the
   * idempotency key, so a client (or a proxy) that retries a grant it never
   * saw the answer to is charged once.
   */
  spend(userId: string, blockId: string, credits: number): Promise<number>;
  /**
   * Credits a block's cost back. Resolves to the balance after the refund.
   *
   * Separate from a general "grant credits" so that both refund sites — the
   * mint failure in grant() and the eligible release — are the same keyed
   * operation, and so a retry of either refunds exactly once.
   */
  refund(userId: string, blockId: string, credits: number): Promise<number>;
  /**
   * Credits an award that is not a block refund: the device-gated trial and
   * voucher redemptions. Resolves to the balance after the grant.
   *
   * `reference` is the caller's stable identity for the award — the user id
   * for a trial, the redemption id for a voucher — and is both the ledger
   * reference and the idempotency key. A retry therefore re-issues the *same*
   * grant rather than a second one, which is what lets an award whose ledger
   * call died mid-flight finish on the next attempt without ever paying twice
   * (reqs 11.8, 12.5).
   *
   * Kept separate from `refund` so a grep for who hands out new credit finds
   * two sites and not every balance movement.
   */
  grant(userId: string, reference: string, credits: number): Promise<number>;
}

export interface TokenMinter {
  /** Resolves to a short-lived streaming token. */
  mint(ttlSeconds: number): Promise<string>;
}

export interface VoiceBlockRow {
  id: string;
  user_id: string;
  session_id: string;
  credits: number;
  granted_at: string; // ISO timestamp
  expires_at: string; // ISO timestamp
  reconciled: boolean;
  streamed_secs: number | null;
  detections: number | null;
}

export interface BlockStore {
  /** The user's unreconciled, unexpired block, if any. */
  findLiveBlock(userId: string, now: Date): Promise<VoiceBlockRow | null>;
  /**
   * Marks a block reconciled because a renewal has replaced it. Distinct from
   * `reconcile`, which records a client's usage report; a superseded block was
   * never released and has no report to record.
   */
  supersede(blockId: string): Promise<void>;
  /** Number of blocks granted to the user since `since` (rate limiting). */
  countGrantsSince(userId: string, since: Date): Promise<number>;
  /**
   * Reconciles the user's unreconciled blocks that have already expired.
   *
   * A client that died mid-block never called /release, so its row stays
   * unreconciled and would collide with the one-live-block unique index for
   * ever. Nothing is refundable by then — an expired block is far outside the
   * refund window — so retiring it is safe.
   */
  retireExpired(userId: string, now: Date): Promise<void>;
  /**
   * Inserts the row under the caller-supplied id (see BalanceProvider.spend).
   * Rejects with BlockConflictError when the user already has a live block.
   */
  insert(
    row: Omit<VoiceBlockRow, "reconciled" | "streamed_secs" | "detections">,
  ): Promise<VoiceBlockRow>;
  findById(blockId: string, userId: string): Promise<VoiceBlockRow | null>;
  /**
   * Marks a block reconciled with its usage report. Resolves true only when
   * this call flipped `reconciled` from false to true, so concurrent releases
   * cannot both refund.
   */
  reconcile(
    blockId: string,
    patch: { streamed_secs: number | null; detections: number | null },
  ): Promise<boolean>;
}

/**
 * A budget on a route that writes nothing and so has no rows to count.
 *
 * One method, deliberately: `allow` both asks and records, because a limiter
 * that separates the two invites a caller to check and then forget to charge.
 * `ratelimit.ts` holds the only implementation; it is a port so tests can
 * drive the window without a clock.
 */
export interface RateLimiter {
  /** Records this hit and reports whether it is within budget. */
  allow(key: string, now: Date): boolean;
}

export interface Authenticator {
  /** Resolves the Supabase user id for a bearer token, or null if invalid. */
  userIdForToken(token: string): Promise<string | null>;
}

export interface HandlerConfig {
  blockCredits: number;
  blockSeconds: number;
  tokenTtlSeconds: number;
  refundWindowSeconds: number;
  rateLimitMax: number;
  rateLimitWindowMinutes: number;
  /** Token mints allowed per user per window on /token. */
  tokenMintMax: number;
  tokenMintWindowMinutes: number;
  /** Credits the one-per-device trial pays out (req 4.3). */
  trialCredits: number;
  /** Failed voucher redemptions allowed per user per window (req 12.8). */
  voucherAttemptMax: number;
  voucherAttemptWindowMinutes: number;
}

export interface Deps {
  auth: Authenticator;
  balance: BalanceProvider;
  minter: TokenMinter;
  blocks: BlockStore;
  /** Budget for /token, which mints a credential but writes no row. */
  tokenLimiter: RateLimiter;
  trials: TrialStore;
  vouchers: VoucherStore;
  /**
   * The attestation gate for each platform that has one. A platform missing
   * from this map is not offered the trial (req 11.10) — which is also how an
   * operator who has configured no Apple or Google credentials ends up with
   * the trial off rather than with an endpoint that always 503s.
   */
  attestors: Partial<Record<TrialPlatform, DeviceAttestor>>;
  config: HandlerConfig;
  /** Injected so tests control time; both constructors always supply it. */
  now: () => Date;
  /** New block id, minted before the debit so the ledger can be keyed on it. */
  newBlockId: () => string;
  log: LogFn;
}

/** One structured log line. Every event in this function goes through it. */
export type LogFn = (event: string, fields: Record<string, unknown>) => void;

// ---------------------------------------------------------------------------
// Trial (req 11) and vouchers (req 12)

/** The two platforms that offer a device attestation (req 11.10). */
export type TrialPlatform = "ios" | "android";

/** Which attestation decided a grant; recorded on counta.trial_grants.gate. */
export type TrialGate = "devicecheck" | "play_integrity";

/** Why an attestation did not clear. */
export type AttestationFailure =
  /**
   * The provider read the payload and said no. The same token will never
   * pass, so the client must not retry it (design: Error Handling -> 400).
   */
  | "rejected"
  /**
   * The provider answered, but not with a verdict — an UNEVALUATED field, a
   * missing verdict, a body that does not parse. Req 11.9: refuse without
   * granting, and tell the client the check can be retried.
   */
  | "indeterminate";

/**
 * A verdict-level attestation failure, as opposed to a transport one. An
 * unreachable provider still throws ProviderError from providerFetch; both
 * refuse the trial, but only this one can distinguish "Apple says this token
 * is junk" (400, never retry it) from "nobody could decide" (503, do retry).
 */
export class AttestationError extends Error {
  constructor(readonly failure: AttestationFailure, message: string) {
    super(message);
    this.name = "AttestationError";
  }
}

export interface DeviceAttestation {
  /** Whether this device may claim the trial. */
  eligible: boolean;
  /**
   * Records the claim where the platform will enforce it next time: iOS sets
   * the allocated DeviceCheck bit, Android has nowhere to write one and does
   * nothing. Called only after the credits are granted, so a failure between
   * the two costs the operator one extra trial rather than silently burning a
   * device's only claim (design: "iOS: DeviceCheck").
   */
  claim(): Promise<void>;
}

/**
 * A platform's answer to "may this device take the trial?".
 *
 * Shaped like BalanceProvider and TokenMinter — one port, a real adapter per
 * platform under providers/, fakes under testing/ — so the handler is testable
 * without Apple or Google, and so the deployed bundle can only ever construct
 * the real ones.
 */
export interface DeviceAttestor {
  /** Recorded on the grant row. */
  readonly gate: TrialGate;
  /**
   * The request-body field this platform's attestation arrives in —
   * `device_token` for DeviceCheck, `integrity_token` for Play Integrity.
   *
   * On the port beside `gate` because it is a fact about this adapter's
   * protocol, not about the endpoint. The handler used to hold its own table
   * of it, next to its own list of supported platforms, next to the keys of
   * the injected map: three statements of the same thing, and a third platform
   * would have had to be added to all three. Now it touches index.ts and its
   * adapter.
   */
  readonly tokenField: string;
  /**
   * Rejects with AttestationError for a verdict-level refusal and with
   * ProviderError when the provider could not be reached at all.
   */
  check(attestation: string): Promise<DeviceAttestation>;
}

export interface TrialGrantRow {
  user_id: string;
  platform: TrialPlatform;
  gate: TrialGate;
  credits: number;
  granted_at: string; // ISO timestamp
}

export interface TrialStore {
  find(userId: string): Promise<TrialGrantRow | null>;
  /**
   * Inserts the grant. Resolves null when the row already exists: the primary
   * key on user_id is what makes a retried grant idempotent (req 11.8).
   */
  insert(row: Omit<TrialGrantRow, "granted_at">): Promise<TrialGrantRow | null>;
}

/**
 * What counta.redeem_voucher decided, in one round trip.
 *
 * The whole decision is one Postgres function because the slot claim and the
 * redemption row must not come apart: a leaked slot under-grants a campaign,
 * while a redemption row with no slot behind it lets the cap be exceeded
 * (design: Edge Function contract).
 *
 * `not_found` deliberately covers both an unknown and a disabled code, so the
 * endpoint cannot be used to discover which codes exist (req 12.6).
 */
export type RedeemOutcome =
  | ({ outcome: "redeemed" } & Redemption)
  | ({ outcome: "already_redeemed" } & Redemption)
  | { outcome: "not_found" }
  | { outcome: "expired" }
  | { outcome: "exhausted" };

/** The redemption behind a `redeemed` or `already_redeemed` outcome. */
export interface Redemption {
  voucher_id: string;
  redemption_id: string;
  credits: number;
  /**
   * Whether this redemption's payout is already confirmed
   * (`counta.voucher_redemptions.credited_at`).
   *
   * The endpoint must not ask the ledger this question. RevenueCat's
   * `Idempotency-Key` is what makes a re-issued grant a no-op, and those keys
   * expire on a bounded window; treating "the ledger will deduplicate it" as
   * "it pays once" credited a resubmitted code again every time, once the
   * window had passed. False re-issues the *same* keyed grant so a redemption
   * whose ledger call died mid-flight still heals (req 12.5); true pays
   * nothing.
   */
  credited: boolean;
}

export interface VoucherStore {
  /**
   * Failed attempts by this user since `since`, with the oldest of them so a
   * 429 can say when the window clears (req 12.8).
   */
  attemptsSince(
    userId: string,
    since: Date,
  ): Promise<{ count: number; oldest: Date | null }>;
  recordAttempt(userId: string): Promise<void>;
  /** Claims a slot and writes the redemption in one transaction. */
  redeem(code: string, userId: string): Promise<RedeemOutcome>;
  /**
   * Records that this redemption's grant reached the ledger. Called after the
   * grant, never before: a row marked credited by a payout that then failed
   * would be a redemption nothing can ever complete.
   */
  markCredited(redemptionId: string): Promise<void>;
}
