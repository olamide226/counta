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

/**
 * Pages of the balance list to walk before giving up. A project has a handful
 * of virtual currencies, so this is only ever a bound on a runaway cursor.
 */
const MAX_BALANCE_PAGES = 5;

/**
 * RevenueCat has no record of this customer.
 *
 * Not a failure of the provider. A customer exists there only once something
 * creates it — the SDK identifying a user, or this function — so every
 * first-time user starts out unknown. Kept apart from ProviderError because
 * the right answers are "zero credits" on a read and "create them" on a grant,
 * neither of which is a 503.
 */
class CustomerMissing extends Error {}

/**
 * Whether a 404 body says the *customer* is what was not found.
 *
 * A 404 can also mean the project id is wrong. Reading that as an empty
 * balance would answer every user with "insufficient credit" and hide a
 * misconfiguration behind a plausible-looking 402, so only RevenueCat's own
 * statement that the customer is missing counts.
 */
function isMissingCustomer(body: unknown): boolean {
  const error = body as { type?: unknown; param?: unknown; message?: unknown };
  return error?.type === "resource_missing" &&
    (error.param === "customer_id" || /customer/i.test(String(error.message)));
}

export interface RevenueCatOptions {
  secretKey: string;
  projectId: string;
  currencyCode: string;
  fetch?: typeof fetch;
  /** Injected so tests do not sleep. */
  sleep?: (ms: number) => Promise<void>;
}

/**
 * `object: "list"` of `virtual_currency_balance` items, per the documented
 * example response. `next_page` is a path relative to the host, already
 * carrying `/v2` and the `starting_after` cursor.
 */
interface VirtualCurrencyList {
  items?: Array<{ currency_code?: string; balance?: number }>;
  next_page?: string | null;
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
 * The transactions response is the same balance list as the GET, so a write
 * reports the balance it produced without a second round trip.
 */
export class RevenueCatBalanceProvider implements BalanceProvider {
  private readonly fetchFn: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private readonly opts: RevenueCatOptions) {
    this.fetchFn = opts.fetch ?? fetch;
    this.sleep = opts.sleep ??
      ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  }

  /**
   * The balance list is paginated, and a currency that fell onto page two
   * would otherwise read as a zero balance — which fails every grant with a
   * 402 that no amount of buying credit would fix. `include_empty_balances`
   * keeps the currency present even at zero, `limit` makes a second page
   * unlikely, and the cursor is followed for the case where it happens anyway.
   */
  async getBalance(userId: string): Promise<number> {
    try {
      return await this.readBalance(
        `${
          this.customerPath(userId)
        }/virtual_currencies?include_empty_balances=true&limit=100`,
      );
    } catch (error) {
      // Someone RevenueCat has never seen holds no credits. Answering that as
      // an outage told every first-time user the service was down, when the
      // true answer — and the one the handler turns into a 402 — is zero.
      // Reading must not create the customer: a balance check is not a reason
      // to write to the ledger.
      if (error instanceof CustomerMissing) return 0;
      throw error;
    }
  }

  spend(userId: string, blockId: string, credits: number): Promise<number> {
    return this.adjust(userId, -Math.abs(credits), `voice-block:${blockId}`);
  }

  refund(userId: string, blockId: string, credits: number): Promise<number> {
    return this.adjust(
      userId,
      Math.abs(credits),
      `voice-block:${blockId}:refund`,
    );
  }

  /**
   * Credits a user who may be unknown to RevenueCat — which a trial or a
   * voucher almost always is, being the first thing a new user does.
   *
   * RevenueCat refuses a transaction for a customer it has not seen, so the
   * customer is created first. Done up front rather than as a retry after a
   * 404: a retry would resend the same Idempotency-Key that the 404 was
   * answered under, and whether that key replays the failure is not something
   * to find out with a user's trial. Grants are once-per-user events, so the
   * extra call costs nothing that matters.
   */
  async grant(
    userId: string,
    reference: string,
    credits: number,
  ): Promise<number> {
    await this.ensureCustomer(userId);
    return this.adjust(userId, Math.abs(credits), reference);
  }

  /** Creates the customer if RevenueCat does not have them. Safe to repeat. */
  private async ensureCustomer(userId: string): Promise<void> {
    const path = `/projects/${
      encodeURIComponent(this.opts.projectId)
    }/customers`;
    const response = await providerFetch(
      "revenuecat",
      this.fetchFn,
      `${BASE_URL}${path}`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.opts.secretKey}`,
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ id: userId }),
      },
      // 409 `resource_already_exists` is the answer for a customer who is
      // already there, which is the outcome wanted.
      [409],
    );
    await response.body?.cancel();
  }

  private async adjust(
    userId: string,
    delta: number,
    reference: string,
  ): Promise<number> {
    let list: VirtualCurrencyList;
    try {
      list = await this.request<VirtualCurrencyList>(
        "POST",
        `${
          this.customerPath(userId)
        }/virtual_currencies/transactions?include_empty_balances=true&limit=100`,
        {
          body: { adjustments: { [this.opts.currencyCode]: delta }, reference },
          idempotencyKey: reference,
          retries: MAX_WRITE_RETRIES,
        },
      );
    } catch (error) {
      // A grant creates the customer first, and a debit or refund only ever
      // follows a balance that customer was found to have. Reaching here means
      // the ledger disagrees with what was just read, which is a failure to
      // report, not a zero to assume.
      if (error instanceof CustomerMissing) {
        throw new ProviderError(
          "unavailable",
          `revenuecat: customer missing for ${reference}`,
        );
      }
      throw error;
    }
    const balance = this.balanceFrom(list);
    // The currency this call just moved is normally on the first page of the
    // response. If it is not, re-read rather than guess how to page a POST.
    return balance ?? (list.next_page ? await this.getBalance(userId) : 0);
  }

  private async readBalance(firstPage: string): Promise<number> {
    let path: string | undefined = firstPage;
    for (let page = 0; page < MAX_BALANCE_PAGES && path; page++) {
      const list: VirtualCurrencyList = await this.request<VirtualCurrencyList>(
        "GET",
        path,
        { retries: 0 },
      );
      const balance = this.balanceFrom(list);
      if (balance !== undefined) return balance;
      // `next_page` already carries the /v2 prefix that BASE_URL supplies.
      path = list.next_page?.replace(/^\/v2/, "") ?? undefined;
    }
    // A currency absent from every page is a currency the project does not
    // have — a zero balance, which the handler answers with 402.
    return 0;
  }

  private customerPath(userId: string): string {
    return `/projects/${encodeURIComponent(this.opts.projectId)}/customers/${
      encodeURIComponent(userId)
    }`;
  }

  /** The configured currency's balance, or undefined if it is not on this page. */
  private balanceFrom(list: VirtualCurrencyList): number | undefined {
    const match = (list.items ?? []).find(
      (item) => item.currency_code === this.opts.currencyCode,
    );
    return match === undefined ? undefined : match.balance ?? 0;
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
          [404],
        );
        if (response.status === 404) {
          const body = await response.json().catch(() => undefined);
          if (isMissingCustomer(body)) throw new CustomerMissing();
          // Any other 404 — a wrong project id, a path that moved — is ours
          // to fix, and must not pass for an empty balance.
          throw new ProviderError(
            "unavailable",
            `revenuecat: ${method} ${BASE_URL}${path} -> 404`,
          );
        }
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
