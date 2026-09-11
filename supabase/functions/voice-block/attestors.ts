import { AppleDeviceCheckAttestor } from "./providers/devicecheck.ts";
import { PlayIntegrityAttestor } from "./providers/playintegrity.ts";
import type { DeviceAttestor, TrialPlatform } from "./types.ts";

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
 * The trial gate for each platform whose credentials are configured.
 *
 * A platform with no attestor is not offered the trial (req 11.10), and the
 * endpoint answers `platform_unsupported` for it rather than 503ing on every
 * call. That is deliberate for an *unset* variable: an operator who has not set
 * DeviceCheck up yet should lose the trial, not the block endpoints that pay
 * for the whole feature.
 *
 * A *malformed* variable has to reach the same place, and used not to: parsing
 * the Google service-account JSON eagerly threw out of the dependency builder,
 * so `Deno.serve`'s catch answered `500 misconfigured` for /voice-block and
 * /release too, on every request until someone redeployed. One badly pasted
 * secret took down the paid endpoints.
 *
 * Nothing is validated here now — nothing at all, for either platform. Each
 * adapter parses its own credential where it already imports its own key, and
 * reports an unusable one as an unavailable provider on the request that
 * needed it. That was already the Apple story and already half the Google one,
 * because a well-formed JSON carrying an unreadable private key could only
 * ever fail at the import; the eager check was a partial duplicate of a rule
 * that could not be completed at wiring time, and it needed a shape of its own
 * to be tested against. This function now only answers "is it configured?".
 */
export function buildAttestors(
  env: EnvReader,
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
  const serviceAccountJson = env("PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON");
  if (packageName && serviceAccountJson) {
    attestors.android = new PlayIntegrityAttestor({
      packageName,
      serviceAccountJson,
    });
  }

  return attestors;
}
