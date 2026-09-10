import { assertEquals } from "@std/assert";
import { buildAttestors } from "./attestors.ts";
import type { EnvReader } from "./attestors.ts";

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

function build(values: Record<string, string>) {
  const logs: Array<{ event: string; fields: Record<string, unknown> }> = [];
  const attestors = buildAttestors(
    envOf(values),
    (event, fields) => logs.push({ event, fields }),
  );
  return { attestors, logs };
}

Deno.test("attestors: both platforms are gated when both are configured", () => {
  const { attestors, logs } = build({
    ...APPLE,
    PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
    PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: GOOGLE_JSON,
  });

  assertEquals(attestors.ios?.gate, "devicecheck");
  assertEquals(attestors.android?.gate, "play_integrity");
  assertEquals(logs, []);
});

Deno.test("attestors: an unset credential turns off that platform only", () => {
  // The documented, deliberate case: no Apple key means no iOS trial, and
  // /trial answers platform_unsupported rather than 503ing on every call.
  const { attestors } = build({
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
  assertEquals(partial.attestors.ios, undefined);

  const none = build({});
  assertEquals(none.attestors, {});
});

Deno.test("attestors: a malformed Google key disables the trial, not the paid endpoints", () => {
  // Parsing this eagerly used to throw out of the dependency builder, so
  // Deno.serve's catch answered 500 misconfigured for /voice-block and
  // /release too, on every request until someone redeployed. One badly pasted
  // secret took down the endpoints that pay for the feature.
  const broken = [
    "{not json",
    "",
    "null",
    "[]",
    JSON.stringify({ client_email: "counta@example.com" }), // no private_key
    JSON.stringify({ private_key: "-----BEGIN PRIVATE KEY-----" }), // no email
    JSON.stringify({ client_email: "", private_key: "x" }),
    JSON.stringify({ client_email: "a@b.c", private_key: 42 }),
  ];

  for (const value of broken) {
    const { attestors, logs } = build({
      ...APPLE,
      PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
      PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: value,
    });

    // No throw, no android gate, and iOS is untouched.
    assertEquals(attestors.android, undefined, value);
    assertEquals(attestors.ios?.gate, "devicecheck", value);

    // Loud, because unlike an unset variable somebody meant to enable this.
    // An empty string is an unset variable, though, so it says nothing.
    const complained = logs.some((l) => l.event === "attestor_unavailable");
    assertEquals(complained, value !== "", value);
  }
});

Deno.test("attestors: a service account without a key id is still usable", () => {
  // private_key_id is optional in Google's JWT spec, and a key file that omits
  // it must not be read as broken.
  const { attestors, logs } = build({
    PLAY_INTEGRITY_PACKAGE_NAME: "com.ruach.counta",
    PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON: JSON.stringify({
      client_email: "counta@example.iam.gserviceaccount.com",
      private_key: "-----BEGIN PRIVATE KEY-----\nMII\n-----END PRIVATE KEY-----",
    }),
  });
  assertEquals(attestors.android?.gate, "play_integrity");
  assertEquals(logs, []);
});
