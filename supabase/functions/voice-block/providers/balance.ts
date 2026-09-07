import { BalanceProvider, ProviderError } from "../types.ts";
import { providerFetch } from "./http.ts";

const BASE_URL = "https://api.revenuecat.com/v2";

/**
 * Retries after a 429 on a write before giving up. The design caps this at 2.
 * Reads are never retried: `getBalance` runs before any money moves, so
 * failing fast to 503 costs the caller a retry, while sleeping costs the whole
 * request the seconds it has left.
 */
const MAX_WRITE_RETRIES = 2;

/**
 * Ceiling on a single backoff. RevenueCat can answer a 429 with a
 * `Retry-After` of a minute; honouring that would hold the request open long
 * past the 30 s life of the Deepgram token this call exists to mint, so the
 * client would receive a token that is already dead. Cap it and let the client
 * retry the whole request instead.
 */
const MAX_BACKOFF_MS = 2_000;

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
      { retries: 0 },
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
        body: { adjustments: { [this.opts.currencyCode]: delta }, reference },
        idempotencyKey: reference,
        retries: MAX_WRITE_RETRIES,
      },
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
    opts: { body?: unknown; idempotencyKey?: string; retries: number },
  ): Promise<T> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.opts.secretKey}`,
      Accept: "application/json",
    };
    if (opts.body !== undefined) headers["Content-Type"] = "application/json";
    if (opts.idempotencyKey) {
      headers["Idempotency-Key"] = opts.idempotencyKey;
    }

    for (let attempt = 0;; attempt++) {
      try {
        const response = await providerFetch(
          "revenuecat",
          this.fetchFn,
          `${BASE_URL}${path}`,
          {
            method,
            headers,
            body: opts.body === undefined
              ? undefined
              : JSON.stringify(opts.body),
          },
        );
        return (await response.json()) as T;
      } catch (error) {
        if (
          !(error instanceof ProviderError) ||
          error.reason !== "rate_limited" ||
          attempt >= opts.retries
        ) {
          throw error;
        }
        await this.sleep(
          Math.min(error.retryAfterMs ?? 250 * 2 ** attempt, MAX_BACKOFF_MS),
        );
      }
    }
  }
}
