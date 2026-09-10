import { assertEquals } from "@std/assert";
import { handleVoiceBlock } from "./handler.ts";
import {
  androidAttestor,
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
import { AttestationError, Deps, ProviderError } from "./types.ts";

// POST /voice-block/trial — requirement 11, end to end through the handler
// with the attestation faked. Nothing here reaches Apple or Google.

async function call(deps: Deps, req: Request) {
  const res = await handleVoiceBlock(req, deps);
  return { status: res.status, body: await res.json() };
}

const ANDROID = { platform: "android", integrity_token: INTEGRITY_TOKEN };

Deno.test("trial: grants once, then reports the existing outcome", async () => {
  const h = harness();

  const first = await call(h.deps, trialReq());
  assertEquals(first.status, 200);
  assertEquals(first.body, { granted: true, credits: 20, balance: 40 });
  assertEquals(h.trials.rows.length, 1);
  assertEquals(h.trials.rows[0].gate, "devicecheck");
  assertEquals(h.trials.rows[0].platform, "ios");
  // The bit is set, so the *device* is ineligible from now on (req 11.3).
  assertEquals(h.ios.claimed.has(DEVICE_TOKEN), true);
  const granted = h.logs.find((l) => l.event === "trial_granted");
  assertEquals(granted?.fields.user_id, USER);
  assertEquals(granted?.fields.credits, 20);

  // 11.8: the retry is answered from the grant row without spending an
  // attestation call, and pays nothing.
  const second = await call(h.deps, trialReq());
  assertEquals(second.status, 200);
  assertEquals(second.body, {
    granted: false,
    reason: "already_claimed",
    credits: 20,
  });
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

Deno.test("trial: an indeterminate verdict refuses without granting", async () => {
  const ios = new FakeAttestor("devicecheck", {
    failWith: new AttestationError("indeterminate", "appRecognitionVerdict UNEVALUATED"),
  });
  const h = harness({ attestors: { ios } });

  const { status, body } = await call(h.deps, trialReq());

  // 11.9: refuse, grant nothing, and let the client try again — reading an
  // unevaluated verdict as "no" would deny a real device for ever.
  assertEquals(status, 503);
  assertEquals(body, { error: "attestation_unavailable" });
  assertEquals(h.trials.rows.length, 0);
  assertEquals(h.balance.calls.length, 0);
  assertEquals(ios.claims, []);
});

Deno.test("trial: an unreachable attestation provider refuses without granting", async () => {
  const ios = new FakeAttestor("devicecheck", {
    failWith: new ProviderError("unavailable", "devicecheck: connection reset"),
  });
  const h = harness({ attestors: { ios } });

  const { status, body } = await call(h.deps, trialReq());

  assertEquals(status, 503);
  assertEquals(body, { error: "attestation_unavailable" });
  assertEquals(h.trials.rows.length, 0);
  assertEquals(h.balance.calls.length, 0);
  const refused = h.logs.find((l) => l.event === "trial_refused");
  assertEquals(refused?.fields.outcome, "indeterminate");
});

Deno.test("trial: a payload the provider rejects is 400, not a retryable 503", async () => {
  const ios = new FakeAttestor("devicecheck", {
    failWith: new AttestationError("rejected", "devicecheck 400: Bad Device Token"),
  });
  const h = harness({ attestors: { ios } });

  const { status, body } = await call(h.deps, trialReq());

  assertEquals(status, 400);
  assertEquals(body, { error: "invalid_attestation" });
  assertEquals(h.trials.rows.length, 0);
  assertEquals(h.balance.calls.length, 0);
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
  assertEquals(h.android.claims, [INTEGRITY_TOKEN]);
  assertEquals(h.android.claimed.size, 0);
});

Deno.test("trial: Android refuses a verdict that is not genuine", async () => {
  const android = androidAttestor({
    failWith: new AttestationError("rejected", "playintegrity: device []"),
  });
  const h = harness({ attestors: { android } });

  const { status, body } = await call(h.deps, trialReq(ANDROID));

  assertEquals(status, 400);
  assertEquals(body, { error: "invalid_attestation" });
  assertEquals(h.trials.rows.length, 0);
  assertEquals(h.balance.calls.length, 0);
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
    credits: 20,
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
  assertEquals(ios.claimed.size, 0);
  assertEquals(h.logs.some((l) => l.event === "trial_claim_failed"), true);
});

Deno.test("trial: a grant row written by a concurrent request pays out once", async () => {
  const h = harness();

  const [a, b] = await Promise.all([
    call(h.deps, trialReq()),
    call(h.deps, trialReq()),
  ]);

  assertEquals([a.status, b.status], [200, 200]);
  assertEquals([a.body.granted, b.body.granted].sort(), [false, true]);
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
