// Ports the voice-block handler depends on. The handler is a pure function of
// (request, deps) so every collaborator here has a fake for tests and a real
// adapter for production (see providers/ and store.ts).

/** Thrown by a provider when the upstream rate-limits us (HTTP 429). The
 * handler maps it to 503 rather than a credit error (design: Security). */
export class ProviderRateLimitedError extends Error {
  constructor(message = "provider rate limited") {
    super(message);
    this.name = "ProviderRateLimitedError";
  }
}

/** Any other upstream failure the handler should surface as 503. */
export class ProviderUnavailableError extends Error {
  constructor(message = "provider unavailable") {
    super(message);
    this.name = "ProviderUnavailableError";
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

export interface MintedToken {
  token: string;
  expiresInSeconds: number;
}

export interface TokenMinter {
  mint(ttlSeconds: number): Promise<MintedToken>;
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
  now?: () => Date;
  log?: (event: string, fields: Record<string, unknown>) => void;
}
