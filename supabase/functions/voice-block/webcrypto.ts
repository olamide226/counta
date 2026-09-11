// The WebCrypto vocabulary shared by the two halves of JWS in this function:
// auth.ts, which verifies user tokens against the project JWKS, and
// providers/jwt.ts, which signs the assertions Apple and Google authenticate
// us with.
//
// Only the *table* and the byte encoding are shared, deliberately. There is no
// sign function here and no key import here, so auth.ts still gains no signing
// path by importing this — the split the two modules are built around survives
// having one place that knows what ES256 means.

/** The two algorithms this function signs or verifies with. */
export type JwtAlgorithm = "ES256" | "RS256";

export interface JwtAlgorithmSpec {
  /** `crypto.subtle.importKey` params, for a public or a private key alike. */
  readonly import: EcKeyImportParams | RsaHashedImportParams;
  /**
   * What `crypto.subtle.sign` and `.verify` both take for this algorithm.
   * WebCrypto uses one parameter shape for the pair, so there is nothing to
   * split here; who may sign is decided by which module imports a key with a
   * "sign" usage, not by this table.
   */
  readonly operation: AlgorithmIdentifier | EcdsaParams;
}

export const JWT_ALGORITHMS: Record<JwtAlgorithm, JwtAlgorithmSpec> = {
  ES256: {
    import: { name: "ECDSA", namedCurve: "P-256" },
    operation: { name: "ECDSA", hash: "SHA-256" },
  },
  RS256: {
    import: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    operation: { name: "RSASSA-PKCS1-v1_5" },
  },
};

/**
 * The spec for an algorithm named in a token header, or undefined for one this
 * function does not implement — HS256, the legacy shared-secret scheme, being
 * the one that actually turns up. `hasOwn` rather than a bare lookup so that
 * `alg: "constructor"` cannot resolve to anything.
 */
export function jwtAlgorithm(name: string): JwtAlgorithmSpec | undefined {
  return Object.hasOwn(JWT_ALGORITHMS, name)
    ? JWT_ALGORITHMS[name as JwtAlgorithm]
    : undefined;
}

/**
 * Decodes base64url. Plain base64 decodes correctly too — the substitutions
 * are no-ops on an alphabet that has neither `-` nor `_`, and padding a string
 * that is already padded adds nothing — which is why a PEM body goes through
 * the same function as a JWS segment.
 */
export function base64UrlToBytes(value: string): Uint8Array<ArrayBuffer> {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Encodes base64url, unpadded, as every JWS field wants it. */
export function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
