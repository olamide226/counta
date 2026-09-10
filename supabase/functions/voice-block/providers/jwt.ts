// Signing side of JWS, for the two upstreams that authenticate with a
// self-signed assertion rather than an API key: Apple DeviceCheck (ES256, the
// team's .p8) and Google's token endpoint (RS256, the service account key).
//
// auth.ts is the verifying counterpart and shares nothing with this on
// purpose: it holds public keys fetched from a JWKS and must never gain a
// signing path.

/** The two algorithms the upstreams here require. */
export type JwtAlgorithm = "ES256" | "RS256";

const PARAMS: Record<
  JwtAlgorithm,
  { import: EcKeyImportParams | RsaHashedImportParams; sign: AlgorithmIdentifier | EcdsaParams }
> = {
  ES256: {
    import: { name: "ECDSA", namedCurve: "P-256" },
    sign: { name: "ECDSA", hash: "SHA-256" },
  },
  RS256: {
    import: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    sign: { name: "RSASSA-PKCS1-v1_5" },
  },
};

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
    decodeBase64(body),
    PARAMS[algorithm].import,
    false,
    ["sign"],
  );
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
    PARAMS[algorithm].sign,
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

function encodeSegment(value: Record<string, unknown>): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decodeBase64(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
