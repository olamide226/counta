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

export interface BalanceProvider {
  /** Current credit balance for the user. */
  getBalance(userId: string): Promise<number>;
  /** Debit `amount` credits. Resolves to the balance after the debit. */
  spend(userId: string, amount: number, reference: string): Promise<number>;
  /** Credit `amount` credits. Resolves to the balance after the grant. */
  grant(userId: string, amount: number, reference: string): Promise<number>;
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
  /** Unreconciled block for the user that expires after `notBefore`. */
  findLiveBlock(userId: string, notBefore: Date): Promise<VoiceBlockRow | null>;
  /** Number of blocks granted to the user since `since` (rate limiting). */
  countGrantsSince(userId: string, since: Date): Promise<number>;
  insert(
    row: Omit<VoiceBlockRow, "id" | "reconciled" | "streamed_secs" | "detections">,
  ): Promise<VoiceBlockRow>;
  findById(blockId: string, userId: string): Promise<VoiceBlockRow | null>;
  /**
   * Marks a block reconciled with its usage report. Resolves true only when
   * this call flipped `reconciled` from false to true, so concurrent releases
   * cannot both refund.
   */
  reconcile(
    blockId: string,
    patch: { streamed_secs: number; detections: number },
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
  renewalOverlapSeconds: number;
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
  log: (event: string, fields: Record<string, unknown>) => void;
}
