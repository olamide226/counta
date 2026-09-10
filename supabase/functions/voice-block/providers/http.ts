import { AttestationError, ProviderError } from "../types.ts";

/**
 * The single outbound-HTTP wrapper for every upstream provider.
 *
 * Shared so that classification is identical wherever a call is made: a 429
 * from Deepgram becomes the same rate-limited failure as a 429 from
 * RevenueCat, instead of collapsing into a generic "unavailable" that hides
 * the one condition worth retrying. Retrying is the caller's decision — this
 * only classifies and never sleeps.
 */
export function providerFetch(
  provider: string,
  fetchFn: typeof fetch,
  url: string,
  init: RequestInit,
): Promise<Response> {
  return dispatch(provider, fetchFn, url, init, NO_PASS_THROUGH);
}

/**
 * The same call for the two attestation providers, whose refusals are answers
 * rather than outages.
 *
 * Apple answers a malformed device token with a 400 and Google a malformed
 * integrity token likewise, and both mean "this client's payload is junk,
 * never retry it" rather than "the provider is down"; classifying those as
 * unavailable would turn a permanent 400 into a 503 the client retries for
 * ever. A 401 or 403 is the mirror image — *our* credentials are wrong, which
 * says nothing about this device, so the trial stays unclaimed and the client
 * may retry once an operator has fixed the secret (req 11.9).
 *
 * Both attestors classified those three statuses for themselves, identically
 * and twice; the status list, the rule and the body truncation live here now.
 * Network failures, 429 and 5xx never reach it — they stay with the shared
 * classifier, so nobody re-implements the retryable case.
 *
 * Resolves to the response body, since both callers want the text either way:
 * the verdict on success, the detail for the logs on a refusal.
 */
export async function attestationFetch(
  provider: string,
  fetchFn: typeof fetch,
  url: string,
  init: RequestInit,
): Promise<string> {
  const response = await dispatch(provider, fetchFn, url, init, PASS_THROUGH);
  const body = await response.text();
  if (response.ok) return body;

  // The providers' documented "descriptive string" columns are not wire
  // contracts — the strings observed in production differ from them — so the
  // status decides and the body only reaches the logs.
  const detail = `${provider} ${response.status}: ${body.slice(0, 200)}`;
  return Promise.reject(
    new AttestationError(
      response.status === 400 ? "rejected" : "indeterminate",
      detail,
    ),
  );
}

async function dispatch(
  provider: string,
  fetchFn: typeof fetch,
  url: string,
  init: RequestInit,
  passThrough: readonly number[],
): Promise<Response> {
  const what = `${provider}: ${init.method ?? "GET"} ${url}`;

  let response: Response;
  try {
    response = await fetchFn(url, init);
  } catch (error) {
    throw new ProviderError("unavailable", `${what} -> ${String(error)}`);
  }

  if (response.ok || passThrough.includes(response.status)) return response;

  // Nothing downstream reads the body of a failed call; releasing it keeps the
  // worker from holding the connection open.
  await response.body?.cancel();

  if (response.status === 429) {
    throw new ProviderError(
      "rate_limited",
      `${what} -> 429`,
      retryAfterMs(response),
    );
  }
  throw new ProviderError("unavailable", `${what} -> ${response.status}`);
}

function retryAfterMs(response: Response): number | undefined {
  const seconds = Number(response.headers.get("Retry-After"));
  return Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : undefined;
}

/** 400 is the client's payload; 401 and 403 are our own credentials. */
const PASS_THROUGH = [400, 401, 403] as const;
const NO_PASS_THROUGH = [] as const;
