import type { SupabaseClient } from "@supabase/supabase-js";
import {
  BlockConflictError,
  BlockStore,
  RedeemOutcome,
  TrialGrantRow,
  TrialStore,
  VoiceBlockRow,
  VoucherStore,
} from "./types.ts";

/**
 * The app owns one Postgres schema. The deploy target is shared staging where
 * each product has its own and `public` belongs to something else, so no query
 * here may resolve against the default schema. PostgREST serves `counta` only
 * while it is in the project's exposed-schemas list (supabase/README.md).
 */
export const COUNTA_SCHEMA = "counta";

/**
 * The one place the schema is named. Every table and every RPC in this file
 * goes through it, so a new query cannot silently fall back to `public` —
 * which is the failure store_test.ts exists to catch. Each store used to hold
 * its own private `table()` and one of them, the voucher redemption RPC, went
 * around all of them.
 */
const counta = (admin: SupabaseClient) => admin.schema(COUNTA_SCHEMA);

/**
 * `counta.voice_blocks` access through a service-role client. RLS grants
 * clients read-only access to their own rows; every write in this file
 * bypasses RLS on purpose and is the only write path to the table.
 */
export class SupabaseBlockStore implements BlockStore {
  /** Every column the handler reads; named so a select never ships more. */
  private static readonly COLUMNS =
    "id,user_id,session_id,credits,granted_at,expires_at,reconciled,streamed_secs,detections";

  constructor(private readonly admin: SupabaseClient) {}

  private table() {
    return counta(this.admin).from("voice_blocks");
  }

  async findLiveBlock(
    userId: string,
    now: Date,
  ): Promise<VoiceBlockRow | null> {
    const { data, error } = await this.table()
      .select("id,session_id,expires_at")
      .eq("user_id", userId)
      .eq("reconciled", false)
      .gt("expires_at", now.toISOString())
      .order("expires_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw new Error(`counta.voice_blocks select: ${error.message}`);
    return (data as VoiceBlockRow | null) ?? null;
  }

  async supersede(blockId: string): Promise<void> {
    const { error } = await this.table()
      .update({ reconciled: true })
      .eq("id", blockId)
      .eq("reconciled", false);
    if (error) throw new Error(`counta.voice_blocks supersede: ${error.message}`);
  }

  async countGrantsSince(userId: string, since: Date): Promise<number> {
    const { count, error } = await this.table()
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .gte("granted_at", since.toISOString());
    if (error) throw new Error(`counta.voice_blocks count: ${error.message}`);
    return count ?? 0;
  }

  async retireExpired(userId: string, now: Date): Promise<void> {
    const { error } = await this.table()
      .update({ reconciled: true })
      .eq("user_id", userId)
      .eq("reconciled", false)
      .lte("expires_at", now.toISOString());
    if (error) throw new Error(`counta.voice_blocks retire: ${error.message}`);
  }

  async insert(
    row: Omit<VoiceBlockRow, "reconciled" | "streamed_secs" | "detections">,
  ): Promise<VoiceBlockRow> {
    const { data, error } = await this.table()
      .insert(row)
      .select(SupabaseBlockStore.COLUMNS)
      .single();
    if (error) {
      // 23505: the partial unique index on (user_id) where not reconciled.
      if (error.code === "23505") throw new BlockConflictError(error.message);
      throw new Error(`counta.voice_blocks insert: ${error.message}`);
    }
    return data as VoiceBlockRow;
  }

  async findById(
    blockId: string,
    userId: string,
  ): Promise<VoiceBlockRow | null> {
    const { data, error } = await this.table()
      // expires_at is read as well as granted_at: /release decides on the
      // grant time and /token on the expiry, and both go through this row.
      .select("id,credits,granted_at,expires_at,reconciled")
      .eq("id", blockId)
      .eq("user_id", userId)
      .maybeSingle();
    if (error) throw new Error(`counta.voice_blocks select: ${error.message}`);
    return (data as VoiceBlockRow | null) ?? null;
  }

  async reconcile(
    blockId: string,
    patch: { streamed_secs: number | null; detections: number | null },
  ): Promise<boolean> {
    const { data, error } = await this.table()
      .update({ ...patch, reconciled: true })
      .eq("id", blockId)
      .eq("reconciled", false)
      .select("id");
    if (error) throw new Error(`counta.voice_blocks update: ${error.message}`);
    return (data?.length ?? 0) > 0;
  }
}

/**
 * `counta.trial_grants` through the same service-role client. The table has no
 * client grant and no policy at all, so this is its only reader and writer: a
 * client that could read it would learn whether reinstalling is worth it, and
 * one that could write it would grant itself the trial (req 4.8).
 */
export class SupabaseTrialStore implements TrialStore {
  private static readonly COLUMNS = "user_id,platform,gate,credits,granted_at";

  constructor(private readonly admin: SupabaseClient) {}

  private table() {
    return counta(this.admin).from("trial_grants");
  }

  async find(userId: string): Promise<TrialGrantRow | null> {
    const { data, error } = await this.table()
      .select(SupabaseTrialStore.COLUMNS)
      .eq("user_id", userId)
      .maybeSingle();
    if (error) throw new Error(`counta.trial_grants select: ${error.message}`);
    return (data as TrialGrantRow | null) ?? null;
  }

  async insert(
    row: Omit<TrialGrantRow, "granted_at">,
  ): Promise<TrialGrantRow | null> {
    const { data, error } = await this.table()
      .insert(row)
      .select(SupabaseTrialStore.COLUMNS)
      .single();
    if (error) {
      // 23505: the primary key on user_id. Someone else already granted this
      // user's trial, which is the outcome, not a failure (req 11.8).
      if (error.code === "23505") return null;
      throw new Error(`counta.trial_grants insert: ${error.message}`);
    }
    return data as TrialGrantRow;
  }
}

/**
 * The voucher tables, likewise service-role only: the codes are the secret.
 *
 * The redemption itself is not assembled here. `counta.redeem_voucher` does
 * the lookup, the cap claim and the redemption row in one transaction, so
 * there is no ordering for this class to get wrong and no window in which a
 * slot and a row can disagree (design: Edge Function contract).
 */
export class SupabaseVoucherStore implements VoucherStore {
  constructor(private readonly admin: SupabaseClient) {}

  private attempts() {
    return counta(this.admin).from("voucher_attempts");
  }

  async attemptsSince(
    userId: string,
    since: Date,
  ): Promise<{ count: number; oldest: Date | null }> {
    // One query for both: PostgREST counts the whole filtered set even when
    // the page is one row, so the oldest attempt — which is what says when the
    // window clears — comes back for free.
    const { data, count, error } = await this.attempts()
      .select("attempted_at", { count: "exact" })
      .eq("user_id", userId)
      .gte("attempted_at", since.toISOString())
      .order("attempted_at", { ascending: true })
      .limit(1);
    if (error) throw new Error(`counta.voucher_attempts count: ${error.message}`);
    const oldest = (data as Array<{ attempted_at: string }> | null)?.[0];
    return {
      count: count ?? 0,
      oldest: oldest ? new Date(oldest.attempted_at) : null,
    };
  }

  async recordAttempt(userId: string): Promise<void> {
    // The submitted code is deliberately not stored, not even hashed: a table
    // of hashed guesses is an offline dictionary target and buys nothing the
    // timestamp does not.
    const { error } = await this.attempts().insert({ user_id: userId });
    if (error) throw new Error(`counta.voucher_attempts insert: ${error.message}`);
  }

  async markCredited(redemptionId: string): Promise<void> {
    // `is null` guards it, so two concurrent completions of the same
    // redemption record one time rather than overwriting each other's.
    const { error } = await counta(this.admin)
      .from("voucher_redemptions")
      .update({ credited_at: new Date().toISOString() })
      .eq("id", redemptionId)
      .is("credited_at", null);
    if (error) {
      throw new Error(`counta.voucher_redemptions credited: ${error.message}`);
    }
  }

  async redeem(code: string, userId: string): Promise<RedeemOutcome> {
    const { data, error } = await counta(this.admin)
      .rpc("redeem_voucher", { p_code: code, p_user_id: userId });
    if (error) throw new Error(`counta.redeem_voucher: ${error.message}`);

    const result = data as Partial<RedeemOutcome> | null;
    switch (result?.outcome) {
      case "redeemed":
      case "already_redeemed": {
        const { voucher_id, redemption_id, credits, credited } = result as {
          voucher_id?: unknown;
          redemption_id?: unknown;
          credits?: unknown;
          credited?: unknown;
        };
        if (
          typeof voucher_id !== "string" || typeof redemption_id !== "string" ||
          typeof credits !== "number" || typeof credited !== "boolean"
        ) {
          // Never a default: a missing `credited` read as false would re-issue
          // a payout that has already landed, which is the bug the column
          // exists to close.
          throw new Error("counta.redeem_voucher: incomplete redemption");
        }
        return {
          outcome: result.outcome,
          voucher_id,
          redemption_id,
          credits,
          credited,
        };
      }
      case "not_found":
      case "expired":
      case "exhausted":
        return { outcome: result.outcome };
      default:
        // Never silently a refusal: an unrecognised answer would otherwise
        // read as "no such code" and quietly deny every real one.
        throw new Error(`counta.redeem_voucher: unknown outcome ${result?.outcome}`);
    }
  }
}
