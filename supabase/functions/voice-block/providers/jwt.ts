// Signing side of JWS, for the two upstreams that authenticate with a
// self-signed assertion rather than an API key: Apple DeviceCheck (ES256, the
// team's .p8) and Google's token endpoint (RS256, the service account key).
//
// auth.ts is the verifying counterpart and shares only webcrypto.ts's table
// with this: it holds public keys fetched from a JWKS and must never gain a
// signing path, and no function here is importable from there.

import { ProviderError } from "../types.ts";
import {
  base64UrlToBytes,
  bytesToBase64Url,
  JWT_ALGORITHMS,
} from "../webcrypto.ts";
import type { JwtAlgorithm } from "../webcrypto.ts";

/**
 * Imports a PKCS#8 private key from its PEM text.
 *
 * The key arrives from `Deno.env`, never from a file: an Apple `.p8` can be
 * downloaded exactly once, and writing either key to disk inside a function
 * worker would put it somewhere a later bug could read (design: Security).
 *
 * Secret managers and `.env` files disagree about newlines, so a literal
 * backslash-n is accepted as well as a real one — a key that survived a round
 * trip through JSON still imports.
 */
export function importPrivateKey(
  pem: string,
  algorithm: JwtAlgorithm,
): Promise<CryptoKey> {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----(BEGIN|END)[^-]+-----/g, "")
    .replace(/\s+/g, "");
  return crypto.subtle.importKey(
    "pkcs8",
    base64UrlToBytes(body),
    JWT_ALGORITHMS[algorithm].import,
    false,
    ["sign"],
  );
}

/**
 * A private key imported at most once, and never cached as a failure.
 *
 * Both attestors sign with a key that arrives as PEM text in an environment
 * variable, and both want it imported lazily — a worker that never sees a
 * trial request should not pay for the import, and an operator with no key
 * configured should not have a broken one either. What matters is the guard:
 * caching the *rejected* promise would poison the worker, so a bad key fails
 * this request and leaves the next one able to retry the import once the
 * secret is fixed. Written twice, identically, before it lived here.
 *
 * The failure is a ProviderError rather than an AttestationError: nothing
 * about the device has been decided, and it is our own credential that is
 * wrong.
 */
export function lazyKey(
  provider: string,
  pem: string,
  algorithm: JwtAlgorithm,
): () => Promise<CryptoKey> {
  let key: Promise<CryptoKey> | undefined;
  return () => {
    key ??= importPrivateKey(pem, algorithm).catch((error) => {
      key = undefined;
      throw new ProviderError(
        "unavailable",
        `${provider}: private key rejected: ${String(error)}`,
      );
    });
    return key;
  };
}

/**
 * Signs a compact JWS.
 *
 * Web Crypto emits an ECDSA signature as the raw r‖s pair (IEEE P1363), which
 * is exactly what RFC 7518 wants for ES256 — no DER unwrapping, unlike the
 * Node/OpenSSL helpers this would otherwise be ported from. Copying one of
 * those in would corrupt a signature that is already correct.
 */
export async function signJwt(
  key: CryptoKey,
  algorithm: JwtAlgorithm,
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
): Promise<string> {
  const signingInput = `${encodeSegment({ ...header, alg: algorithm })}.${
    encodeSegment(claims)
  }`;
  const signature = await crypto.subtle.sign(
    JWT_ALGORITHMS[algorithm].operation,
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

function encodeSegment(value: Record<string, unknown>): string {
  return bytesToBase64Url(new TextEncoder().encode(JSON.stringify(value)));
}
