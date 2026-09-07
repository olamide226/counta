import {
  BalanceProvider,
  ProviderRateLimitedError,
  ProviderUnavailableError,
} from "../types.ts";

/** In-memory balances. Used by tests and by `BALANCE_PROVIDER=fake` for local
 * development before RevenueCat exists (task 10). State lives for the life of
 * the worker only. */
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

export interface RevenueCatOptions {
  secretKey: string;
  projectId: string;
  currencyCode: string;
  baseUrl?: string;
  fetch?: typeof fetch;
  /** Retries after a 429 before giving up. Design caps this at 2. */
  maxRetries?: number;
  /** Injected so tests do not sleep. */
  sleep?: (ms: number) => Promise<void>;
}

interface VirtualCurrencyList {
  items?: Array<{ currency_code?: string; balance?: number }>;
}

/**
 * RevenueCat Developer API v2 virtual currency ledger. The Supabase user id is
 * the RevenueCat customer id (the client identifies the SDK with it, task 10.3).
 *
 * Endpoints (https://www.revenuecat.com/docs/api-v2/customer/resources):
 *   GET  /projects/{p}/customers/{c}/virtual_currencies?include_empty_balances=true
 *   POST /projects/{p}/customers/{c}/virtual_currencies/transactions
 *        { adjustments: { [code]: delta }, reference }
 * Both live in the Virtual Currencies domain, rate limited to 480 req/min.
 */
export class RevenueCatBalanceProvider implements BalanceProvider {
  private readonly baseUrl: string;
  private readonly fetchFn: typeof fetch;
  private readonly maxRetries: number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private readonly opts: RevenueCatOptions) {
    this.baseUrl = opts.baseUrl ?? "https://api.revenuecat.com/v2";
    this.fetchFn = opts.fetch ?? fetch;
    this.maxRetries = Math.min(opts.maxRetries ?? 2, 2);
    this.sleep = opts.sleep ??
      ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  }

  async getBalance(userId: string): Promise<number> {
    const list = await this.request<VirtualCurrencyList>(
      "GET",
      `${this.customerPath(userId)}/virtual_currencies?include_empty_balances=true`,
    );
    return this.balanceFrom(list);
  }

  spend(userId: string, amount: number, reference: string): Promise<number> {
    return this.adjust(userId, -Math.abs(amount), reference);
  }

  grant(userId: string, amount: number, reference: string): Promise<number> {
    return this.adjust(userId, Math.abs(amount), reference);
  }

  private async adjust(
    userId: string,
    delta: number,
    reference: string,
  ): Promise<number> {
    const list = await this.request<VirtualCurrencyList>(
      "POST",
      `${this.customerPath(userId)}/virtual_currencies/transactions?include_empty_balances=true`,
      {
        adjustments: { [this.opts.currencyCode]: delta },
        reference,
      },
      reference,
    );
    return this.balanceFrom(list);
  }

  private customerPath(userId: string): string {
    return `/projects/${encodeURIComponent(this.opts.projectId)}/customers/${
      encodeURIComponent(userId)
    }`;
  }

  private balanceFrom(list: VirtualCurrencyList): number {
    const match = (list.items ?? []).find(
      (item) => item.currency_code === this.opts.currencyCode,
    );
    return match?.balance ?? 0;
  }

  private async request<T>(
    method: "GET" | "POST",
    path: string,
    body?: unknown,
    idempotencyKey?: string,
  ): Promise<T> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.opts.secretKey}`,
      Accept: "application/json",
    };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;

    for (let attempt = 0; ; attempt++) {
      let response: Response;
      try {
        response = await this.fetchFn(`${this.baseUrl}${path}`, {
          method,
          headers,
          body: body === undefined ? undefined : JSON.stringify(body),
        });
      } catch (error) {
        throw new ProviderUnavailableError(`revenuecat: ${String(error)}`);
      }

      if (response.status === 429) {
        if (attempt >= this.maxRetries) {
          throw new ProviderRateLimitedError("revenuecat: 429 after retries");
        }
        const retryAfter = Number(response.headers.get("Retry-After"));
        const backoffMs = Number.isFinite(retryAfter) && retryAfter > 0
          ? retryAfter * 1000
          : 250 * 2 ** attempt;
        await this.sleep(backoffMs);
        continue;
      }

      if (!response.ok) {
        throw new ProviderUnavailableError(
          `revenuecat: ${method} ${path} -> ${response.status}`,
        );
      }
      return (await response.json()) as T;
    }
  }
}
