// Entrypoint: reads configuration and secrets from Deno.env, wires the real
// adapters, and delegates to the pure handler. Secrets never leave this file
// except as constructor arguments to the adapters that need them.

import { createClient } from "@supabase/supabase-js";
import { handleVoiceBlock } from "./handler.ts";
import { json } from "./respond.ts";
import { RevenueCatBalanceProvider } from "./providers/balance.ts";
import { AppleDeviceCheckAttestor } from "./providers/devicecheck.ts";
import { DeepgramTokenMinter } from "./providers/minter.ts";
import { PlayIntegrityAttestor } from "./providers/playintegrity.ts";
import { SupabaseAuthenticator } from "./auth.ts";
import {
  SupabaseBlockStore,
  SupabaseTrialStore,
  SupabaseVoucherStore,
} from "./store.ts";
import type {
  Deps,
  DeviceAttestor,
  HandlerConfig,
  TrialPlatform,
} from "./types.ts";

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
    trialCredits: intEnv("TRIAL_CREDITS", 20),
    voucherAttemptMax: intEnv("VOUCHER_ATTEMPT_MAX", 10),
    voucherAttemptWindowMinutes: intEnv("VOUCHER_ATTEMPT_WINDOW_MINUTES", 60),
  };
}

/**
 * The trial gate for each platform whose credentials are configured.
 *
 * A platform with no credentials gets no attestor, and the trial endpoint
 * answers `platform_unsupported` for it (req 11.10) rather than 503ing on
 * every call. Deliberately not `requireEnv`: an operator who has not set up
 * DeviceCheck yet should lose the trial, not the block endpoints that pay for
 * the whole feature.
 */
function buildAttestors(): Partial<Record<TrialPlatform, DeviceAttestor>> {
  const attestors: Partial<Record<TrialPlatform, DeviceAttestor>> = {};

  const teamId = env("APPLE_TEAM_ID");
  const keyId = env("APPLE_DEVICECHECK_KEY_ID");
  const applePrivateKey = env("APPLE_DEVICECHECK_PRIVATE_KEY");
  if (teamId && keyId && applePrivateKey) {
    attestors.ios = new AppleDeviceCheckAttestor({
      teamId,
      keyId,
      privateKey: applePrivateKey,
      host: env("APPLE_DEVICECHECK_HOST") ?? "api.devicecheck.apple.com",
      // The bits belong to the Apple team, not to an app: check the
      // allocation table in specs/voice-phrase-counting/design.md before
      // changing this (req 11.4).
      bit: intEnv("DEVICECHECK_TRIAL_BIT", 0) === 1 ? 1 : 0,
    });
  }

  const packageName = env("PLAY_INTEGRITY_PACKAGE_NAME");
  const serviceAccount = env("PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON");
  if (packageName && serviceAccount) {
    // The whole service-account JSON is one secret, so it arrives as one
    // variable and is destructured here rather than being split into three
    // that can drift apart.
    const account = JSON.parse(serviceAccount) as {
      client_email?: string;
      private_key?: string;
      private_key_id?: string;
    };
    if (!account.client_email || !account.private_key) {
      throw new Error(
        "PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON has no client_email/private_key",
      );
    }
    attestors.android = new PlayIntegrityAttestor({
      packageName,
      clientEmail: account.client_email,
      privateKey: account.private_key,
      keyId: account.private_key_id,
    });
  }

  return attestors;
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

  const built: Deps = {
    auth: new SupabaseAuthenticator({
      client: admin,
      jwksUrl: `${supabaseUrl}/auth/v1/.well-known/jwks.json`,
    }),
    blocks: new SupabaseBlockStore(admin),
    trials: new SupabaseTrialStore(admin),
    vouchers: new SupabaseVoucherStore(admin),
    attestors: buildAttestors(),
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
