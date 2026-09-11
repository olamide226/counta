import { assertEquals } from "@std/assert";
import {
  androidAttestor,
  call,
  DEVICE_TOKEN,
  FakeAttestor,
  harness,
  INTEGRITY_TOKEN,
  MemoryTrialStore,
  OTHER_USER,
  tokenFor,
  trialReq,
  USER,
} from "./testing/fakes.ts";
import { AttestationError, ProviderError, TrialPlatform } from "./types.ts";

// POST /voice-block/trial — requirement 11, end to end through the handler
// with the attestation faked. Nothing here reaches Apple or Google.

const ANDROID = { platform: "android", integrity_token: INTEGRITY_TOKEN };

const TIMED_OUT = Symbol("timed out");

/** Resolves to TIMED_OUT rather than hanging the suite on a regression. */
function within<T>(ms: number, work: Promise<T>): Promise<T | typeof TIMED_OUT> {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<typeof TIMED_OUT>((resolve) => {
    timer = setTimeout(() => resolve(TIMED_OUT), ms);
  });
  return Promise.race([work, timeout]).finally(() => clearTimeout(timer));
}

Deno.test("trial: grants once, then reports the existing outcome", async () => {
  const h = harness();

  const first = await call(h.deps, trialReq());
  assertEquals(first.status, 200);
  assertEquals(first.body, { granted: true, credits: 20, balance: 40 });
  assertEquals(h.trials.rows.length, 1);
  assertEquals(h.trials.rows[0].gate, "devicecheck");
  assertEquals(h.trials.rows[0].platform, "ios");
  // The bit is set, so the *device* is ineligible from now on (req 11.3).
  // Settled first: it is written after the response, not during it.
  await h.settle();
  assertEquals(h.ios.claimed.has(DEVICE_TOKEN), true);
  const granted = h.logs.find((l) => l.event === "trial_granted");
  assertEquals(granted?.fields.user_id, USER);
  assertEquals(granted?.fields.credits, 20);

  // 11.8: the retry is answered from the grant row without spending an
  // attestation call, and pays nothing. One shape for every already-claimed
  // answer, so the client's parse does not depend on which branch fired; the
  // distinction an operator wants is in the log's `via`.
  const second = await call(h.deps, trialReq());
  assertEquals(second.status, 200);
  assertEquals(second.body, { granted: false, reason: "already_claimed" });
  assertEquals(
    h.logs.find((l) => l.event === "trial_already_claimed")?.fields.via,
    "grant_row",
  );
  assertEquals(h.balance.balances.get(USER), 40);
  assertEquals(h.balance.calls.filter((c) => c.op === "grant").length, 1);
  assertEquals(h.ios.checks.length, 1);
});

Deno.test("trial: a device whose DeviceCheck bit is set is refused, whoever asks", async () => {
  const h = harness();
  // The same phone, reinstalled: a brand new anonymous Supabase user, and a
  // bit Apple has been holding since the first install (req 11.2).
  h.ios.claimed.add(DEVICE_TOKEN);

  const { status, body } = await call(
    h.deps,
    trialReq(undefined, tokenFor(OTHER_USER)),
  );

  assertEquals(status, 200);
  assertEquals(body, { granted: false, reason: "already_claimed" });
  assertEquals(h.trials.rows.length, 0);
  assertEquals(h.balance.calls.length, 0);
});

interface Refusal {
  name: string;
  platform: TrialPlatform;
  failWith: Error;
  status: number;
  body: Record<string, unknown>;
  /** The event that must appear, and its outcome field when it has one. */
  event: string;
  outcome?: string;
}

// Every way an attestation can fail to clear, and what the client is told.
// Four near-identical tests before this: the only thing that varied was the
// error going in and the answer coming out, which is a table.
const REFUSALS: Refusal[] = [
  {
    // 11.9: Google could not evaluate the verdict. Reading that as "no" would
    // deny a real device for ever, so it is refused and left retryable.
    name: "an unevaluated verdict",
    platform: "ios",
    failWith: new AttestationError(
      "indeterminate",
      "appRecognitionVerdict UNEVALUATED",
    ),
    status: 503,
    body: { error: "attestation_unavailable" },
    event: "trial_refused",
    outcome: "indeterminate",
  },
  {
    // Not attestation_unavailable: an upstream nobody could reach is the
    // router's 503, the same one RevenueCat and Deepgram get. One condition,
    // one vocabulary.
    name: "a provider nobody could reach",
    platform: "ios",
    failWith: new ProviderError("unavailable", "devicecheck: connection reset"),
    status: 503,
    body: { error: "provider_unavailable" },
    event: "provider_unavailable",
  },
  {
    // Apple read the payload and said no. The same token will never pass, so
    // the client must stop rather than retry a 503 for ever.
    name: "a payload the provider rejects",
    platform: "ios",
    failWith: new AttestationError(
      "rejected",
      "devicecheck 400: Bad Device Token",
    ),
    status: 400,
    body: { error: "invalid_attestation" },
    event: "trial_refused",
    outcome: "rejected",
  },
  {
    name: "an Android verdict that is not genuine",
    platform: "android",
    failWith: new AttestationError("rejected", "playintegrity: device []"),
    status: 400,
    body: { error: "invalid_attestation" },
    event: "trial_refused",
    outcome: "rejected",
  },
];

Deno.test("trial: every refusal grants nothing and says whether to retry", async () => {
  for (const refusal of REFUSALS) {
    const ios = refusal.platform === "ios";
    const attestor = ios
      ? new FakeAttestor("devicecheck", { failWith: refusal.failWith })
      : androidAttestor({ failWith: refusal.failWith });
    const h = harness({
      attestors: ios ? { ios: attestor } : { android: attestor },
    });

    const { status, body } = await call(
      h.deps,
      trialReq(ios ? undefined : ANDROID),
    );

    assertEquals(status, refusal.status, refusal.name);
    assertEquals(body, refusal.body, refusal.name);
    // Nothing was granted, recorded or claimed by any of them.
    assertEquals(h.trials.rows.length, 0, refusal.name);
    assertEquals(h.balance.calls.length, 0, refusal.name);
    assertEquals(attestor.claims, [], refusal.name);

    const logged = h.logs.find((l) => l.event === refusal.event);
    assertEquals(logged?.event, refusal.event, refusal.name);
    if (refusal.outcome !== undefined) {
      assertEquals(logged?.fields.outcome, refusal.outcome, refusal.name);
    }
  }
});

Deno.test("trial: Android grants on a genuine verdict and records only the row", async () => {
  const h = harness();

  const { status, body } = await call(h.deps, trialReq(ANDROID));

  assertEquals(status, 200);
  assertEquals(body, { granted: true, credits: 20, balance: 40 });
  assertEquals(h.trials.rows[0].gate, "play_integrity");
  assertEquals(h.trials.rows[0].platform, "android");
  // Play Integrity has nowhere to write a claim, so the row is the whole
  // record and the gate is weaker than the iOS one by construction (11.6).
  await h.settle();
  assertEquals(h.android.claims, [INTEGRITY_TOKEN]);
  assertEquals(h.android.claimed.size, 0);
});

Deno.test("trial: a platform with no attestation is not offered the trial", async () => {
  const h = harness();

  // 11.10: macOS, Windows, Linux and web have nothing to attest with.
  for (const platform of ["macos", "web", undefined]) {
    const res = await call(h.deps, trialReq({ platform, device_token: DEVICE_TOKEN }));
    assertEquals(res.status, 409, `platform=${platform}`);
    assertEquals(res.body, { error: "platform_unsupported" });
  }

  // And an operator who has configured no DeviceCheck key lands in the same
  // place: the trial is off on iOS rather than failing on every call.
  const unconfigured = harness({ attestors: {} });
  const res = await call(unconfigured.deps, trialReq());
  assertEquals(res.status, 409);
  assertEquals(res.body, { error: "platform_unsupported" });
  assertEquals(unconfigured.balance.calls.length, 0);
});

Deno.test("trial: a missing attestation payload is 400 before any provider call", async () => {
  const h = harness();

  for (const body of [{ platform: "ios" }, { platform: "ios", device_token: "" }]) {
    const res = await call(h.deps, trialReq(body));
    assertEquals(res.status, 400);
    assertEquals(res.body, { error: "invalid_attestation" });
  }
  // The android field is not interchangeable with the ios one.
  const wrongField = await call(
    h.deps,
    trialReq({ platform: "ios", integrity_token: INTEGRITY_TOKEN }),
  );
  assertEquals(wrongField.status, 400);

  assertEquals(h.ios.checks.length, 0);
  assertEquals(h.balance.calls.length, 0);
});

Deno.test("trial: unauthenticated is 401 and touches nothing", async () => {
  const h = harness();
  const anon = await call(h.deps, trialReq(undefined, null));
  assertEquals(anon.status, 401);
  assertEquals(anon.body, { error: "unauthenticated" });
  assertEquals(h.ios.checks.length, 0);
  assertEquals(h.balance.calls.length, 0);
});

Deno.test("trial: a ledger failure leaves a retry able to finish it, paying once", async () => {
  const h = harness();
  h.balance.failGrants = 1;

  const failed = await call(h.deps, trialReq());
  assertEquals(failed.status, 503);
  assertEquals(failed.body, { error: "provider_unavailable" });
  // Nothing downstream of the payout ran, so the device's claim is intact and
  // the retry walks the whole path again rather than being told it is done.
  assertEquals(h.trials.rows.length, 0);
  assertEquals(h.ios.claimed.size, 0);

  const retried = await call(h.deps, trialReq());
  assertEquals(retried.status, 200);
  assertEquals(retried.body, { granted: true, credits: 20, balance: 40 });

  // A third attempt is answered from the row and pays nothing.
  assertEquals((await call(h.deps, trialReq())).body, {
    granted: false,
    reason: "already_claimed",
  });
  assertEquals(h.balance.balances.get(USER), 40);
});

Deno.test("trial: a failed bit write still grants, and says so in the logs", async () => {
  const ios = new FakeAttestor("devicecheck", { failClaims: 1 });
  const h = harness({ attestors: { ios } });

  const { status, body } = await call(h.deps, trialReq());

  // Losing the bit costs the operator one extra trial; refusing the grant the
  // user has already been charged nothing for would cost them the feature.
  assertEquals(status, 200);
  assertEquals(body, { granted: true, credits: 20, balance: 40 });
  assertEquals(h.trials.rows.length, 1);
  await h.settle();
  assertEquals(ios.claimed.size, 0);
  assertEquals(h.logs.some((l) => l.event === "trial_claim_failed"), true);
});

Deno.test("trial: the DeviceCheck bit is written after the response, not during it", async () => {
  // The bit write is non-fatal by design — losing it costs the operator one
  // extra trial — so there was never a reason for every successful iOS trial
  // to wait on an Apple round trip. This attestor's claim() does not settle
  // until it is released, so a handler that awaited it would never answer.
  const ios = new FakeAttestor("devicecheck", { hold: true });
  const h = harness({ attestors: { ios } });

  const answered = await within(1000, call(h.deps, trialReq()));
  if (answered === TIMED_OUT) {
    throw new Error("the response waited on the DeviceCheck bit write");
  }

  assertEquals(answered.status, 200);
  assertEquals(answered.body, { granted: true, credits: 20, balance: 40 });
  // Started before the response, as the ordering requires: the credits and
  // the grant row are both already written by the time it is called.
  assertEquals(ios.claims, [DEVICE_TOKEN]);
  // But not finished, and the caller did not wait for it.
  assertEquals(ios.claimed.size, 0);
  assertEquals(h.trials.rows.length, 1);

  ios.releaseClaims();
  await h.settle();
  assertEquals(ios.claimed.has(DEVICE_TOKEN), true);
});

Deno.test("trial: a grant row written by a concurrent request pays out once", async () => {
  const h = harness();

  const [a, b] = await Promise.all([
    call(h.deps, trialReq()),
    call(h.deps, trialReq()),
  ]);

  assertEquals([a.status, b.status], [200, 200]);
  assertEquals([a.body.granted, b.body.granted].sort(), [false, true]);
  // Whichever lost was told so through the insert-conflict exit, in the same
  // shape the other two use.
  assertEquals(
    h.logs.find((l) => l.event === "trial_already_claimed")?.fields.via,
    "insert_conflict",
  );
  assertEquals(h.trials.rows.length, 1);
  // Both requests issued the same keyed grant, so the ledger applied it once.
  assertEquals(h.balance.balances.get(USER), 40);
});

Deno.test("trial: a store failure is a 500, not a silent grant", async () => {
  const trials = new MemoryTrialStore(new Error("counta.trial_grants insert: boom"));
  const h = harness({ trials });

  const { status, body } = await call(h.deps, trialReq());

  assertEquals(status, 500);
  assertEquals(body, { error: "internal" });
  assertEquals(trials.rows.length, 0);
});
