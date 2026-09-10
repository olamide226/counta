import { assertEquals } from "@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  COUNTA_SCHEMA,
  SupabaseBlockStore,
  SupabaseTrialStore,
  SupabaseVoucherStore,
} from "./store.ts";

/**
 * The deploy target is a shared project, so the schema a query lands in is a
 * correctness property, not a detail: a `voice_blocks` resolved against
 * `public` would read another product's namespace. These tests pin it by
 * recording what the store asks the client for.
 */
function recordingClient(): {
  schemas: string[];
  tables: string[];
  rpcs: Array<{ name: string; args: unknown }>;
  client: SupabaseClient;
} {
  const schemas: string[] = [];
  const tables: string[] = [];
  // A builder that answers every chained call with itself and resolves empty.
  const builder: Record<string, unknown> = {};
  const chain = () => builder;
  for (
    const name of [
      "select",
      "insert",
      "update",
      "eq",
      "is",
      "gt",
      "gte",
      "lte",
      "order",
      "limit",
    ]
  ) {
    builder[name] = chain;
  }
  builder.maybeSingle = () => Promise.resolve({ data: null, error: null });
  builder.single = () => Promise.resolve({ data: null, error: null });
  builder.then = (resolve: (value: unknown) => unknown) =>
    Promise.resolve({ data: [], error: null, count: 0 }).then(resolve);

  const rpcs: Array<{ name: string; args: unknown }> = [];
  const client = {
    schema(name: string) {
      schemas.push(name);
      return {
        from(table: string) {
          tables.push(table);
          return builder;
        },
        rpc(name: string, args: unknown) {
          rpcs.push({ name, args });
          return Promise.resolve({
            data: { outcome: "not_found" },
            error: null,
          });
        },
      };
    },
  } as unknown as SupabaseClient;
  return { schemas, tables, rpcs, client };
}

Deno.test("store: every query is scoped to the counta schema", async () => {
  const { schemas, tables, client } = recordingClient();
  const store = new SupabaseBlockStore(client);
  const now = new Date("2026-01-01T00:00:00Z");

  await store.findLiveBlock("user-1", now);
  await store.supersede("block-1");
  await store.grantsSince("user-1", now);
  await store.retireExpired("user-1", now);
  await store.findById("block-1", "user-1");
  await store.reconcile("block-1", { streamed_secs: 1, detections: 0 });

  assertEquals(schemas.length, 6);
  assertEquals(new Set(schemas), new Set([COUNTA_SCHEMA]));
  assertEquals(new Set(tables), new Set(["voice_blocks"]));
});

Deno.test("store: the trial and voucher stores are scoped there too", async () => {
  const { schemas, tables, rpcs, client } = recordingClient();
  const trials = new SupabaseTrialStore(client);
  const vouchers = new SupabaseVoucherStore(client);
  await trials.find("user-1");
  await trials.insert({
    user_id: "user-1",
    platform: "ios",
    gate: "devicecheck",
    credits: 20,
  });
  await vouchers.markCredited("redemption-1");
  await vouchers.redeem("SPRING24", "user-1", {
    windowMinutes: 60,
    maxAttempts: 10,
  });

  assertEquals(schemas.length, 4);
  assertEquals(new Set(schemas), new Set([COUNTA_SCHEMA]));
  assertEquals(
    new Set(tables),
    new Set(["trial_grants", "voucher_redemptions"]),
  );
  // The whole redemption is one RPC and not a hand-assembled sequence: the
  // guess budget, the slot claim, the redemption row and the failed-attempt
  // record all belong in one transaction, and the store no longer touches
  // counta.voucher_attempts at all.
  assertEquals(rpcs, [{
    name: "redeem_voucher",
    args: {
      p_code: "SPRING24",
      p_user_id: "user-1",
      p_window_minutes: 60,
      p_max_attempts: 10,
    },
  }]);
});
