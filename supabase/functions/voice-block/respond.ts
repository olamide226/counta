// The three things every route does with the HTTP envelope. They live here
// rather than in handler.ts so that the per-endpoint modules (trial.ts,
// redeem.ts, token.ts) can use them without importing the router that
// dispatches to them.

export function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
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
