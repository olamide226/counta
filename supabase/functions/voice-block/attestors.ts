import { AppleDeviceCheckAttestor } from "./providers/devicecheck.ts";
import { PlayIntegrityAttestor } from "./providers/playintegrity.ts";
import type { DeviceAttestor, LogFn, TrialPlatform } from "./types.ts";

// Which platforms are offered the trial, decided from the environment.
//
// A separate module from index.ts because this is the one piece of the wiring
// with a decision in it: everything else there is "read a secret, hand it to a
// constructor", while this reads five and answers a question. Being importable
// without starting a server is also what lets attestors_test.ts prove that a
// broken credential costs the trial and nothing else.

/** Just enough of `Deno.env` to be substitutable in a test. */
export type EnvReader = (name: string) => string | undefined;

/**
 * The trial gate for each platform whose credentials are configured and usable.
 *
 * A platform with no attestor is not offered the trial (req 11.10), and the
 * endpoint answers `platform_unsupported` for it rather than 503ing on every
 * call. That is deliberate for an *unset* variable: an operator who has not
 * set DeviceCheck up yet should lose the trial, not the block endpoints that
 * pay for the whole feature.
 *
 * A *malformed* variable has to reach the same place, and used not to: parsing
 * the service-account JSON eagerly threw out of the dependency builder, so
 * `Deno.serve`'s catch answered `500 misconfigured` for /voice-block and
 * /release too, on every request until someone redeployed. One badly pasted
 * secret took down the paid endpoints. Every credential is therefore validated
 * here, and a bad one disables its own platform and says so in the logs.
 */
export function buildAttestors(
  env: EnvReader,
  log: LogFn,
): Partial<Record<TrialPlatform, DeviceAttestor>> {
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
      bit: Number(env("DEVICECHECK_TRIAL_BIT")) === 1 ? 1 : 0,
    });
  }

  const packageName = env("PLAY_INTEGRITY_PACKAGE_NAME");
  const serviceAccount = env("PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON");
  if (packageName && serviceAccount) {
    // The whole service-account JSON is one secret, so it arrives as one
    // variable and is destructured here rather than being split into three
    // that can drift apart. The cost of that is a parse, and a parse can fail.
    const account = googleServiceAccount(serviceAccount);
    if (account) {
      attestors.android = new PlayIntegrityAttestor({
        packageName,
        clientEmail: account.clientEmail,
        privateKey: account.privateKey,
        keyId: account.keyId,
      });
    } else {
      // Loud, because this is a misconfiguration and not a choice: unlike an
      // unset variable, somebody meant to enable the Android trial here.
      log("attestor_unavailable", {
        platform: "android",
        reason: "PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON is not a usable key",
      });
    }
  }

  return attestors;
}

/**
 * The three fields the Play Integrity adapter needs, or null if the secret is
 * not a service-account key. The private key itself is only imported on first
 * use, and a key that is well-formed JSON but not a key still fails there —
 * which the adapter already reports as an unavailable provider rather than as
 * a crash.
 */
function googleServiceAccount(
  raw: string,
): { clientEmail: string; privateKey: string; keyId?: string } | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  const account = parsed as {
    client_email?: unknown;
    private_key?: unknown;
    private_key_id?: unknown;
  } | null;
  if (
    typeof account?.client_email !== "string" ||
    typeof account.private_key !== "string" ||
    account.client_email === "" || account.private_key === ""
  ) {
    return null;
  }
  return {
    clientEmail: account.client_email,
    privateKey: account.private_key,
    keyId: typeof account.private_key_id === "string"
      ? account.private_key_id
      : undefined,
  };
}
