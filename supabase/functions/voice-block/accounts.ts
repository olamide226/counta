import type { SupabaseClient } from "@supabase/supabase-js";
import { Accounts, ProviderError } from "./types.ts";

/**
 * Supabase Auth's admin API, for the two questions /merge and /delete-account
 * ask about a user.
 *
 * Uses the service-role client index.ts already builds; nothing here is
 * reachable with a user's own token.
 */
export class SupabaseAccounts implements Accounts {
  constructor(private readonly admin: SupabaseClient) {}

  async isGuest(userId: string): Promise<boolean> {
    const { data, error } = await this.admin.auth.admin.getUserById(userId);
    if (error) {
      // A user who is gone is not a guest. Anything else is Auth failing to
      // answer, and "not a guest" would turn an outage into a 403 the app
      // reads as permanent, so it is a 503 to retry instead.
      if (isMissingUser(error)) return false;
      throw new ProviderError(
        "unavailable",
        `auth: getUserById -> ${error.status ?? "?"} ${error.message}`,
      );
    }
    return data.user?.is_anonymous === true;
  }

  async remove(userId: string): Promise<void> {
    const { error } = await this.admin.auth.admin.deleteUser(userId);
    // Already gone is what was asked for, so a retried deletion succeeds.
    if (!error || isMissingUser(error)) return;
    throw new ProviderError(
      "unavailable",
      `auth: deleteUser -> ${error.status ?? "?"} ${error.message}`,
    );
  }
}

/** Auth's own statement that the user does not exist. */
function isMissingUser(error: { status?: number; code?: string }): boolean {
  return error.code === "user_not_found" || error.status === 404;
}
