import { isUuid, json, readJson } from "./respond.ts";
import { Deps } from "./types.ts";

// POST /voice-block/token — a fresh streaming token for a block the caller
// already holds (design: Edge Function contract).
//
// The Deepgram token TTL governs *establishing* a connection, not the life of
// a socket already open, which is what makes a 30-second token workable for a
// 300-second block (design: "The Deepgram token TTL of 30 seconds governs
// connection establishment only"). The corollary is that a socket dropped more
// than 30 seconds into a block has no credential left to reconnect with, so
// only the first 10% of a block could survive a network blip.
//
// Asking /voice-block for another grant is worse than useless: a grant
// carrying the live block's session_id is read as a renewal (req 3.9) and
// would debit a whole block per dropped socket. This route therefore mints and
// **never debits** — the block was paid for when it was granted, and a client
// must not be charged for a bad network.
//
// Nothing the client says decides anything: ownership, the reconciled flag and
// the expiry are all read from counta.voice_blocks.

export async function mintToken(
  req: Request,
  deps: Deps,
  userId: string,
): Promise<Response> {
  const { config, blocks, minter } = deps;
  const now = deps.now();

  const body = await readJson(req);
  const blockId = body?.block_id;
  if (typeof blockId !== "string" || !isUuid(blockId)) {
    return json(400, { error: "invalid_request" });
  }

  // Metered before the lookup and before Deepgram, for the same reason the
  // grant route checks its limit first: a mint is cheap but it is not free,
  // and an unmetered route that hands out provider credentials is exactly the
  // thing not to leave lying around.
  if (!deps.tokenLimiter.allow(userId, now)) {
    deps.log("token_rate_limited", { user_id: userId, block_id: blockId });
    return json(429, { error: "rate_limited" });
  }

  // Unknown, someone else's, already reconciled and expired are deliberately
  // one answer. A block that belongs to another user must be indistinguishable
  // from one that does not exist, or a caller could probe for live block ids;
  // and a client holding a dead block wants the same thing in every case —
  // stop reconnecting and ask for a new block.
  const block = await blocks.findById(blockId, userId);
  const live = block && !block.reconciled &&
    new Date(block.expires_at).getTime() > now.getTime();
  if (!block || !live) {
    deps.log("token_block_not_found", { user_id: userId, block_id: blockId });
    return json(404, { error: "block_not_found" });
  }

  // A mint failure is a ProviderError and reaches the router, which answers
  // 503 provider_unavailable. There is nothing to undo here — no debit, no
  // row — so catching it only to relabel it would give one condition two
  // vocabularies.
  const token = await minter.mint(config.tokenTtlSeconds);

  deps.log("block_token_minted", {
    user_id: userId,
    block_id: block.id,
    expires_in: config.tokenTtlSeconds,
    block_expires_at: block.expires_at,
  });

  return json(200, { token, expires_in: config.tokenTtlSeconds });
}
