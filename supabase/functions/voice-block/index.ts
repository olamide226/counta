// Entrypoint: reads configuration and secrets from Deno.env, wires the real
// adapters, and delegates to the pure handler. Secrets never leave this file
// except as constructor arguments to the adapters that need them.

import { createClient } from "@supabase/supabase-js";
import { buildAttestors } from "./attestors.ts";
import { handleVoiceBlock } from "./handler.ts";
import { json } from "./respond.ts";
import { RevenueCatBalanceProvider } from "./providers/balance.ts";
import { DeepgramTokenMinter } from "./providers/minter.ts";
import { SupabaseAuthenticator } from "./auth.ts";
import { MemoryRateLimiter } from "./ratelimit.ts";
import {
  SupabaseBlockStore,
  SupabaseTrialStore,
  SupabaseVoucherStore,
} from "./store.ts";
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
    tokenMintMax: intEnv("TOKEN_MINT_MAX", 20),
    tokenMintWindowMinutes: intEnv("TOKEN_MINT_WINDOW_MINUTES", 5),
    trialCredits: intEnv("TRIAL_CREDITS", 20),
    voucherAttemptMax: intEnv("VOUCHER_ATTEMPT_MAX", 10),
    voucherAttemptWindowMinutes: intEnv("VOUCHER_ATTEMPT_WINDOW_MINUTES", 60),
  };
}

/**
 * Keeps the worker alive for work started before the response and finishing
 * after it (the DeviceCheck bit write).
 *
 * `EdgeRuntime` is the Supabase edge runtime's global and is absent under
 * `deno test` and `deno run`. Its absence is not a failure: the promise has
 * already been started and still runs — all that is lost is the guarantee
 * that the isolate stays up for it, which is exactly the guarantee only a
 * deployed worker can give.
 */
function afterResponse(work: Promise<unknown>): void {
  const runtime = (globalThis as {
    EdgeRuntime?: { waitUntil?: (work: Promise<unknown>) => void };
  }).EdgeRuntime;
  runtime?.waitUntil?.(work);
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
  const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

  // Left on the default schema: SupabaseBlockStore scopes its own queries to
  // `counta` (store.ts), and SupabaseAuthenticator only uses `.auth`, which
  // no schema setting affects.
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const config = buildConfig();
  const built: Deps = {
    auth: new SupabaseAuthenticator({
      client: admin,
      jwksUrl: `${supabaseUrl}/auth/v1/.well-known/jwks.json`,
    }),
    blocks: new SupabaseBlockStore(admin),
    tokenLimiter: new MemoryRateLimiter(
      config.tokenMintMax,
      config.tokenMintWindowMinutes * 60_000,
    ),
    trials: new SupabaseTrialStore(admin),
    vouchers: new SupabaseVoucherStore(admin),
    attestors: buildAttestors(env, log),
    // Only the real adapters are reachable from here. The fakes — including
    // the attestor that says every device is eligible — live in testing/ and
    // are never imported by this module, so no environment variable can turn
    // the deployed function into a free-credit dispenser.
    balance: new RevenueCatBalanceProvider({
      secretKey: requireEnv("REVENUECAT_SECRET_KEY"),
      projectId: requireEnv("REVENUECAT_PROJECT_ID"),
      currencyCode: env("REVENUECAT_CURRENCY_CODE") ?? "VOICE",
    }),
    minter: new DeepgramTokenMinter({
      apiKey: requireEnv("DEEPGRAM_API_KEY"),
    }),
    config,
    now: () => new Date(),
    newBlockId: () => crypto.randomUUID(),
    afterResponse,
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
