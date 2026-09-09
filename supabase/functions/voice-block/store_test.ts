import { assertEquals } from "@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import { COUNTA_SCHEMA, SupabaseBlockStore } from "./store.ts";

/**
 * The deploy target is a shared project, so the schema a query lands in is a
 * correctness property, not a detail: a `voice_blocks` resolved against
 * `public` would read another product's namespace. These tests pin it by
 * recording what the store asks the client for.
 */
function recordingClient(): { schemas: string[]; tables: string[]; client: SupabaseClient } {
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
  builder.then = (resolve: (value: unknown) => unknown) =>
    Promise.resolve({ data: [], error: null, count: 0 }).then(resolve);

  const client = {
    schema(name: string) {
      schemas.push(name);
      return {
        from(table: string) {
          tables.push(table);
          return builder;
        },
      };
    },
  } as unknown as SupabaseClient;
  return { schemas, tables, client };
}

Deno.test("store: every query is scoped to the counta schema", async () => {
  const { schemas, tables, client } = recordingClient();
  const store = new SupabaseBlockStore(client);
  const now = new Date("2026-01-01T00:00:00Z");

  await store.findLiveBlock("user-1", now);
  await store.supersede("block-1");
  await store.countGrantsSince("user-1", now);
  await store.retireExpired("user-1", now);
  await store.findById("block-1", "user-1");
  await store.reconcile("block-1", { streamed_secs: 1, detections: 0 });

  assertEquals(schemas.length, 6);
  assertEquals(new Set(schemas), new Set([COUNTA_SCHEMA]));
  assertEquals(new Set(tables), new Set(["voice_blocks"]));
});
