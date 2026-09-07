import { Deps, ProviderError } from "./types.ts";

// Pure request handler for POST /voice-block and POST /voice-block/release.
// No Deno.env, no network: everything arrives through `deps`, which is what
// makes index_test.ts possible without a running stack.

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function bearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1].trim() : null;
}

async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await req.json();
    return body && typeof body === "object" ? body : null;
  } catch {
    return null;
  }
}

export async function handleVoiceBlock(
  req: Request,
  deps: Deps,
): Promise<Response> {
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const path = new URL(req.url).pathname.replace(/\/+$/, "");
  const isRelease = path.endsWith("/release");
  if (!isRelease && !path.endsWith("/voice-block")) {
    return json(404, { error: "not_found" });
  }

  const token = bearerToken(req);
  const userId = token ? await deps.auth.userIdForToken(token) : null;
  if (!userId) {
    return json(401, { error: "unauthenticated" });
  }

  try {
    return isRelease
      ? await release(req, deps, userId)
      : await grant(req, deps, userId);
  } catch (error) {
    if (error instanceof ProviderError) {
      deps.log("provider_unavailable", {
        user_id: userId,
        reason: error.reason,
      });
      return json(503, { error: "provider_unavailable" });
    }
    deps.log("internal_error", { user_id: userId, message: String(error) });
    return json(500, { error: "internal" });
  }
}

async function grant(req: Request, deps: Deps, userId: string): Promise<Response> {
  const { config, blocks, balance, minter } = deps;
  const now = deps.now();

  const body = await readJson(req);
  const sessionId = body?.session_id;
  if (typeof sessionId !== "string" || !UUID_RE.test(sessionId)) {
    return json(400, { error: "invalid_session_id" });
  }

  // Rate limit (8.7) before anything that costs money or touches a provider.
  const windowStart = new Date(
    now.getTime() - config.rateLimitWindowMinutes * 60_000,
  );
  const recent = await blocks.countGrantsSince(userId, windowStart);
  if (recent >= config.rateLimitMax) {
    deps.log("rate_limited", { user_id: userId, recent });
    return json(429, { error: "rate_limited" });
  }

  // 3.8: one live block per user. A block inside its renewal overlap window is
  // not "live" for this purpose, otherwise the 90% renewal (3.9) could never
  // succeed.
  const liveCutoff = new Date(
    now.getTime() + config.renewalOverlapSeconds * 1000,
  );
  const live = await blocks.findLiveBlock(userId, liveCutoff);
  if (live) {
    return json(409, { error: "block_in_flight", expires_at: live.expires_at });
  }

  // 3.3 / 3.4
  const current = await balance.getBalance(userId);
  if (current < config.blockCredits) {
    return json(402, {
      error: "insufficient_credit",
      balance: current,
      required: config.blockCredits,
    });
  }

  // 3.5: debit before minting.
  const reference = `voice-block:${sessionId}:${now.toISOString()}`;
  const balanceAfter = await balance.spend(userId, config.blockCredits, reference);

  // 3.6: any mint failure refunds the debit and reports 503.
  let token: string;
  try {
    token = await minter.mint(config.tokenTtlSeconds);
  } catch (error) {
    try {
      await balance.grant(userId, config.blockCredits, `${reference}:refund`);
    } catch (refundError) {
      // Money is now wrong; say so loudly. The reconciliation query (10.5)
      // is what catches this class of drift.
      deps.log("refund_failed", {
        user_id: userId,
        session_id: sessionId,
        credits: config.blockCredits,
        message: String(refundError),
      });
    }
    deps.log("mint_failed", { user_id: userId, message: String(error) });
    return json(503, { error: "provider_unavailable" });
  }

  // 3.7
  const expiresAt = new Date(now.getTime() + config.blockSeconds * 1000);
  const row = await blocks.insert({
    user_id: userId,
    session_id: sessionId,
    credits: config.blockCredits,
    granted_at: now.toISOString(),
    expires_at: expiresAt.toISOString(),
  });

  // 10.1
  deps.log("block_granted", {
    user_id: userId,
    block_id: row.id,
    session_id: sessionId,
    credits: config.blockCredits,
    granted_at: row.granted_at,
  });

  return json(200, {
    block_id: row.id,
    token,
    block_seconds: config.blockSeconds,
    expires_at: row.expires_at,
    balance_after: balanceAfter,
  });
}

async function release(req: Request, deps: Deps, userId: string): Promise<Response> {
  const { config, blocks, balance } = deps;
  const now = deps.now();

  const body = await readJson(req);
  const blockId = body?.block_id;
  if (typeof blockId !== "string" || !UUID_RE.test(blockId)) {
    return json(400, { error: "invalid_block_id" });
  }
  const streamedSecs = clampInt(body?.streamed_secs);
  const detections = clampInt(body?.detections);
  // The client's own assertion is recorded for observability but never trusted.
  const clientClaimsRefund = body?.eligible_for_refund === true;

  const block = await blocks.findById(blockId, userId);
  if (!block) {
    return json(404, { error: "block_not_found" });
  }

  if (block.reconciled) {
    // Idempotent: a retried release neither refunds twice nor errors.
    return json(200, { refunded: false, balance: await balance.getBalance(userId) });
  }

  // 3.11, validated server-side against granted_at.
  const ageMs = now.getTime() - new Date(block.granted_at).getTime();
  const eligible = ageMs <= config.refundWindowSeconds * 1000 && detections === 0;

  const flipped = await blocks.reconcile(block.id, {
    streamed_secs: streamedSecs,
    detections,
  });
  if (!flipped) {
    return json(200, { refunded: false, balance: await balance.getBalance(userId) });
  }

  let refunded = false;
  let balanceNow: number;
  if (eligible) {
    balanceNow = await balance.grant(
      userId,
      block.credits,
      `voice-block:${block.id}:release-refund`,
    );
    refunded = true;
  } else {
    balanceNow = await balance.getBalance(userId);
  }

  deps.log("block_released", {
    user_id: userId,
    block_id: block.id,
    streamed_secs: streamedSecs,
    detections,
    client_claimed_refund: clientClaimsRefund,
    refunded,
  });

  return json(200, { refunded, balance: balanceNow });
}

function clampInt(value: unknown): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.floor(n);
}
