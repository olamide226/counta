import { assertEquals, assertRejects, assertStringIncludes } from "@std/assert";
import { AppleDeviceCheckAttestor } from "./providers/devicecheck.ts";
import { PlayIntegrityAttestor } from "./providers/playintegrity.ts";
import { jsonResponse, recorder } from "./testing/fakes.ts";
import { AttestationError, ProviderError } from "./types.ts";
import { base64UrlToBytes } from "./webcrypto.ts";

// The wire shape of the two attestation providers, against a stubbed fetch.
// Nothing here reaches Apple or Google; what is pinned is the request each one
// sends and how each documented answer is classified.

const DEVICE_TOKEN = "wlkCDA2Hy/CfrMqVAShs1BAR";
const NOW = Date.parse("2026-09-07T12:00:00.000Z");

/**
 * A throwaway key pair, generated at run time so no secret is committed. Two
 * of them, once each: RSA-2048 keygen costs a quarter of a second and the
 * tests only need a key that imports and signs.
 */
const KEYS = new Map<string, Promise<string>>();
function privateKeyPem(algorithm: "ES256" | "RS256"): Promise<string> {
  const cached = KEYS.get(algorithm) ?? generateKeyPem(algorithm);
  KEYS.set(algorithm, cached);
  return cached;
}

async function generateKeyPem(algorithm: "ES256" | "RS256"): Promise<string> {
  const params: EcKeyGenParams | RsaHashedKeyGenParams = algorithm === "ES256"
    ? { name: "ECDSA", namedCurve: "P-256" }
    : {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    };
  const pair = await crypto.subtle.generateKey(params, true, ["sign", "verify"]);
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  const base64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  // Wrapped and newline-escaped, the way a secret manager hands it back.
  return `-----BEGIN PRIVATE KEY-----\\n${
    base64.match(/.{1,64}/g)!.join("\\n")
  }\\n-----END PRIVATE KEY-----\\n`;
}

async function deviceCheck(
  responses: Response[],
  overrides: { bit?: 0 | 1; host?: string } = {},
) {
  const { sent, fetchFn } = recorder(responses);
  const attestor = new AppleDeviceCheckAttestor({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    privateKey: await privateKeyPem("ES256"),
    host: overrides.host ?? "api.devicecheck.apple.com",
    bit: overrides.bit ?? 0,
    fetch: fetchFn,
    now: () => NOW,
  });
  return { attestor, sent };
}

function decodeSegment(segment: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(base64UrlToBytes(segment)));
}

// ---------------------------------------------------------------------------
// DeviceCheck

Deno.test("DeviceCheck: queries the two bits with an ES256 team assertion", async () => {
  const { attestor, sent } = await deviceCheck([
    jsonResponse({ bit0: false, bit1: false, last_update_time: "2026-05" }),
  ]);

  const verdict = await attestor.check(DEVICE_TOKEN);
  assertEquals(verdict.eligible, true);

  assertEquals(sent[0].url, "https://api.devicecheck.apple.com/v1/query_two_bits");
  assertEquals(sent[0].init.method, "POST");
  assertEquals(sent[0].body.device_token, DEVICE_TOKEN);
  // Milliseconds since the epoch, from our own clock, per Apple's field table.
  assertEquals(sent[0].body.timestamp, NOW);
  assertEquals(typeof sent[0].body.transaction_id, "string");

  const [rawHeader, rawPayload, signature] = sent[0].headers.Authorization
    .replace(/^Bearer /, "").split(".");
  assertEquals(decodeSegment(rawHeader), { kid: "KEY1234567", alg: "ES256" });
  assertEquals(decodeSegment(rawPayload), {
    iss: "TEAM123456",
    iat: Math.floor(NOW / 1000),
  });
  // ES256 over P-256 is a raw r‖s pair: 64 bytes, 86 base64url characters.
  assertEquals(signature.length, 86);
});

Deno.test("DeviceCheck: a device Apple has never seen reads as unclaimed", async () => {
  // No bit state comes back as a 200 whose body is not the bit document.
  // Apple documents no literal for it, so the absence of bit0/bit1 is what is
  // matched — a magic string would break the first time they reworded it.
  const { attestor, sent } = await deviceCheck([
    new Response("Bit State Not Found", { status: 200 }),
    new Response("", { status: 200 }),
  ]);

  const verdict = await attestor.check(DEVICE_TOKEN);
  assertEquals(verdict.eligible, true);

  await verdict.claim();
  assertEquals(sent[1].url, "https://api.devicecheck.apple.com/v1/update_two_bits");
  assertEquals(sent[1].body.bit0, true);
  assertEquals(sent[1].body.bit1, false);
});

Deno.test("DeviceCheck: a sibling app's bit survives our claim", async () => {
  // The two bits belong to the Apple team, not to an app. Apple documents
  // both update fields as optional but not what omitting one does to the
  // stored value, so ours is set and theirs is written back as it was.
  const { attestor, sent } = await deviceCheck([
    jsonResponse({ bit0: false, bit1: true, last_update_time: "2026-05" }),
    new Response("", { status: 200 }),
  ]);

  const verdict = await attestor.check(DEVICE_TOKEN);
  await verdict.claim();

  assertEquals(sent[1].body.bit0, true);
  assertEquals(sent[1].body.bit1, true);
});

Deno.test("DeviceCheck: the allocated bit already set is not eligible", async () => {
  const { attestor } = await deviceCheck([
    jsonResponse({ bit0: true, bit1: false, last_update_time: "2026-05" }),
  ]);
  assertEquals((await attestor.check(DEVICE_TOKEN)).eligible, false);

  // And bit1 is read when that is the allocation (req 11.4).
  const other = await deviceCheck(
    [jsonResponse({ bit0: true, bit1: false, last_update_time: "2026-05" })],
    { bit: 1 },
  );
  assertEquals((await other.attestor.check(DEVICE_TOKEN)).eligible, true);
});

Deno.test("DeviceCheck: the development host is a separate bit store", async () => {
  const { attestor, sent } = await deviceCheck(
    [jsonResponse({ bit0: true, bit1: false, last_update_time: "2026-05" })],
    { host: "api.development.devicecheck.apple.com" },
  );
  await attestor.check(DEVICE_TOKEN);
  assertStringIncludes(sent[0].url, "https://api.development.devicecheck.apple.com/v1/");
});

Deno.test("DeviceCheck: 400 is rejected, 401 is indeterminate, 429 is a provider failure", async () => {
  const bad = await deviceCheck([new Response("Bad Device Token", { status: 400 })]);
  const rejected = await assertRejects(
    () => bad.attestor.check(DEVICE_TOKEN),
    AttestationError,
  );
  assertEquals(rejected.failure, "rejected");

  // Our own assertion is wrong, which says nothing about this device: the
  // trial stays unclaimed and the client may retry (req 11.9).
  const unauthorised = await deviceCheck([
    new Response("Invalid Authorization Token", { status: 401 }),
  ]);
  const indeterminate = await assertRejects(
    () => unauthorised.attestor.check(DEVICE_TOKEN),
    AttestationError,
  );
  assertEquals(indeterminate.failure, "indeterminate");

  // 429 and 5xx stay with the shared classifier, so the retryable case is
  // recognised in exactly one place.
  const throttled = await deviceCheck([
    new Response("", { status: 429, headers: { "Retry-After": "5" } }),
  ]);
  const provider = await assertRejects(
    () => throttled.attestor.check(DEVICE_TOKEN),
    ProviderError,
  );
  assertEquals(provider.reason, "rate_limited");
  assertEquals(provider.retryAfterMs, 5000);
});

Deno.test("DeviceCheck: one assertion is reused across calls", async () => {
  const { attestor, sent } = await deviceCheck([
    jsonResponse({ bit0: false, bit1: false, last_update_time: "2026-05" }),
    new Response("", { status: 200 }),
  ]);

  const verdict = await attestor.check(DEVICE_TOKEN);
  await verdict.claim();

  assertEquals(sent.length, 2);
  assertEquals(sent[0].headers.Authorization, sent[1].headers.Authorization);
  // But each request gets its own transaction id.
  assertEquals(sent[0].body.transaction_id === sent[1].body.transaction_id, false);
});

// ---------------------------------------------------------------------------
// Play Integrity

const PACKAGE = "com.ruach.counta";

const GENUINE = {
  requestDetails: {
    requestPackageName: PACKAGE,
    requestHash: "aGVsbG8",
    timestampMillis: String(NOW - 5_000),
  },
  appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED" },
  deviceIntegrity: {
    deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY", "MEETS_BASIC_INTEGRITY"],
  },
  accountDetails: { appLicensingVerdict: "LICENSED" },
};

async function playIntegrity(responses: Response[]) {
  const { sent, fetchFn } = recorder([
    jsonResponse({ access_token: "ya29.fake", expires_in: 3600 }),
    ...responses,
  ]);
  const attestor = new PlayIntegrityAttestor({
    packageName: PACKAGE,
    clientEmail: "counta@example.iam.gserviceaccount.com",
    privateKey: await privateKeyPem("RS256"),
    keyId: "kid-1",
    fetch: fetchFn,
    now: () => NOW,
  });
  return { attestor, sent };
}

Deno.test("PlayIntegrity: a genuine verdict is eligible and records nothing", async () => {
  const { attestor, sent } = await playIntegrity([
    jsonResponse({ tokenPayloadExternal: GENUINE }),
  ]);

  const verdict = await attestor.check("integrity-token");
  assertEquals(verdict.eligible, true);
  await verdict.claim();

  // The access token is minted first, with the JWT-bearer grant.
  assertEquals(sent[0].url, "https://oauth2.googleapis.com/token");
  const form = new URLSearchParams(String(sent[0].init.body));
  assertEquals(
    form.get("grant_type"),
    "urn:ietf:params:oauth:grant-type:jwt-bearer",
  );
  const [rawHeader, rawPayload] = form.get("assertion")!.split(".");
  assertEquals(decodeSegment(rawHeader), { typ: "JWT", kid: "kid-1", alg: "RS256" });
  assertEquals(decodeSegment(rawPayload), {
    iss: "counta@example.iam.gserviceaccount.com",
    scope: "https://www.googleapis.com/auth/playintegrity",
    aud: "https://oauth2.googleapis.com/token",
    iat: Math.floor(NOW / 1000),
    exp: Math.floor(NOW / 1000) + 3600,
  });

  assertEquals(
    sent[1].url,
    `https://playintegrity.googleapis.com/v1/${PACKAGE}:decodeIntegrityToken`,
  );
  assertEquals(sent[1].body, { integrity_token: "integrity-token" });
  assertEquals(sent[1].headers.Authorization, "Bearer ya29.fake");

  // claim() writes nowhere: Play Integrity has no per-device storage (11.6).
  assertEquals(sent.length, 2);
});

Deno.test("PlayIntegrity: each way of not being genuine is refused", async () => {
  const cases: Array<[string, unknown, "rejected" | "indeterminate"]> = [
    [
      "repackaged build",
      { ...GENUINE, appIntegrity: { appRecognitionVerdict: "UNRECOGNIZED_VERSION" } },
      "rejected",
    ],
    [
      "rooted device or emulator",
      { ...GENUINE, deviceIntegrity: { deviceRecognitionVerdict: [] } },
      "rejected",
    ],
    [
      "basic integrity only",
      {
        ...GENUINE,
        deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_BASIC_INTEGRITY"] },
      },
      "rejected",
    ],
    [
      "sideloaded install",
      { ...GENUINE, accountDetails: { appLicensingVerdict: "UNLICENSED" } },
      "rejected",
    ],
    [
      "verdict for another package",
      {
        ...GENUINE,
        requestDetails: { ...GENUINE.requestDetails, requestPackageName: "com.other" },
      },
      "rejected",
    ],
    [
      "a token minted an hour ago",
      {
        ...GENUINE,
        requestDetails: {
          ...GENUINE.requestDetails,
          timestampMillis: String(NOW - 3_600_000),
        },
      },
      "rejected",
    ],
    // Google could not evaluate it. Reading that as "no" would permanently
    // deny a real device that asked during an outage (req 11.9).
    [
      "app unevaluated",
      { ...GENUINE, appIntegrity: { appRecognitionVerdict: "UNEVALUATED" } },
      "indeterminate",
    ],
    [
      "licence unevaluated",
      { ...GENUINE, accountDetails: { appLicensingVerdict: "UNEVALUATED" } },
      "indeterminate",
    ],
    ["no verdict at all", {}, "indeterminate"],
  ];

  for (const [name, payload, expected] of cases) {
    const { attestor } = await playIntegrity([
      jsonResponse({ tokenPayloadExternal: payload }),
    ]);
    const error = await assertRejects(
      () => attestor.check("integrity-token"),
      AttestationError,
      undefined,
      name,
    );
    assertEquals(error.failure, expected, name);
  }
});

Deno.test("PlayIntegrity: an undecodable token is rejected, a 403 is not", async () => {
  const bad = await playIntegrity([
    jsonResponse({ error: { code: 400, status: "INVALID_ARGUMENT" } }, 400),
  ]);
  assertEquals(
    (await assertRejects(() => bad.attestor.check("junk"), AttestationError)).failure,
    "rejected",
  );

  // Our own credentials, or the API not enabled on the project: nothing about
  // this device has been decided.
  const forbidden = await playIntegrity([
    jsonResponse({ error: { code: 403, status: "PERMISSION_DENIED" } }, 403),
  ]);
  assertEquals(
    (await assertRejects(() => forbidden.attestor.check("t"), AttestationError))
      .failure,
    "indeterminate",
  );
});

Deno.test("PlayIntegrity: the access token is minted once and reused", async () => {
  const { attestor, sent } = await playIntegrity([
    jsonResponse({ tokenPayloadExternal: GENUINE }),
    jsonResponse({ tokenPayloadExternal: GENUINE }),
  ]);

  await attestor.check("first");
  await attestor.check("second");

  assertEquals(sent.length, 3);
  assertEquals(sent.filter((s) => s.url.includes("oauth2")).length, 1);
});
