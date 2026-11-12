import { json, readJson } from "./respond.ts";
import { Deps } from "./types.ts";

// POST /voice-block/merge — moves a guest's minutes into a signed-in account.
//
// The case it exists for: a guest on a new phone signs in with an Apple or
// Google identity that already belongs to another account. The app switches
// to that account, and the guest's minutes would otherwise be stranded on a
// user id nothing will ever sign in as again. The first sign-in of a guest
// needs none of this — the identity is linked to the guest's own user id, so
// the minutes are already where they belong.
//
// The caller's JWT is the destination. The source is proved the same way: the
// app sends the guest's own access token, so only someone holding that guest's
// session can empty it.

/** The ledger reference and idempotency key for a guest's merge. */
export function mergeReference(guestId: string): string {
  return `merge:${guestId}`;
}

export async function merge(
  req: Request,
  deps: Deps,
  userId: string,
): Promise<Response> {
  const { accounts, balance, blocks } = deps;

  const body = await readJson(req);
  const raw = body?.guest_token;
  const guestToken = typeof raw === "string" ? raw.trim() : "";
  if (guestToken.length === 0) {
    return json(400, { error: "invalid_request" });
  }

  const guestId = await deps.auth.userIdForToken(guestToken);
  if (!guestId) {
    return json(400, { error: "invalid_guest" });
  }

  // Merging into yourself moves nothing. Answered rather than refused, so an
  // app that asks twice around a sign-in it already completed is not an error.
  const nothingMoved = async () =>
    json(200, { moved: 0, balance: await balance.getBalance(userId) });
  if (guestId === userId) return nothingMoved();

  // Minutes only ever move out of a guest. A real account is somebody's, and
  // holding one of its tokens is not a reason to empty it into another.
  if (!(await accounts.isGuest(guestId))) {
    deps.log("merge_refused", {
      user_id: userId,
      guest_id: guestId,
      reason: "not_a_guest",
    });
    return json(403, { error: "not_a_guest" });
  }

  // A live block is minutes the guest has paid for but not yet had back. Its
  // release refunds the unused part to the *guest*, after this merge would
  // have read the balance, and those minutes would be stranded. The app stops
  // the session first; this is the server saying so if it did not.
  if (await blocks.findLiveBlock(guestId, deps.now())) {
    return json(409, { error: "guest_busy" });
  }

  const moving = await balance.getBalance(guestId);
  if (moving <= 0) return nothingMoved();

  // Grant first, then spend, both keyed on the guest. The order is what makes
  // a retry after a partial failure safe, because every retry starts by
  // re-reading the guest's balance:
  //   - if the spend already happened, the guest reads 0 and the retry stops;
  //   - if only the grant happened, the guest still reads the same amount, the
  //     grant replays under its idempotency key and the spend completes.
  // Spend-first would lose the minutes outright: a grant that failed after it
  // leaves a retry reading 0 and moving nothing, with the guest emptied and
  // the account never credited.
  //
  // The window that remains is the one redeem.ts names: the ledger's keys
  // expire, so a grant that landed and a spend that never did, retried only
  // after that window, would credit twice. A merge is retried within seconds
  // of the failure or not at all, so this is accepted rather than recorded.
  const reference = mergeReference(guestId);
  const balanceAfter = await balance.grant(userId, reference, moving);
  await balance.spend(guestId, reference, moving);

  deps.log("minutes_merged", {
    user_id: userId,
    guest_id: guestId,
    moved: moving,
  });

  return json(200, { moved: moving, balance: balanceAfter });
}
