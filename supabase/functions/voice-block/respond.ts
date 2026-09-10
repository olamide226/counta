// The three things every route does with the HTTP envelope. They live here
// rather than in handler.ts so that the per-endpoint modules (trial.ts,
// redeem.ts, token.ts) can use them without importing the router that
// dispatches to them.

export function json(
  status: number,
  body: Record<string, unknown>,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

/**
 * The one 429 this function answers, from all three of its budgets.
 *
 * The three are metered in three different places — rows in
 * `counta.voice_blocks` for a block grant, the worker's memory for a token
 * mint, `counta.voucher_attempts` inside the redemption transaction for a
 * guess — and that is deliberate, because what each one is protecting differs
 * (ratelimit.ts). What is not defensible is three *answers*: two of them used
 * to say `{"error":"rate_limited"}` with no hint at all and the third
 * `{"error":"too_many_attempts","retry_after_seconds":n}`, and none of the
 * three set the `Retry-After` header the client actually reads
 * (`lib/core/services/counting/block_client.dart`, on the branch that adds
 * it, parses the header and nothing else). Its retry hint was therefore always
 * empty, and the engine fell back to a fixed delay while its comment claimed
 * the server had told it how long to wait.
 *
 * Both are written here: the header for the client and any proxy between, the
 * body field for a caller reading JSON only. One responder is what keeps them
 * from disagreeing.
 */
export function rateLimited(retryAfterSeconds: number): Response {
  return json(
    429,
    { error: "rate_limited", retry_after_seconds: retryAfterSeconds },
    { "Retry-After": String(retryAfterSeconds) },
  );
}

/** Parses a JSON object body; null for anything else, including no body. */
export async function readJson(
  req: Request,
): Promise<Record<string, unknown> | null> {
  try {
    const body = await req.json();
    return body && typeof body === "object" ? body : null;
  } catch {
    return null;
  }
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Whether a client-supplied id is a UUID, checked before any lookup. */
export function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}
