// Entrypoint: reads configuration and secrets from Deno.env, wires the real
// adapters, and delegates to the pure handler. Secrets never leave this file
// except as constructor arguments to the adapters that need them.

import { createClient } from "@supabase/supabase-js";
import { handleVoiceBlock, json } from "./handler.ts";
import { RevenueCatBalanceProvider } from "./providers/balance.ts";
import { DeepgramTokenMinter } from "./providers/minter.ts";
import { SupabaseAuthenticator, SupabaseBlockStore } from "./store.ts";
import type { Deps, HandlerConfig } from "./types.ts";

function env(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value === undefined || value === "" ? undefined : value;
}

function requireEnv(name: string): string {
  const value = env(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}

function intEnv(name: string, fallback: number): number {
  const raw = env(name);
  const n = raw === undefined ? NaN : Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

function buildConfig(): HandlerConfig {
  return {
    blockCredits: intEnv("BLOCK_CREDITS", 5),
    blockSeconds: intEnv("BLOCK_SECONDS", 300),
    tokenTtlSeconds: Math.min(Math.max(intEnv("DEEPGRAM_TOKEN_TTL_SECONDS", 30), 1), 3600),
    refundWindowSeconds: intEnv("REFUND_WINDOW_SECONDS", 30),
    rateLimitMax: intEnv("RATE_LIMIT_MAX", 6),
    rateLimitWindowMinutes: intEnv("RATE_LIMIT_WINDOW_MINUTES", 10),
  };
}

/** One log line shape everywhere, so the function logs stay greppable. */
function log(event: string, fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ event, ...fields }));
}

// Built once per worker so a warm function does not re-read env per request.
// Failures here (a missing secret) surface on the first request as a 500 with
// the message in the function logs rather than crashing worker boot.
let cachedDeps: Deps | null = null;

function deps(): Deps {
  if (cachedDeps) return cachedDeps;
  const supabaseUrl = requireEnv("SUPABASE_URL");
  const publishableKey = env("SUPABASE_PUBLISHABLE_KEY") ??
    requireEnv("SUPABASE_ANON_KEY");
  const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const built: Deps = {
    auth: new SupabaseAuthenticator((bearer) =>
      createClient(supabaseUrl, publishableKey, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: `Bearer ${bearer}` } },
      })
    ),
    blocks: new SupabaseBlockStore(admin),
    // Only the real adapters are reachable from here. The fakes live in
    // testing/ and are never imported by this module, so no environment
    // variable can turn the deployed function into a free-credit dispenser.
    balance: new RevenueCatBalanceProvider({
      secretKey: requireEnv("REVENUECAT_SECRET_KEY"),
      projectId: requireEnv("REVENUECAT_PROJECT_ID"),
      currencyCode: env("REVENUECAT_CURRENCY_CODE") ?? "VOICE",
    }),
    minter: new DeepgramTokenMinter({
      apiKey: requireEnv("DEEPGRAM_API_KEY"),
    }),
    config: buildConfig(),
    now: () => new Date(),
    newBlockId: () => crypto.randomUUID(),
    log,
  };
  cachedDeps = built;
  return built;
}

Deno.serve(async (req) => {
  try {
    return await handleVoiceBlock(req, deps());
  } catch (error) {
    // A missing secret throws here on every request until it is set; no cached
    // failure, so fixing the secret and redeploying is enough to recover.
    log("boot_failed", { message: String(error) });
    return json(500, { error: "misconfigured" });
  }
});
