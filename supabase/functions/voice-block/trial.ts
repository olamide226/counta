import { json, readJson } from "./respond.ts";
import {
  AttestationError,
  DeviceAttestation,
  Deps,
  ProviderError,
  TrialPlatform,
} from "./types.ts";

// POST /voice-block/trial — the device-gated free trial (req 4.3, 11).
//
// Pure, like the block routes: every collaborator arrives through `deps`, so
// the whole of requirement 11 is exercised in index_test.ts without Apple or
// Google being reachable.

/** The ledger reference and idempotency key for a user's trial payout. */
export function trialReference(userId: string): string {
  return `trial:${userId}`;
}

export async function trial(
  req: Request,
  deps: Deps,
  userId: string,
): Promise<Response> {
  const { config, trials, balance } = deps;

  const body = await readJson(req);
  const requested = body?.platform;
  // Which platforms are supported *is* the injected map. Requirements 11.10
  // and 10.9: a platform with no attestation is not offered the trial rather
  // than offered one that always fails, and an operator who has configured no
  // gate lands in the same place — which is why this is one branch and not
  // two that have to be kept answering alike. The platform is logged because
  // `ios` in this line is a misconfiguration, not a desktop build asking a
  // question it should not have asked.
  const attestor = typeof requested === "string"
    ? deps.attestors[requested as TrialPlatform]
    : undefined;
  if (!attestor) {
    deps.log("trial_platform_unsupported", {
      user_id: userId,
      platform: requested ?? null,
    });
    return json(409, { error: "platform_unsupported" });
  }
  // Sound: `attestors` is keyed by TrialPlatform, so a hit means this string
  // is one of them.
  const platform = requested as TrialPlatform;

  // Which field carries the payload belongs to the adapter, not here: the
  // handler has no business knowing that DeviceCheck says `device_token`.
  const attestation = body?.[attestor.tokenField];
  if (typeof attestation !== "string" || attestation.length === 0) {
    return json(400, { error: "invalid_attestation" });
  }

  // 11.8, and the cheap answer first: a user who already holds a grant is told
  // so without spending an attestation call on it.
  //
  // Sequential where handler.ts:85 would run the pair in parallel, and
  // deliberately. Parallelising trades a Postgres lookup on the first-time
  // path — which today pays for it and finds nothing — for an Apple or Google
  // round trip on every repeat caller, and every reinstall is a repeat caller.
  // The two round trips are not comparable: one is metered by a third party
  // and one is not.
  const existing = await trials.find(userId);
  if (existing) {
    deps.log("trial_already_claimed", {
      user_id: userId,
      platform,
      gate: existing.gate,
      via: "grant_row",
    });
    return json(200, {
      granted: false,
      reason: "already_claimed",
      credits: existing.credits,
    });
  }

  let verdict: DeviceAttestation;
  try {
    verdict = await attestor.check(attestation);
  } catch (error) {
    return refuse(deps, userId, platform, error);
  }

  if (!verdict.eligible) {
    // iOS only: Apple's bit is already set, so this device has taken the
    // trial under some other Supabase user (req 11.2). Not an error — every
    // reinstall asks this question, and the client shows the paywall either
    // way (design: Edge Function contract).
    deps.log("trial_already_claimed", {
      user_id: userId,
      platform,
      gate: attestor.gate,
      via: "attestation",
    });
    return json(200, { granted: false, reason: "already_claimed" });
  }

  // Credits before the row, and the ledger call keyed on the user id.
  //
  // Every step after this is recoverable by a retry precisely because of that
  // key: a retry re-issues the *same* grant, which the ledger applies once, so
  // a failure anywhere below leaves the user with credits, no grant row and no
  // DeviceCheck bit — a state the next attempt walks straight through. The
  // opposite order would write the row first and then have to re-issue the
  // grant on every later "already claimed" answer to stay self-healing, which
  // buys nothing and spends a RevenueCat write per reinstall.
  const credits = config.trialCredits;
  const balanceAfter = await balance.grant(
    userId,
    trialReference(userId),
    credits,
  );

  const row = await trials.insert({
    user_id: userId,
    platform,
    gate: attestor.gate,
    credits,
  });
  if (!row) {
    // A concurrent request for this same user won. Both were the one keyed
    // grant, so the user was paid once; there is nothing to undo.
    deps.log("trial_already_claimed", {
      user_id: userId,
      platform,
      gate: attestor.gate,
      via: "insert_conflict",
    });
    return json(200, { granted: false, reason: "already_claimed", credits });
  }

  // Last, and deliberately: the bit is what makes the device ineligible for
  // ever (req 11.3), so setting it before the credits landed would burn a
  // device's only claim on a request that then failed. A failure here costs
  // the operator one extra trial instead, which is the cheaper mistake — so
  // it is logged rather than thrown (design: "iOS: DeviceCheck").
  try {
    await verdict.claim();
  } catch (error) {
    deps.log("trial_claim_failed", {
      user_id: userId,
      platform,
      gate: attestor.gate,
      message: String(error),
    });
  }

  // 10.1's log shape, for the same reason a block grant has one.
  deps.log("trial_granted", {
    user_id: userId,
    platform,
    gate: attestor.gate,
    credits,
    granted_at: row.granted_at,
  });

  return json(200, { granted: true, credits, balance: balanceAfter });
}

/**
 * Turns an attestation failure into the client's answer.
 *
 * The split is what the client does next. A rejection is Apple or Google
 * reading the payload and saying no, and the same token will never pass, so
 * the client must stop; anything else is an answer nobody could give, and
 * requirement 11.9 says to refuse without granting and let the client retry.
 * The trial stays unclaimed in both cases.
 */
function refuse(
  deps: Deps,
  userId: string,
  platform: TrialPlatform,
  error: unknown,
): Response {
  const rejected = error instanceof AttestationError &&
    error.failure === "rejected";
  if (!rejected && !(error instanceof AttestationError) && !(error instanceof ProviderError)) {
    throw error;
  }
  deps.log("trial_refused", {
    user_id: userId,
    platform,
    outcome: rejected ? "rejected" : "indeterminate",
    message: String(error),
  });
  return rejected
    ? json(400, { error: "invalid_attestation" })
    : json(503, { error: "attestation_unavailable" });
}
