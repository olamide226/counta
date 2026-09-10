import {
  AttestationError,
  DeviceAttestation,
  DeviceAttestor,
  ProviderError,
  TrialGate,
} from "../types.ts";
import { attestationFetch, providerFetch } from "./http.ts";
import { lazyKey, signJwt } from "./jwt.ts";

/**
 * Google Play Integrity, decoded server-side.
 *
 * `POST https://playintegrity.googleapis.com/v1/{package}:decodeIntegrityToken`
 * with `{ integrity_token }` returns a `tokenPayloadExternal` carrying the
 * verdicts (developer.android.com/google/play/integrity/verdicts). The call is
 * authenticated with a Google access token minted from the service account key
 * by the JWT-bearer grant.
 *
 * **This attestor never reports a device as already claimed.** Play Integrity
 * says whether the app and device are genuine and offers no per-device
 * storage, so there is nowhere to record a claim: `claim()` is a no-op and the
 * `counta.trial_grants` row keyed on the Supabase user is the only record
 * (req 11.6). That makes the Android gate weaker than the iOS one by
 * construction; the design says so plainly rather than dressing it up, and a
 * device fingerprint — the obvious way to close it — is prohibited (req 11.7).
 */
export class PlayIntegrityAttestor implements DeviceAttestor {
  readonly gate: TrialGate = "play_integrity";
  readonly tokenField = "integrity_token";

  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private readonly signingKey: () => Promise<CryptoKey>;
  private accessToken?: { value: string; expiresAt: number };

  constructor(private readonly opts: PlayIntegrityOptions) {
    this.fetchFn = opts.fetch ?? fetch;
    this.now = opts.now ?? (() => Date.now());
    this.signingKey = lazyKey("playintegrity", opts.privateKey, "RS256");
  }

  async check(attestation: string): Promise<DeviceAttestation> {
    const payload = await this.decode(attestation);
    this.assertGenuine(payload);
    return { eligible: true, claim: () => Promise.resolve() };
  }

  /**
   * Requires a genuine, unmodified, Play-recognised build on a genuine device
   * with a licensed install (req 11.5).
   *
   * The three verdicts fail in two different ways, and the difference is what
   * the client is told. A verdict that says "no" is a rejection: this build or
   * this device will not pass, and the same token never will either (400). A
   * verdict Google could not evaluate is not an answer at all, so the trial is
   * refused with the check left retryable (503, req 11.9). Reading UNEVALUATED
   * as "no" would permanently deny a legitimate device that happened to ask
   * during a Play Store outage.
   */
  private assertGenuine(payload: TokenPayload): void {
    const request = payload.requestDetails;
    // A payload with no request details at all is not a verdict — Google gave
    // us something we cannot read, which is not the same as reading it and
    // finding a different app.
    if (request?.requestPackageName === undefined) {
      throw new AttestationError(
        "indeterminate",
        "playintegrity: no request details",
      );
    }
    if (request.requestPackageName !== this.opts.packageName) {
      throw new AttestationError(
        "rejected",
        `playintegrity: verdict is for ${request.requestPackageName}`,
      );
    }

    // A token minted long ago is one that leaked; a farm replaying it would
    // otherwise buy a trial per anonymous account for the price of one device.
    const issuedAt = Number(request.timestampMillis);
    if (!Number.isFinite(issuedAt)) {
      throw new AttestationError("indeterminate", "playintegrity: no timestamp");
    }
    const age = this.now() - issuedAt;
    if (age > MAX_TOKEN_AGE_MS || age < -MAX_CLOCK_SKEW_MS) {
      throw new AttestationError(
        "rejected",
        `playintegrity: token is ${Math.round(age / 1000)}s old`,
      );
    }

    const app = payload.appIntegrity?.appRecognitionVerdict;
    if (app === undefined || app === "UNEVALUATED") {
      throw new AttestationError("indeterminate", `playintegrity: app ${app}`);
    }
    if (app !== "PLAY_RECOGNIZED") {
      throw new AttestationError("rejected", `playintegrity: app ${app}`);
    }

    const device = payload.deviceIntegrity?.deviceRecognitionVerdict;
    if (device === undefined) {
      throw new AttestationError("indeterminate", "playintegrity: no device verdict");
    }
    // An empty array is Google's positive statement that the device shows
    // signs of attack — a refusal, not an absence.
    if (!device.includes("MEETS_DEVICE_INTEGRITY")) {
      throw new AttestationError(
        "rejected",
        `playintegrity: device [${device.join(",")}]`,
      );
    }

    const licence = payload.accountDetails?.appLicensingVerdict;
    if (licence === undefined || licence === "UNEVALUATED") {
      throw new AttestationError(
        "indeterminate",
        `playintegrity: licence ${licence}`,
      );
    }
    if (licence !== "LICENSED") {
      throw new AttestationError("rejected", `playintegrity: licence ${licence}`);
    }
  }

  /**
   * attestationFetch owns the refusals: a 400 is Google declining to decode
   * the client's token, while a 401 or 403 is our own credentials or an API
   * not enabled on the project, which decides nothing about this device.
   */
  private async decode(integrityToken: string): Promise<TokenPayload> {
    const text = await attestationFetch(
      "playintegrity",
      this.fetchFn,
      `${PLAY_INTEGRITY_URL}/${
        encodeURIComponent(this.opts.packageName)
      }:decodeIntegrityToken`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${await this.googleAccessToken()}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({ integrity_token: integrityToken }),
      },
    );

    try {
      return (JSON.parse(text) as DecodeResponse).tokenPayloadExternal ?? {};
    } catch {
      throw new AttestationError("indeterminate", "playintegrity: unparseable verdict");
    }
  }

  /**
   * Mints a Google access token with the service-account JWT-bearer grant and
   * reuses it until shortly before it expires. Each trial request would
   * otherwise pay for two round trips instead of one.
   */
  private async googleAccessToken(): Promise<string> {
    const cached = this.accessToken;
    if (cached && cached.expiresAt - this.now() > TOKEN_REFRESH_MARGIN_MS) {
      return cached.value;
    }

    const issuedAt = Math.floor(this.now() / 1000);
    const assertion = await signJwt(
      await this.signingKey(),
      "RS256",
      { typ: "JWT", ...(this.opts.keyId ? { kid: this.opts.keyId } : {}) },
      {
        iss: this.opts.clientEmail,
        scope: SCOPE,
        aud: GOOGLE_TOKEN_URL,
        iat: issuedAt,
        exp: issuedAt + ASSERTION_TTL_SECONDS,
      },
    );

    const response = await providerFetch(
      "google-oauth",
      this.fetchFn,
      GOOGLE_TOKEN_URL,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
          assertion,
        }).toString(),
      },
    );
    const body = (await response.json()) as {
      access_token?: string;
      expires_in?: number;
    };
    if (!body.access_token) {
      throw new ProviderError("unavailable", "google-oauth: no access_token");
    }
    this.accessToken = {
      value: body.access_token,
      expiresAt: this.now() + (body.expires_in ?? 3600) * 1000,
    };
    return body.access_token;
  }
}

export interface PlayIntegrityOptions {
  /** The Android application id the verdict must name. */
  packageName: string;
  /** Service account `client_email`. */
  clientEmail: string;
  /** Service account `private_key` (PKCS#8 PEM), straight from Deno.env. */
  privateKey: string;
  /** Service account `private_key_id`; optional, per Google's JWT spec. */
  keyId?: string;
  fetch?: typeof fetch;
  /** Injected so tests control token freshness and the access-token cache. */
  now?: () => number;
}

/** The subset of `tokenPayloadExternal` the gate reads. */
interface TokenPayload {
  requestDetails?: {
    requestPackageName?: string;
    timestampMillis?: string;
  };
  appIntegrity?: { appRecognitionVerdict?: string };
  deviceIntegrity?: { deviceRecognitionVerdict?: string[] };
  accountDetails?: { appLicensingVerdict?: string };
}

interface DecodeResponse {
  tokenPayloadExternal?: TokenPayload;
}

const PLAY_INTEGRITY_URL = "https://playintegrity.googleapis.com/v1";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/playintegrity";

/** Google's ceiling for a service-account assertion is one hour. */
const ASSERTION_TTL_SECONDS = 3600;
const TOKEN_REFRESH_MARGIN_MS = 60_000;

/** A trial request follows its token within seconds; minutes is generous. */
const MAX_TOKEN_AGE_MS = 10 * 60_000;
const MAX_CLOCK_SKEW_MS = 60_000;
