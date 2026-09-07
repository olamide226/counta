import { assertEquals } from "@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import { SupabaseAuthenticator } from "./auth.ts";

const JWKS_URL = "https://project.supabase.co/auth/v1/.well-known/jwks.json";
const USER = "11111111-1111-4111-8111-111111111111";
const NOW_MS = Date.parse("2026-09-07T12:00:00.000Z");

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function encodeJson(value: unknown): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

async function signingKey(kid: string) {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  return { pair, jwk: { ...jwk, kid, use: "sig", alg: "ES256" } };
}

async function makeToken(
  privateKey: CryptoKey,
  kid: string,
  claims: Record<string, unknown>,
): Promise<string> {
  const signed = `${encodeJson({ alg: "ES256", typ: "JWT", kid })}.${
    encodeJson(claims)
  }`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(signed),
  );
  return `${signed}.${base64Url(new Uint8Array(signature))}`;
}

/** Records every getUser call so a test can prove the round trip was skipped. */
function fakeClient(userId: string | null) {
  const calls: string[] = [];
  const client = {
    auth: {
      getUser(token: string) {
        calls.push(token);
        return Promise.resolve(
          userId
            ? { data: { user: { id: userId } }, error: null }
            : { data: { user: null }, error: { message: "bad jwt" } },
        );
      },
    },
  } as unknown as SupabaseClient;
  return { client, calls };
}

function jwksResponse(keys: unknown[], seen: string[]): typeof fetch {
  return (input) => {
    seen.push(String(input));
    return Promise.resolve(
      new Response(JSON.stringify({ keys }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  };
}

Deno.test("auth: a valid token is verified locally, without asking GoTrue", async () => {
  const { pair, jwk } = await signingKey("key-1");
  const { client, calls } = fakeClient(null);
  const fetched: string[] = [];
  const auth = new SupabaseAuthenticator({
    client,
    jwksUrl: JWKS_URL,
    fetch: jwksResponse([jwk], fetched),
    now: () => NOW_MS,
  });

  const token = await makeToken(pair.privateKey, "key-1", {
    sub: USER,
    exp: NOW_MS / 1000 + 3600,
  });

  assertEquals(await auth.userIdForToken(token), USER);
  assertEquals(calls, []);
  assertEquals(fetched, [JWKS_URL]);

  // The JWKS is cached for the life of the worker.
  assertEquals(await auth.userIdForToken(token), USER);
  assertEquals(fetched.length, 1);
});

Deno.test("auth: a forged signature is rejected without asking GoTrue", async () => {
  const { jwk } = await signingKey("key-1");
  const other = await signingKey("key-1");
  const { client, calls } = fakeClient(USER);
  const auth = new SupabaseAuthenticator({
    client,
    jwksUrl: JWKS_URL,
    fetch: jwksResponse([jwk], []),
    now: () => NOW_MS,
  });

  const token = await makeToken(other.pair.privateKey, "key-1", {
    sub: USER,
    exp: NOW_MS / 1000 + 3600,
  });

  assertEquals(await auth.userIdForToken(token), null);
  assertEquals(calls, []);
});

Deno.test("auth: an expired token is rejected", async () => {
  const { pair, jwk } = await signingKey("key-1");
  const { client, calls } = fakeClient(USER);
  const auth = new SupabaseAuthenticator({
    client,
    jwksUrl: JWKS_URL,
    fetch: jwksResponse([jwk], []),
    now: () => NOW_MS,
  });

  const token = await makeToken(pair.privateKey, "key-1", {
    sub: USER,
    exp: NOW_MS / 1000 - 1,
  });

  assertEquals(await auth.userIdForToken(token), null);
  assertEquals(calls, []);
});

Deno.test("auth: garbage that is not a JWT is rejected without a round trip", async () => {
  const { client, calls } = fakeClient(USER);
  const auth = new SupabaseAuthenticator({
    client,
    jwksUrl: JWKS_URL,
    fetch: jwksResponse([], []),
    now: () => NOW_MS,
  });

  assertEquals(await auth.userIdForToken("not-a-jwt"), null);
  assertEquals(await auth.userIdForToken("a.b.c"), null);
  assertEquals(calls, []);
});

Deno.test("auth: a legacy HS256 token falls back to GoTrue", async () => {
  const { client, calls } = fakeClient(USER);
  const auth = new SupabaseAuthenticator({
    client,
    jwksUrl: JWKS_URL,
    fetch: jwksResponse([], []),
    now: () => NOW_MS,
  });

  const token = `${encodeJson({ alg: "HS256", typ: "JWT" })}.${
    encodeJson({ sub: USER })
  }.signature`;

  assertEquals(await auth.userIdForToken(token), USER);
  assertEquals(calls, [token]);
});

Deno.test("auth: an unreachable JWKS falls back to GoTrue rather than 401ing", async () => {
  const { pair, jwk } = await signingKey("key-1");
  const { client, calls } = fakeClient(USER);
  const auth = new SupabaseAuthenticator({
    client,
    jwksUrl: JWKS_URL,
    fetch: () => Promise.reject(new Error("network down")),
    now: () => NOW_MS,
  });

  const token = await makeToken(pair.privateKey, "key-1", {
    sub: USER,
    exp: NOW_MS / 1000 + 3600,
  });

  assertEquals(await auth.userIdForToken(token), USER);
  assertEquals(calls, [token]);
  assertEquals(jwk.kid, "key-1");
});

Deno.test("auth: an unknown kid is not a fetch amplifier", async () => {
  const { pair } = await signingKey("key-1");
  const { client } = fakeClient(USER);
  const fetched: string[] = [];
  let clock = NOW_MS;
  const auth = new SupabaseAuthenticator({
    client,
    jwksUrl: JWKS_URL,
    fetch: jwksResponse([], fetched),
    now: () => clock,
  });

  const token = await makeToken(pair.privateKey, "unknown-kid", {
    sub: USER,
    exp: NOW_MS / 1000 + 3600,
  });

  await auth.userIdForToken(token);
  await auth.userIdForToken(token);
  assertEquals(fetched.length, 1);

  // Past the refresh interval a rotated key can still be picked up.
  clock += 61_000;
  await auth.userIdForToken(token);
  assertEquals(fetched.length, 2);
});
