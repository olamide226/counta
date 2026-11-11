import { json } from "./respond.ts";
import { Deps } from "./types.ts";

// POST /voice-block/delete-account — the in-app account deletion Apple
// requires of any app that offers sign-in.
//
// Two records hold the user: RevenueCat's customer, where the minutes are,
// and the Supabase Auth user, which every `counta.*` table references with
// `on delete cascade` (migrations/20260907120000_voice_blocks.sql), so the
// blocks, trial grant, redemptions and voucher attempts go with it.

export async function deleteAccount(
  _req: Request,
  deps: Deps,
  userId: string,
): Promise<Response> {
  // The ledger first. If the Auth delete then fails, the user can still sign
  // in and the retry finds an already-forgotten customer, which is success.
  // The other order would leave, on a failed ledger call, a balance belonging
  // to a user id nobody can ever authenticate as again — and so no request
  // that could clear it.
  await deps.balance.forget(userId);
  await deps.accounts.remove(userId);

  deps.log("account_deleted", { user_id: userId });
  return json(200, { deleted: true });
}
