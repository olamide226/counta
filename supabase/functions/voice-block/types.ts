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
}

export interface Deps {
  auth: Authenticator;
  balance: BalanceProvider;
  minter: TokenMinter;
  blocks: BlockStore;
  config: HandlerConfig;
  /** Injected so tests control time; both constructors always supply it. */
  now: () => Date;
  /** New block id, minted before the debit so the ledger can be keyed on it. */
  newBlockId: () => string;
  log: (event: string, fields: Record<string, unknown>) => void;
}
