import type { SupabaseClient } from "@supabase/supabase-js";
import { BlockConflictError, BlockStore, VoiceBlockRow } from "./types.ts";

/**
 * `voice_blocks` access through a service-role client. RLS grants clients
 * read-only access to their own rows; every write in this file bypasses RLS
 * on purpose and is the only write path to the table.
 */
export class SupabaseBlockStore implements BlockStore {
  /** Every column the handler reads; named so a select never ships more. */
  private static readonly COLUMNS =
    "id,user_id,session_id,credits,granted_at,expires_at,reconciled,streamed_secs,detections";

  constructor(private readonly admin: SupabaseClient) {}

  async findLiveBlock(
    userId: string,
    now: Date,
  ): Promise<VoiceBlockRow | null> {
    const { data, error } = await this.admin
      .from("voice_blocks")
      .select("id,session_id,expires_at")
      .eq("user_id", userId)
      .eq("reconciled", false)
      .gt("expires_at", now.toISOString())
      .order("expires_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw new Error(`voice_blocks select: ${error.message}`);
    return (data as VoiceBlockRow | null) ?? null;
  }

  async supersede(blockId: string): Promise<void> {
    const { error } = await this.admin
      .from("voice_blocks")
      .update({ reconciled: true })
      .eq("id", blockId)
      .eq("reconciled", false);
    if (error) throw new Error(`voice_blocks supersede: ${error.message}`);
  }

  async countGrantsSince(userId: string, since: Date): Promise<number> {
    const { count, error } = await this.admin
      .from("voice_blocks")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .gte("granted_at", since.toISOString());
    if (error) throw new Error(`voice_blocks count: ${error.message}`);
    return count ?? 0;
  }

  async retireExpired(userId: string, now: Date): Promise<void> {
    const { error } = await this.admin
      .from("voice_blocks")
      .update({ reconciled: true })
      .eq("user_id", userId)
      .eq("reconciled", false)
      .lte("expires_at", now.toISOString());
    if (error) throw new Error(`voice_blocks retire: ${error.message}`);
  }

  async insert(
    row: Omit<VoiceBlockRow, "reconciled" | "streamed_secs" | "detections">,
  ): Promise<VoiceBlockRow> {
    const { data, error } = await this.admin
      .from("voice_blocks")
      .insert(row)
      .select(SupabaseBlockStore.COLUMNS)
      .single();
    if (error) {
      // 23505: the partial unique index on (user_id) where not reconciled.
      if (error.code === "23505") throw new BlockConflictError(error.message);
      throw new Error(`voice_blocks insert: ${error.message}`);
    }
    return data as VoiceBlockRow;
  }

  async findById(
    blockId: string,
    userId: string,
  ): Promise<VoiceBlockRow | null> {
    const { data, error } = await this.admin
      .from("voice_blocks")
      .select("id,credits,granted_at,reconciled")
      .eq("id", blockId)
      .eq("user_id", userId)
      .maybeSingle();
    if (error) throw new Error(`voice_blocks select: ${error.message}`);
    return (data as VoiceBlockRow | null) ?? null;
  }

  async reconcile(
    blockId: string,
    patch: { streamed_secs: number | null; detections: number | null },
  ): Promise<boolean> {
    const { data, error } = await this.admin
      .from("voice_blocks")
      .update({ ...patch, reconciled: true })
      .eq("id", blockId)
      .eq("reconciled", false)
      .select("id");
    if (error) throw new Error(`voice_blocks update: ${error.message}`);
    return (data?.length ?? 0) > 0;
  }
}
