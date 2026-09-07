// Test doubles for the voice-block handler.
//
// Deliberately NOT imported by index.ts: a fake balance provider reachable from
// the deployed bundle is one env typo away from giving every caller free
// streaming, so the deployed function can only ever construct the real
// adapters. Nothing outside index_test.ts should import this file.

import type {
  Authenticator,
  BalanceProvider,
  BlockStore,
  Deps,
  HandlerConfig,
  TokenMinter,
  VoiceBlockRow,
} from "../types.ts";

export const USER = "11111111-1111-4111-8111-111111111111";
export const SESSION = "22222222-2222-4222-8222-222222222222";
export const GOOD_TOKEN = "good-jwt";

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
    return Promise.resolve(token === GOOD_TOKEN ? USER : null);
  }
}

/** In-memory balances. State lives for the life of the instance. */
export class FakeBalanceProvider implements BalanceProvider {
  readonly balances = new Map<string, number>();
  readonly calls: Array<{ op: string; userId: string; amount?: number }> = [];

  constructor(private readonly initialBalance = 20) {}

  getBalance(userId: string): Promise<number> {
    this.calls.push({ op: "get", userId });
    return Promise.resolve(this.current(userId));
  }

  spend(userId: string, amount: number): Promise<number> {
    this.calls.push({ op: "spend", userId, amount });
    const next = this.current(userId) - amount;
    this.balances.set(userId, next);
    return Promise.resolve(next);
  }

  grant(userId: string, amount: number): Promise<number> {
    this.calls.push({ op: "grant", userId, amount });
    const next = this.current(userId) + amount;
    this.balances.set(userId, next);
    return Promise.resolve(next);
  }

  private current(userId: string): number {
    return this.balances.get(userId) ?? this.initialBalance;
  }
}

/** In-memory stand-in for the Supabase-backed store. */
export class MemoryBlockStore implements BlockStore {
  rows: VoiceBlockRow[] = [];
  private seq = 0;

  findLiveBlock(userId: string, notBefore: Date): Promise<VoiceBlockRow | null> {
    const live = this.rows
      .filter((r) =>
        r.user_id === userId && !r.reconciled &&
        new Date(r.expires_at).getTime() > notBefore.getTime()
      )
      .sort((a, b) => b.expires_at.localeCompare(a.expires_at))[0];
    return Promise.resolve(live ?? null);
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
    row: Omit<
      VoiceBlockRow,
      "id" | "reconciled" | "streamed_secs" | "detections"
    >,
  ): Promise<VoiceBlockRow> {
    this.seq++;
    const full: VoiceBlockRow = {
      ...row,
      id: `33333333-3333-4333-8333-${String(this.seq).padStart(12, "0")}`,
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
    patch: { streamed_secs: number; detections: number },
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
  renewalOverlapSeconds: 30,
  rateLimitMax: 6,
  rateLimitWindowMinutes: 10,
};

export interface Harness {
  deps: Deps;
  balance: FakeBalanceProvider;
  minter: FakeTokenMinter;
  blocks: MemoryBlockStore;
  logs: Array<{ event: string; fields: Record<string, unknown> }>;
  clock: { now: Date };
}

/**
 * A handler wired entirely to fakes. `initialBalance` seeds the default
 * balance provider; every other key overrides the corresponding dep, so an
 * explicit `balance` and an `initialBalance` cannot silently disagree.
 */
export function harness(
  options: Partial<Deps> & { initialBalance?: number } = {},
): Harness {
  const { initialBalance = 20, ...overrides } = options;
  const balance = new FakeBalanceProvider(initialBalance);
  const minter = new FakeTokenMinter();
  const blocks = new MemoryBlockStore();
  const logs: Harness["logs"] = [];
  const clock = { now: new Date("2026-09-07T12:00:00.000Z") };
  const deps: Deps = {
    auth: new FakeAuth(),
    balance,
    minter,
    blocks,
    config: CONFIG,
    now: () => clock.now,
    log: (event, fields) => logs.push({ event, fields }),
    ...overrides,
  };
  return { deps, balance, minter, blocks, logs, clock };
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
