import { assertEquals, assertRejects } from "@std/assert";
import {
  call,
  deleteAccountReq,
  harness,
  jsonResponse,
  revenueCat,
  throttled,
  USER,
} from "./testing/fakes.ts";
import { ProviderError } from "./types.ts";

// POST /voice-block/delete-account, and the RevenueCat call behind it.

Deno.test("delete-account: forgets the ledger, then removes the user", async () => {
  const h = harness();
  h.balance.balances.set(USER, 12);

  const res = await call(h.deps, deleteAccountReq());

  assertEquals(res.status, 200);
  assertEquals(res.body, { deleted: true });
  assertEquals(h.balance.calls, [{ op: "forget", userId: USER }]);
  assertEquals(h.balance.balances.get(USER), 0);
  assertEquals(h.accounts.removed, [USER]);
  assertEquals(
    h.logs.find((l) => l.event === "account_deleted")?.fields,
    { user_id: USER },
  );
});

Deno.test("delete-account: a ledger failure is 503 and leaves the user to retry", async () => {
  const h = harness();
  h.balance.failForgetWith = new ProviderError("unavailable", "down");

  const res = await call(h.deps, deleteAccountReq());

  assertEquals(res.status, 503);
  assertEquals(res.body, { error: "provider_unavailable" });
  // The user still exists, so the retry can be authenticated.
  assertEquals(h.accounts.removed, []);
});

Deno.test("delete-account: an Auth failure is 503 after the ledger is forgotten", async () => {
  const h = harness();
  h.accounts.failRemoveWith = new ProviderError("unavailable", "auth down");

  const res = await call(h.deps, deleteAccountReq());

  assertEquals(res.status, 503);
  assertEquals(h.balance.calls, [{ op: "forget", userId: USER }]);

  // The retry forgets an already-forgotten customer, which is success.
  h.accounts.failRemoveWith = undefined;
  const retry = await call(h.deps, deleteAccountReq());
  assertEquals(retry.status, 200);
  assertEquals(h.accounts.removed, [USER]);
});

Deno.test("delete-account: needs a signed-in user", async () => {
  const h = harness();
  const res = await call(h.deps, deleteAccountReq(null));
  assertEquals(res.status, 401);
  assertEquals(h.balance.calls, []);
  assertEquals(h.accounts.removed, []);
});

Deno.test("RevenueCat provider: forget deletes the customer", async () => {
  const { provider, sent } = revenueCat([
    jsonResponse({ object: "customer", id: USER, deleted_at: 1658399423658 }),
  ]);

  await provider.forget(USER);

  assertEquals(sent.length, 1);
  assertEquals(sent[0].init.method, "DELETE");
  assertEquals(
    sent[0].url,
    `https://api.revenuecat.com/v2/projects/proj/customers/${USER}`,
  );
});

Deno.test("RevenueCat provider: forgetting a customer it never had succeeds", async () => {
  const { provider } = revenueCat([
    () =>
      jsonResponse({
        object: "error",
        type: "resource_missing",
        message: "Customer not found",
        param: "customer_id",
      }, 404),
  ]);

  await provider.forget(USER);
});

Deno.test("RevenueCat provider: forget on a wrong project is a failure", async () => {
  const { provider } = revenueCat([
    () =>
      jsonResponse({
        object: "error",
        type: "resource_missing",
        message: "Project could not be found",
        param: "project_id",
      }, 404),
  ]);

  await assertRejects(() => provider.forget(USER), ProviderError);
});

Deno.test("RevenueCat provider: forget retries a 429", async () => {
  const { provider, sent } = revenueCat([
    throttled(),
    jsonResponse({ object: "customer", id: USER, deleted_at: 1 }),
  ]);

  await provider.forget(USER);
  assertEquals(sent.length, 2);
});
