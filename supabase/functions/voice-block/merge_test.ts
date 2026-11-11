import { assertEquals } from "@std/assert";
import { mergeReference } from "./merge.ts";
import {
  call,
  harness,
  mergeReq,
  OTHER_USER,
  SESSION,
  tokenFor,
  USER,
} from "./testing/fakes.ts";

// POST /voice-block/merge — a guest's minutes into the signed-in account.
// USER is the account (GOOD_TOKEN); OTHER_USER is the guest, proved by its own
// token in the body.

const GUEST = OTHER_USER;
const guestBody = { guest_token: tokenFor(GUEST) };

/** A harness where GUEST is an anonymous user holding `guest` minutes. */
function setup(account = 10, guest = 7) {
  const h = harness();
  h.accounts.guests.add(GUEST);
  h.balance.balances.set(USER, account);
  h.balance.balances.set(GUEST, guest);
  return h;
}

Deno.test("merge: moves every guest minute into the account", async () => {
  const h = setup(10, 7);

  const res = await call(h.deps, mergeReq(guestBody));

  assertEquals(res.status, 200);
  assertEquals(res.body, { moved: 7, balance: 17 });
  assertEquals(h.balance.balances.get(USER), 17);
  assertEquals(h.balance.balances.get(GUEST), 0);
  // Grant before spend, both keyed on the guest.
  const moves = h.balance.calls.filter((c) => c.op !== "get");
  assertEquals(moves, [
    { op: "grant", userId: USER, blockId: mergeReference(GUEST), credits: 7 },
    { op: "spend", userId: GUEST, blockId: mergeReference(GUEST), credits: 7 },
  ]);
  const logged = h.logs.find((l) => l.event === "minutes_merged");
  assertEquals(logged?.fields, { user_id: USER, guest_id: GUEST, moved: 7 });
});

Deno.test("merge: a missing or blank guest_token is 400 invalid_request", async () => {
  const h = setup();
  for (
    const body of [{}, { guest_token: "" }, { guest_token: "  " }, {
      guest_token: 5,
    }]
  ) {
    const res = await call(h.deps, mergeReq(body));
    assertEquals(res.status, 400);
    assertEquals(res.body, { error: "invalid_request" });
  }
  assertEquals(h.balance.calls, []);
});

Deno.test("merge: a guest token that does not verify is 400 invalid_guest", async () => {
  const h = setup();
  const res = await call(h.deps, mergeReq({ guest_token: "junk" }));
  assertEquals(res.status, 400);
  assertEquals(res.body, { error: "invalid_guest" });
  assertEquals(h.balance.calls, []);
});

Deno.test("merge: needs a signed-in account", async () => {
  const h = setup();
  const res = await call(h.deps, mergeReq(guestBody, null));
  assertEquals(res.status, 401);
});

Deno.test("merge: merging into yourself moves nothing", async () => {
  const h = setup(10, 7);
  h.accounts.guests.add(USER);

  const res = await call(h.deps, mergeReq({ guest_token: tokenFor(USER) }));

  assertEquals(res.status, 200);
  assertEquals(res.body, { moved: 0, balance: 10 });
  assertEquals(h.balance.calls.filter((c) => c.op !== "get"), []);
});

Deno.test("merge: never moves minutes out of a real account", async () => {
  const h = setup(10, 7);
  h.accounts.guests.delete(GUEST);

  const res = await call(h.deps, mergeReq(guestBody));

  assertEquals(res.status, 403);
  assertEquals(res.body, { error: "not_a_guest" });
  assertEquals(h.balance.balances.get(GUEST), 7);
  assertEquals(h.balance.calls, []);
});

Deno.test("merge: a guest with a live block is 409 guest_busy", async () => {
  const h = setup(10, 7);
  await h.blocks.insert({
    id: "33333333-3333-4333-8333-999999999999",
    user_id: GUEST,
    session_id: SESSION,
    credits: 5,
    granted_at: h.clock.now.toISOString(),
    expires_at: new Date(h.clock.now.getTime() + 300_000).toISOString(),
  });

  const res = await call(h.deps, mergeReq(guestBody));

  assertEquals(res.status, 409);
  assertEquals(res.body, { error: "guest_busy" });
  assertEquals(h.balance.calls, []);
});

Deno.test("merge: an empty guest moves nothing and reports the account", async () => {
  const h = setup(10, 0);

  const res = await call(h.deps, mergeReq(guestBody));

  assertEquals(res.status, 200);
  assertEquals(res.body, { moved: 0, balance: 10 });
  assertEquals(h.balance.calls.filter((c) => c.op !== "get"), []);
});

Deno.test("merge: a spend that failed after the grant finishes on retry, once", async () => {
  const h = setup(10, 7);
  h.balance.failSpends = 1;

  const first = await call(h.deps, mergeReq(guestBody));
  assertEquals(first.status, 503);
  // The account was credited, the guest not yet emptied.
  assertEquals(h.balance.balances.get(USER), 17);
  assertEquals(h.balance.balances.get(GUEST), 7);

  const retry = await call(h.deps, mergeReq(guestBody));
  assertEquals(retry.status, 200);
  assertEquals(retry.body, { moved: 7, balance: 17 });
  // Exactly seven moved: the grant replayed under its key, the spend landed.
  assertEquals(h.balance.balances.get(USER), 17);
  assertEquals(h.balance.balances.get(GUEST), 0);

  // And a third ask, after it all went through, reads an empty guest.
  const again = await call(h.deps, mergeReq(guestBody));
  assertEquals(again.body, { moved: 0, balance: 17 });
});

Deno.test("merge: a grant that failed moves nothing and is retryable", async () => {
  const h = setup(10, 7);
  h.balance.failGrants = 1;

  const first = await call(h.deps, mergeReq(guestBody));
  assertEquals(first.status, 503);
  assertEquals(first.body, { error: "provider_unavailable" });
  assertEquals(h.balance.balances.get(USER), 10);
  assertEquals(h.balance.balances.get(GUEST), 7);
  assertEquals(h.balance.calls.some((c) => c.op === "spend"), false);

  const retry = await call(h.deps, mergeReq(guestBody));
  assertEquals(retry.body, { moved: 7, balance: 17 });
  assertEquals(h.balance.balances.get(GUEST), 0);
});
