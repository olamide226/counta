import type { SupabaseClient } from "@supabase/supabase-js";
import { Authenticator, BlockStore, VoiceBlockRow } from "./types.ts";

/**
 * `voice_blocks` access through a service-role client. RLS grants clients
 * read-only access to their own rows; every write in this file bypasses RLS
 * on purpose and is the only write path to the table.
 */
export class SupabaseBlockStore implements BlockStore {
  constructor(private readonly admin: SupabaseClient) {}

  async findLiveBlock(
    userId: string,
    notBefore: Date,
  ): Promise<VoiceBlockRow | null> {
    const { data, error } = await this.admin
      .from("voice_blocks")
      .select("*")
      .eq("user_id", userId)
      .eq("reconciled", false)
      .gt("expires_at", notBefore.toISOString())
      .order("expires_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw new Error(`voice_blocks select: ${error.message}`);
    return (data as VoiceBlockRow | null) ?? null;
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

  async insert(
    row: Omit<VoiceBlockRow, "reconciled" | "streamed_secs" | "detections">,
  ): Promise<VoiceBlockRow> {
    const { data, error } = await this.admin
      .from("voice_blocks")
      .insert(row)
      .select("*")
      .single();
    if (error) throw new Error(`voice_blocks insert: ${error.message}`);
    return data as VoiceBlockRow;
  }

  async findById(
    blockId: string,
    userId: string,
  ): Promise<VoiceBlockRow | null> {
    const { data, error } = await this.admin
      .from("voice_blocks")
      .select("*")
      .eq("id", blockId)
      .eq("user_id", userId)
      .maybeSingle();
    if (error) throw new Error(`voice_blocks select: ${error.message}`);
    return (data as VoiceBlockRow | null) ?? null;
  }

  async reconcile(
    blockId: string,
    patch: { streamed_secs: number; detections: number },
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

/** Verifies a Supabase user JWT by asking Auth for the user behind it. */
export class SupabaseAuthenticator implements Authenticator {
  constructor(
    private readonly clientFor: (bearer: string) => SupabaseClient,
  ) {}

  async userIdForToken(token: string): Promise<string | null> {
    const { data, error } = await this.clientFor(token).auth.getUser(token);
    if (error || !data.user) return null;
    return data.user.id;
  }
}
