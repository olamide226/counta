import type { SupabaseClient } from "@supabase/supabase-js";
import type { Authenticator } from "./types.ts";
import { base64UrlToBytes, jwtAlgorithm } from "./webcrypto.ts";

/**
 * Verifies Supabase user JWTs.
 *
 * The function runs with `verify_jwt = false` (config.toml) so that it owns the
 * 401 contract and keeps working when the project moves to asymmetric signing
 * keys. That made every request — including junk — cost a GoTrue round trip
 * before it could be rejected. Tokens are now verified in-process against the
 * project's JWKS, which is fetched once per worker and refreshed only when a
 * key id turns up that the cache has never seen.
 *
 * `getUser` remains the fallback for anything this cannot decide locally: a
 * legacy HS256 token signed with the shared secret, an algorithm not
 * implemented here, or a JWKS that could not be fetched. A token that *is*
 * verifiable locally and fails is rejected outright — asking Auth for a second
 * opinion on a bad signature would only reintroduce the round trip.
 */
export class SupabaseAuthenticator implements Authenticator {
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private keys = new Map<string, JsonWebKey>();
  private fetchedAt = 0;

  constructor(private readonly opts: AuthenticatorOptions) {
    this.fetchFn = opts.fetch ?? fetch;
    this.now = opts.now ?? (() => Date.now());
  }

  async userIdForToken(token: string): Promise<string | null> {
    const local = await this.verifyLocally(token);
    if (local !== UNVERIFIABLE) return local;

    const { data, error } = await this.opts.client.auth.getUser(token);
    if (error || !data.user) return null;
    return data.user.id;
  }

  private async verifyLocally(
    token: string,
  ): Promise<string | null | typeof UNVERIFIABLE> {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const [rawHeader, rawPayload, rawSignature] = parts;

    const header = decodeJson(rawHeader);
    const payload = decodeJson(rawPayload);
    if (!header || !payload) return null;

    const algorithm = jwtAlgorithm(String(header.alg));
    // HS256 is the legacy shared-secret scheme, which no JWKS can verify.
    if (!algorithm || typeof header.kid !== "string") return UNVERIFIABLE;

    const jwk = await this.keyFor(header.kid);
    if (!jwk) return UNVERIFIABLE;

    let key: CryptoKey;
    try {
      key = await crypto.subtle.importKey(
        "jwk",
        jwk,
        algorithm.import,
        false,
        ["verify"],
      );
    } catch {
      return UNVERIFIABLE;
    }

    const signed = new TextEncoder().encode(`${rawHeader}.${rawPayload}`);
    const valid = await crypto.subtle.verify(
      algorithm.operation,
      key,
      base64UrlToBytes(rawSignature),
      signed,
    );
    if (!valid) return null;

    const nowSeconds = this.now() / 1000;
    if (typeof payload.exp !== "number" || payload.exp <= nowSeconds) {
      return null;
    }
    if (typeof payload.nbf === "number" && payload.nbf > nowSeconds) {
      return null;
    }
    return typeof payload.sub === "string" && payload.sub ? payload.sub : null;
  }

  private async keyFor(kid: string): Promise<JsonWebKey | undefined> {
    const cached = this.keys.get(kid);
    if (cached) return cached;
    // An unknown kid means either a rotated signing key or a forged header;
    // the refresh interval keeps the latter from becoming a fetch amplifier.
    if (this.now() - this.fetchedAt < JWKS_REFRESH_MS) return undefined;
    await this.refreshKeys();
    return this.keys.get(kid);
  }

  private async refreshKeys(): Promise<void> {
    this.fetchedAt = this.now();
    try {
      const response = await this.fetchFn(this.opts.jwksUrl, {
        headers: { Accept: "application/json" },
      });
      if (!response.ok) {
        await response.body?.cancel();
        return;
      }
      const body = (await response.json()) as { keys?: JsonWebKey[] };
      const next = new Map<string, JsonWebKey>();
      for (const key of body.keys ?? []) {
        const kid = (key as { kid?: unknown }).kid;
        if (typeof kid === "string") next.set(kid, key);
      }
      if (next.size > 0) this.keys = next;
    } catch {
      // Leave the cache alone and let getUser decide this request.
    }
  }
}

export interface AuthenticatorOptions {
  /** Consulted only for tokens that cannot be verified locally. */
  client: SupabaseClient;
  /** `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`. */
  jwksUrl: string;
  fetch?: typeof fetch;
  /** Injected so tests control expiry and the refresh interval. */
  now?: () => number;
}

/** Returned when only Auth can answer: fall back rather than reject. */
const UNVERIFIABLE: unique symbol = Symbol("unverifiable");

const JWKS_REFRESH_MS = 60_000;

function decodeJson(segment: string): Record<string, unknown> | null {
  try {
    const text = new TextDecoder().decode(base64UrlToBytes(segment));
    const parsed = JSON.parse(text);
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}
