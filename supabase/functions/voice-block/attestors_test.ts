import { assertEquals, assertRejects } from "@std/assert";
import { buildAttestors } from "./attestors.ts";
import type { EnvReader } from "./attestors.ts";
import { ProviderError } from "./types.ts";

// Which platforms get a trial gate, from a fake environment. The point of
// every case here is the same: a credential problem must cost the trial for
// one platform and nothing else. /voice-block and /release pay for the whole
// feature and must keep answering.

const APPLE = {
  APPLE_TEAM_ID: "TEAM123456",
  APPLE_DEVICECHECK_KEY_ID: "KEY1234567",
  APPLE_DEVICECHECK_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\\nMII\\n-----END PRIVATE KEY-----",
};

const GOOGLE_JSON = JSON.stringify({
  type: "service_account",
  client_email: "counta@example.iam.gserviceaccount.com",
  private_key: "-----BEGIN PRIVATE KEY-----\nMII\n-----END PRIVATE KEY-----",
  private_key_id: "kid-1",
});

function envOf(values: Record<string, string>): EnvReader {
  // Mirrors index.ts's reader, where an empty string is an unset variable.
  return (name) => (values[name] ? values[name] : undefined);
}

const build = (values: Record<string, string>) => buildAttestors(envOf(values));

Deno.test("attestors: both platforms are gated when both are configured", () => {
  const attestors = build({
    ...APPLE,
    PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
    PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: GOOGLE_JSON,
  });

  assertEquals(attestors.ios?.gate, "devicecheck");
  assertEquals(attestors.android?.gate, "play_integrity");
});

Deno.test("attestors: an unset credential turns off that platform only", () => {
  // The documented, deliberate case: no Apple key means no iOS trial, and
  // /trial answers platform_unsupported rather than 503ing on every call.
  const attestors = build({
    PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
    PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: GOOGLE_JSON,
  });
  assertEquals(attestors.ios, undefined);
  assertEquals(attestors.android?.gate, "play_integrity");

  // Apple's three are all-or-nothing.
  const partial = build({
    APPLE_TEAM_ID: APPLE.APPLE_TEAM_ID,
    APPLE_DEVICECHECK_KEY_ID: APPLE.APPLE_DEVICECHECK_KEY_ID,
  });
  assertEquals(partial.ios, undefined);

  assertEquals(build({}), {});
});

Deno.test("attestors: a malformed Google key costs the Android trial and nothing else", async () => {
  // Parsing this at wiring time used to throw out of the dependency builder,
  // so Deno.serve's catch answered 500 misconfigured for /voice-block and
  // /release too, on every request until someone redeployed. One badly pasted
  // secret took down the endpoints that pay for the feature.
  //
  // The credential is the adapter's now, so the property is stronger than "the
  // builder does not throw": the failure cannot happen anywhere but inside
  // check(), on the Android trial request that needed the key.
  const broken = [
    "{not json",
    "null",
    "[]",
    JSON.stringify({ client_email: "counta@example.com" }), // no private_key
    JSON.stringify({ private_key: "-----BEGIN PRIVATE KEY-----" }), // no email
    JSON.stringify({ client_email: "", private_key: "x" }),
    JSON.stringify({ client_email: "a@b.c", private_key: 42 }),
  ];

  for (const value of broken) {
    const attestors = build({
      ...APPLE,
      PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
      PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: value,
    });

    // Wiring succeeds, so nothing that shares this dependency graph is lost.
    assertEquals(attestors.ios?.gate, "devicecheck", value);
    assertEquals(attestors.android?.gate, "play_integrity", value);

    // And the trial that needs it is refused as an unavailable provider — a
    // 503 from the router, never an attestation verdict: nothing has been
    // decided about the device, and it is our own credential that is wrong.
    const error = await assertRejects(
      () => attestors.android!.check("integrity-token"),
      ProviderError,
    );
    assertEquals(error.reason, "unavailable", value);
  }
});

Deno.test("attestors: an empty secret is an unset one, not a broken one", () => {
  // index.ts's reader collapses the two, and the difference matters: an unset
  // variable is an operator who has not enabled Android yet.
  const attestors = build({
    ...APPLE,
    PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
    PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: "",
  });
  assertEquals(attestors.android, undefined);
  assertEquals(attestors.ios?.gate, "devicecheck");
});

Deno.test("attestors: a service account without a key id is still usable", async () => {
  // private_key_id is optional in Google's JWT spec, and a key file that omits
  // it must not be read as broken. Proved by getting past the parse to the key
  // import, which is where this deliberately unreadable PEM fails instead.
  const attestors = build({
    PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
    PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: JSON.stringify({
      client_email: "counta@example.iam.gserviceaccount.com",
      private_key: "-----BEGIN PRIVATE KEY-----\nMII\n-----END PRIVATE KEY-----",
    }),
  });
  assertEquals(attestors.android?.gate, "play_integrity");

  const error = await assertRejects(
    () => attestors.android!.check("integrity-token"),
    ProviderError,
  );
  assertEquals(error.message.includes("private key rejected"), true, error.message);
});
