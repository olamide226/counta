import { ProviderError } from "../types.ts";

/**
 * The single outbound-HTTP wrapper for every upstream provider.
 *
 * Shared so that classification is identical wherever a call is made: a 429
 * from Deepgram becomes the same rate-limited failure as a 429 from
 * RevenueCat, instead of collapsing into a generic "unavailable" that hides
 * the one condition worth retrying. Retrying is the caller's decision — this
 * only classifies and never sleeps.
 *
 * `passThrough` names the statuses the caller decides for itself and gets the
 * response back for. The attestation providers need it: Apple answers a
 * malformed device token with a 400 and Google a malformed integrity token
 * likewise, and both mean "this client's payload is junk, never retry it"
 * rather than "the provider is down". Classifying those as `unavailable`
 * would turn a permanent 400 into a 503 the client retries for ever. Network
 * failures, 429 and 5xx stay here, so nobody re-implements the retryable case.
 */
export async function providerFetch(
  provider: string,
  fetchFn: typeof fetch,
  url: string,
  init: RequestInit,
  passThrough: readonly number[] = [],
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
