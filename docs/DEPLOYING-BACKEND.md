# Deploying the voice backend

How to deploy and update the `voice-block` Edge Function and its `counta`
database schema on a Supabase project. Written for the second deploy and every
one after it, not just the first.

For what the function does and why, see `supabase/README.md` and the design
doc. App releases are covered separately in `docs/RELEASING.md`.

## What gets deployed, and what changes when

| Piece | Lives in | Changes when | Deployed by |
|---|---|---|---|
| Schema | `supabase/migrations/*.sql` | You add a migration | `make supabase-deploy` |
| Function code | `supabase/functions/voice-block/` | Any change under that folder | `make supabase-deploy` |
| Secrets | `supabase/remote.env` (never committed) | A key rotates, or a setting changes | `make supabase-secrets` |
| Auth and API settings | Supabase dashboard | Once per project | By hand, see below |
| App config | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` at build time | You point the app at a different project | Build flags |

The Makefile targets never name a project. They act on whichever one
`supabase link` recorded in `supabase/.temp/`, which is gitignored.

## Routine update

Most deploys are this, and nothing else:

```bash
make supabase-status     # what the linked project has now (read-only)
make supabase-deploy     # preflight, migrations, function, smoke test
```

`make supabase-deploy` runs, in order:

1. **`supabase-test`**: the Deno suite.
2. **Bundle check**: fails if anything under `voice-block/testing/` is
   reachable from `index.ts`. Those doubles include an attestor that approves
   every device and a balance that never runs out, so this is the check that
   keeps a free-credit dispenser out of production.
3. **`supabase db push`**: applies migrations the project hasn't seen. It
   lists them and **waits for you to confirm**. That prompt is intentional: on a
   shared project it is the last look before a schema change lands.
4. **`supabase functions deploy voice-block`**: replaces the running version.
5. **`supabase-smoke`**: see "Verifying a deploy" below.

It is safe to re-run. Applied migrations are skipped, and deploying unchanged
code just publishes the same bundle again.

## Verifying a deploy

`make supabase-smoke` sends an anonymous request and reads the status code.
Each code means one thing:

| Answer | Meaning |
|---|---|
| **401** | Healthy. The function is deployed, `verify_jwt=false` took effect, and every required secret is present. |
| **500** `misconfigured` | Deployed, but a required secret is missing. Building dependencies fails before authentication runs, so *every* request answers this until it is fixed. The function logs `boot_failed` with the missing name. |
| **404** | Not deployed on this project. |

A 401 is the right answer for an anonymous call: the function refuses to
serve anyone without a user token, and it does that itself rather than at the
gateway.

**A 401 does not prove the keys work.** It shows the secrets are *present*,
not that Deepgram and RevenueCat accept them: neither is called until a signed-in
user asks for a block. The first deploy to a real project answered 401 here and
then failed on both. After setting or changing secrets, run one real request
(see "Checking the keys end to end" below).

For anything more, the function logs are in the dashboard under **Edge
Functions → voice-block → Logs**. Every line is one JSON object with an `event`
field (`grant`, `boot_failed`, `trial_refused` and so on), so filter on that.

## Secrets

The function reads its configuration from project secrets. The full list, with
defaults, is in `supabase/.env.example` and the README's environment table.
Three are required, and without any one of them nothing works:
`DEEPGRAM_API_KEY`, `REVENUECAT_SECRET_KEY` and `REVENUECAT_PROJECT_ID`.

```bash
cp supabase/.env.example supabase/remote.env   # once; fill in real values
make supabase-secrets
```

Remote secrets use their own file on purpose. `supabase/.env` is what
`make supabase-serve` uses locally, and pushing it by mistake would put local
values on a live project. `make supabase-secrets` refuses to run if the file is
tracked by git.

**The Deepgram key must have the Member role.** The function never streams
with it; it only asks Deepgram for a 30-second temporary token, and that call
needs Member or higher. A key that streams perfectly well in a debug build can
still be refused here, so do not reuse the app's dev key: create a separate one
for the server. Reusing it also means revoking one breaks the other.

**The RevenueCat key needs Customer information: Read & write**, and nothing
else. That covers reading a balance, moving credits and creating a customer.

**Secrets are project-wide.** On a project other products share, every
function deployed there can read them. Put only what `voice-block` needs in
`remote.env`.

**Adding a secret takes effect immediately. Changing one might not.** Supabase
delivers secrets without a redeploy. But a worker that booted successfully
caches everything it built from them (`index.ts`, `cachedDeps`), so a warm
worker keeps an old value until it is recycled. After **rotating** a key,
redeploy to force fresh workers:

```bash
supabase functions deploy voice-block --project-ref <ref>
```

A *missing* secret doesn't have this problem, because a failed boot is never
cached. Setting it is enough.

## Changing the schema

- **Add a new migration; never edit an applied one.** A migration that has
  already run on a project won't run again there, so editing it changes nothing
  remotely and makes local and remote disagree about what the file means.
  Create a new file: `supabase migration new <what_it_does>`.
- **Stay inside `counta`.** Every object the migrations create or change is in
  the `counta` schema. The only references outside it are foreign keys to
  `auth.users` and RLS calls to `auth.uid()` / `auth.role()`. Keep it that way,
  because other products' schemas live beside it.
- **Make it re-runnable.** Use `if not exists` / `if exists` so a migration
  that failed halfway can be applied again.
- **There is no rollback.** Supabase migrations only go forward. Undo a change
  with another migration that reverses it.

Check which migrations the project has applied with `make supabase-status`.
The `remote` column is empty for any that haven't run.

## Rolling back function code

Function versions aren't kept for you to switch back to. To roll back, check
out the last good commit and deploy it:

```bash
git checkout <good-commit> -- supabase/functions
make supabase-deploy
git checkout HEAD -- supabase/functions    # back to where you were
```

Schema changes don't roll back this way. If the bad deploy included a
migration, reverse it with a new one.

## First deploy to a new project

Do these once per project, in order.

1. **Link the CLI**: `supabase link --project-ref <ref>`.
2. **Dashboard: enable anonymous sign-ins.** *Authentication → Sign In /
   Providers → Anonymous sign-ins.* The app signs every user in anonymously.
   Without this, every request arrives with no user and gets a 401.
3. **Dashboard: expose the `counta` schema.** *Project Settings → Data API →
   Exposed schemas*, add `counta`. Without it the function's queries fail with
   `PGRST106`, which shows up as a 500 that has nothing to do with credits.
4. **Secrets**: fill in `supabase/remote.env`, then `make supabase-secrets`.
5. **Deploy**: `make supabase-deploy`. The smoke test should answer 401.
6. **Deepgram hard spend limit.** Set it in the Deepgram console. Once a client
   holds an open socket, nothing in this code can cap what it costs.
7. **Point the app at it**: pass `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`
   to the build (see below).

### Never run `supabase config push` on a shared project

It pushes the local `config.toml` over the **whole project's** auth settings:
site URL, JWT expiry, sign-up and anonymous rules. Other products depend on
those. Steps 2 and 3 above are what this feature needs from that config, which
is why they are done by hand.

## Pointing the app at the backend

The app reads `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` at build time. The
publishable key isn't a secret: it ships in every build. What it grants is
limited by RLS and by the function's own checks.

- **Debug builds** read them from the repo `.env` (`make run`, `make run-ios`,
  `make run-android`).
- **Release builds** (`make build-ios-ipa`, `make build-appbundle`,
  `make build-android`) read them from the environment and never from `.env`,
  so the dev Deepgram key can't be bundled into a published artifact:

  ```bash
  SUPABASE_URL=https://<ref>.supabase.co \
  SUPABASE_PUBLISHABLE_KEY=sb_publishable_... \
  make build-ios-ipa
  ```

**A build has exactly one credential source.** When `SUPABASE_URL` is set,
the app buys blocks from the function and does **not** fall back to
`DEEPGRAM_API_KEY`, even in a debug build. That's on purpose: falling back
would be a way to stream without paying. The consequence is that setting these
two keys in `.env` makes debug voice depend on the backend being fully working.
Leave them out of `.env` to test voice on the dev key.

A release build with neither key can't do voice at all. It shows *"Voice
counting needs a block token from the voice-block service…"*. That message
means "this build has no backend configured", not that the backend is down.

## Credits for testing

Every block costs credits, and credits live in RevenueCat, so a tester with a
zero balance gets `402 insufficient_credit`. There is no free mode, on purpose:
a flag that turns the function into a credit dispenser is one typo away from
production, and the endpoint is reachable by anyone holding the publishable
key.

To test before purchases exist, grant a tester credits by hand:

1. **Find their user id.** Have them open the app once, which signs them in
   anonymously, then in the SQL editor:

   ```sql
   select id, created_at from auth.users
    where is_anonymous order by created_at desc limit 5;
   ```

   On a shared project other products' anonymous users can appear here too.
   Match on the time they opened the app.

2. **Create them in RevenueCat, then grant credits.** The customer id is the
   Supabase user id. RevenueCat refuses a transaction for a customer it has
   never seen (`404 Customer could not be found`), and until the app carries
   the RevenueCat SDK nothing else creates them, so create first. Creating one
   that already exists answers 409, which is fine.

   ```bash
   curl -X POST \
     "https://api.revenuecat.com/v2/projects/$REVENUECAT_PROJECT_ID/customers" \
     -H "Authorization: Bearer $REVENUECAT_SECRET_KEY" \
     -H "Content-Type: application/json" \
     -d '{"id": "<user-id>"}'

   curl -X POST \
     "https://api.revenuecat.com/v2/projects/$REVENUECAT_PROJECT_ID/customers/<user-id>/virtual_currencies/transactions" \
     -H "Authorization: Bearer $REVENUECAT_SECRET_KEY" \
     -H "Content-Type: application/json" \
     -H "Idempotency-Key: tester-grant-<user-id>-1" \
     -d '{"adjustments": {"VOICE": 100}, "reference": "manual test grant"}'
   ```

   100 credits is 20 blocks, or 100 minutes of voice. The `Idempotency-Key`
   makes a retried command grant once. Change the suffix for a second grant.

Both requests were run against a live project on 2 Oct 2026: create answers
201, the grant answers 200 with the new balance.

### Checking the keys end to end

With a user who has credits, ask for a block the way the app does. A `200` with
a `token` means every key works. Releasing it straight away, unused, refunds
the credits:

| Answer to the block request | Meaning |
|---|---|
| `200` with `token` | Everything works |
| `402 insufficient_credit` | Keys fine; this user has no credits |
| `503 provider_unavailable`, balance unchanged | Deepgram refused the mint, and the debit was refunded. Almost always a key without the Member role |
| `503 provider_unavailable`, before any debit | RevenueCat refused the balance read: wrong key, wrong permission or wrong project id |

`boot_failed`, `mint_failed` and the provider's status are in the function
logs.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Deploy fails: `Relative import path "@supabase/supabase-js" not prefixed` | The bundler didn't find an import map. It reads `deno.json` from the function's own folder, not the one above it. | `voice-block/deno.json` must hold the `imports`. The folder above is a workspace root for local tooling only. |
| Every request: 500 `misconfigured` | A required secret is missing | `boot_failed` in the logs names it; `make supabase-secrets` |
| Every request: 401 even with a user | Anonymous sign-ins are off, or the token is for another project | First deploy, step 2 |
| 500 mentioning `PGRST106` / "schema must be one of" | `counta` isn't an exposed schema | First deploy, step 3 |
| 402 `insufficient_credit` | The user has no credits | "Credits for testing" |
| 503 `provider_unavailable` on a block, balance unchanged | Deepgram refused to mint a token: the key lacks the Member role | New Deepgram key with role Member, `make supabase-secrets`, redeploy |
| Hand-grant answers 404 `Customer could not be found` | RevenueCat has never seen this user | Create the customer first; see "Credits for testing" |
| App: "needs a block token from the voice-block service" | The build has no `SUPABASE_URL` | "Pointing the app at the backend" |
| Rotated a key, still seeing the old behaviour | A warm worker cached the old value | Redeploy the function |
