import { BalanceProvider, ProviderError } from "../types.ts";
import { providerFetch } from "./http.ts";

const BASE_URL = "https://api.revenuecat.com/v2";

/** Retries after a 429 before giving up. The design caps this at 2. */
const MAX_RETRIES = 2;

export interface RevenueCatOptions {
  secretKey: string;
  projectId: string;
  currencyCode: string;
  fetch?: typeof fetch;
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
  private readonly fetchFn: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private readonly opts: RevenueCatOptions) {
    this.fetchFn = opts.fetch ?? fetch;
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

    for (let attempt = 0;; attempt++) {
      try {
        const response = await providerFetch(
          "revenuecat",
          this.fetchFn,
          `${BASE_URL}${path}`,
          {
            method,
            headers,
            body: body === undefined ? undefined : JSON.stringify(body),
          },
        );
        return (await response.json()) as T;
      } catch (error) {
        const retryable = error instanceof ProviderError &&
          error.reason === "rate_limited" && attempt < MAX_RETRIES;
        if (!retryable) throw error;
        const wait = (error as ProviderError).retryAfterMs ??
          250 * 2 ** attempt;
        await this.sleep(wait);
      }
    }
  }
}
