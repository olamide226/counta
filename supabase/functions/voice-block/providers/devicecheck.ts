import { DeviceAttestation, DeviceAttestor, TrialGate } from "../types.ts";
import { attestationFetch } from "./http.ts";
import { lazyKey, signJwt } from "./jwt.ts";

/**
 * Apple DeviceCheck: two bits per device, per developer team, held on Apple's
 * servers. They survive app deletion, reinstall, device reset and a change of
 * the Apple Account signed in on the device, which is exactly the property a
 * once-per-device trial needs and the only one a reinstallable app cannot
 * re-mint for itself (req 11.2, 11.3).
 *
 * `POST https://{host}/v1/query_two_bits`  -> { bit0, bit1, last_update_time }
 * `POST https://{host}/v1/update_two_bits` -> 200
 * Both take `{ device_token, transaction_id, timestamp }` and authenticate
 * with an ES256 assertion signed by the team's DeviceCheck key.
 * (developer.apple.com/documentation/devicecheck/accessing-and-modifying-per-device-data)
 *
 * **The production and development hosts hold separate bit stores.** A device
 * that claimed the trial against one has not claimed it against the other,
 * which is what makes testing possible and what makes a build pointed at the
 * wrong host report every device as unclaimed.
 */
export class AppleDeviceCheckAttestor implements DeviceAttestor {
  readonly gate: TrialGate = "devicecheck";

  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private readonly signingKey: () => Promise<CryptoKey>;
  private assertion?: { jwt: string; mintedAt: number };

  constructor(private readonly opts: DeviceCheckOptions) {
    this.fetchFn = opts.fetch ?? fetch;
    this.now = opts.now ?? (() => Date.now());
    this.signingKey = lazyKey("devicecheck", opts.privateKey, "ES256");
  }

  async check(attestation: string): Promise<DeviceAttestation> {
    const bits = await this.queryTwoBits(attestation);
    const claimed = this.opts.bit === 0 ? bits.bit0 : bits.bit1;
    // The other bit belongs to a sibling app on the same Apple team, so it is
    // carried through the update verbatim. Apple documents both bits as
    // individually optional but says nothing about what omitting one does to
    // its stored value, and guessing wrong here would silently clobber
    // another product's flag — so both are always sent.
    const other = this.opts.bit === 0 ? bits.bit1 : bits.bit0;

    return {
      eligible: !claimed,
      claim: () =>
        this.updateTwoBits(attestation, {
          bit0: this.opts.bit === 0 ? true : other,
          bit1: this.opts.bit === 1 ? true : other,
        }),
    };
  }

  /**
   * A device Apple has never seen has no bit state at all, and Apple answers
   * that with a 200 whose body is not the bit document. There is no documented
   * literal for that body, so the absence of `bit0`/`bit1` is what is matched
   * rather than a magic string that could change under us — and an unseen
   * device reads as unclaimed, which is the answer that lets a first-time
   * device take the trial.
   */
  private async queryTwoBits(deviceToken: string): Promise<TwoBits> {
    const text = await this.post("query_two_bits", { device_token: deviceToken });

    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return { bit0: false, bit1: false };
    }
    const body = parsed as Partial<TwoBits>;
    if (typeof body?.bit0 !== "boolean" || typeof body?.bit1 !== "boolean") {
      return { bit0: false, bit1: false };
    }
    return { bit0: body.bit0, bit1: body.bit1 };
  }

  private async updateTwoBits(
    deviceToken: string,
    bits: TwoBits,
  ): Promise<void> {
    await this.post("update_two_bits", { device_token: deviceToken, ...bits });
  }

  /**
   * Resolves to the response body. attestationFetch owns the refusals: a 400
   * is Bad Device Token / Bad Bits / Bad Timestamp / Bad Payload and is the
   * client's problem, while a 401 or 403 is our own assertion — the key, the
   * team id, or the key's DeviceCheck capability — and decides nothing about
   * this device (req 11.9).
   */
  private post(
    path: "query_two_bits" | "update_two_bits",
    body: Record<string, unknown>,
  ): Promise<string> {
    return this.assertionHeader().then((authorization) =>
      attestationFetch(
        "devicecheck",
        this.fetchFn,
        `https://${this.opts.host}/v1/${path}`,
        {
          method: "POST",
          headers: {
            Authorization: authorization,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            ...body,
            transaction_id: crypto.randomUUID(),
            // Apple wants milliseconds since the epoch, from our own clock.
            timestamp: this.now(),
          }),
        },
      )
    );
  }

  /**
   * One assertion per worker, reused for well under Apple's one-hour ceiling.
   * Apple asks providers not to mint a fresh token per request; a 401 for an
   * expired token is already handled as indeterminate, so the worst a stale
   * cache costs is one refused request.
   */
  private async assertionHeader(): Promise<string> {
    const cached = this.assertion;
    if (cached && this.now() - cached.mintedAt < ASSERTION_REUSE_MS) {
      return `Bearer ${cached.jwt}`;
    }
    const mintedAt = this.now();
    const jwt = await signJwt(
      await this.signingKey(),
      "ES256",
      { kid: this.opts.keyId },
      { iss: this.opts.teamId, iat: Math.floor(mintedAt / 1000) },
    );
    this.assertion = { jwt, mintedAt };
    return `Bearer ${jwt}`;
  }
}

export interface DeviceCheckOptions {
  /** Apple developer team that owns the bits. */
  teamId: string;
  /** Key id of a key with the DeviceCheck capability. */
  keyId: string;
  /** The `.p8` contents, straight from Deno.env — never written to a file. */
  privateKey: string;
  /** `api.devicecheck.apple.com`, or the development host. */
  host: string;
  /**
   * Which of the team's two bits means "this device took the Counta trial".
   * The bits are per team, not per app: see the allocation table in
   * specs/voice-phrase-counting/design.md before changing it (req 11.4).
   */
  bit: 0 | 1;
  fetch?: typeof fetch;
  /** Injected so tests control the timestamp and the assertion cache. */
  now?: () => number;
}

interface TwoBits {
  bit0: boolean;
  bit1: boolean;
}

/** Well inside Apple's one-hour ceiling, and no more often than they ask. */
const ASSERTION_REUSE_MS = 30 * 60_000;
