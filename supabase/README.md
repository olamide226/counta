# Supabase backend for voice counting

One Edge Function (`voice-block`) and six tables — `counta.voice_blocks`,
`counta.trial_grants`, `counta.matcher_config`, `counta.vouchers`,
`counta.voucher_redemptions`, `counta.voucher_attempts` — in a dedicated
`counta` schema. See `specs/voice-phrase-counting/design.md` for the contract,
the reasoning behind blocks, and the device gate on the free trial.

> **The deploy target is a shared staging project.** It already hosts other
> products, each in its own Postgres schema (`mcpl`, `mcp_oauth`), and `public`
> belongs to an unrelated website. Two consequences:
>
> - **Never run `supabase config push` against it.** That command overwrites
>   the whole project's auth configuration — site URL, JWT expiry, signup and
>   anonymous rules — which the other products share. The settings this feature
>   needs are set by hand in the dashboard instead (see "Deploy to a project").
> - `supabase db push` is safe here **only because** the migrations are
>   additive and confined to `counta`. Together they create a schema, six
>   tables and one function, and touch nothing in `public`, `mcpl`,
>   `mcp_oauth` or `auth` beyond foreign keys to `auth.users`. Re-read them
>   before pushing any change.

## Layout

```
supabase/
  config.toml                       local stack config; anonymous sign-in on
  migrations/*_voice_blocks.sql     counta schema: tables, indexes, RLS, grants
  migrations/*_voucher_credited_at.sql  records that a redemption's payout landed
  migrations/*_redeem_voucher.sql   counta.redeem_voucher: one-transaction redemption
  tests/*.sql                       concurrency tests; local databases only
  functions/deno.json               pinned imports + `deno task test`
  functions/voice-block/
    index.ts                        entrypoint: env -> adapters -> handler
    attestors.ts                    which platforms get a trial gate, from env
    handler.ts                      router; the five POST routes share one JWT check
    token.ts                        POST /token   (re-mint for a block you hold)
    trial.ts                        POST /trial   (device-gated free trial)
    redeem.ts                       POST /redeem  (voucher codes)
    respond.ts                      json(), readJson() and isUuid(), shared by every route
    ratelimit.ts                    per-worker sliding window, used by /token
    types.ts                        ports: BalanceProvider, TokenMinter, BlockStore,
                                    DeviceAttestor, TrialStore, VoucherStore
    auth.ts                         JWT verification (local JWKS, getUser fallback)
    webcrypto.ts                    the ES256/RS256 table and base64url, shared by
                                    the verifying and the signing halves
    store.ts                        Supabase-backed stores (counta schema)
    providers/http.ts               shared fetch + failure classification
    providers/balance.ts            RevenueCatBalanceProvider
    providers/minter.ts             DeepgramTokenMinter
    providers/jwt.ts                ES256/RS256 assertion signing from a PKCS#8 PEM
    providers/devicecheck.ts        AppleDeviceCheckAttestor (iOS gate)
    providers/playintegrity.ts      PlayIntegrityAttestor (Android gate)
    testing/fakes.ts                test doubles; never imported by index.ts
    index_test.ts                   block routes and the upstream providers
    token_test.ts                   POST /token
    trial_test.ts                   requirement 11, attestation faked
    redeem_test.ts                  requirement 12
    attestation_test.ts             the two attestors' wire shape, fetch stubbed
    store_test.ts                   pins every query to the counta schema
    attestors_test.ts               a broken credential costs one platform only
  .env.example                      every secret and setting the function reads
```

## Run locally

Requires the Supabase CLI, Docker and Deno.

```bash
make supabase-test        # deno tests, nothing else needed
make supabase-start       # docker stack; applies supabase/migrations
cp supabase/.env.example supabase/.env   # fill in real credentials
make supabase-serve       # serves functions with supabase/.env
```

There is no fake-provider mode. The test doubles live in
`functions/voice-block/testing/fakes.ts`, are imported only by the `*_test.ts`
files, and are therefore absent from the deployed bundle — a provider that
hands out credits, or an attestor that says every device is eligible, must
never be one environment-variable typo away from production. Check it with
`deno info functions/voice-block/index.ts`: nothing under `testing/` may
appear. Every behaviour they used to exercise by hand is covered by
`make supabase-test`; serving the function locally needs real RevenueCat,
Deepgram and — for `/trial` — Apple or Google credentials.

Point the app at the local stack by putting the URL and anon key printed by
`supabase start` into the repo `.env` as `SUPABASE_URL` and
`SUPABASE_PUBLISHABLE_KEY`; `make run` forwards them as dart-defines.

Exercise the function by hand (get a user JWT from the app, or from
`supabase auth` in Studio):

```bash
curl -X POST http://127.0.0.1:54321/functions/v1/voice-block \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"session_id":"11111111-1111-4111-8111-111111111111"}'

curl -X POST http://127.0.0.1:54321/functions/v1/voice-block/release \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"block_id":"<from grant>","streamed_secs":12,"detections":0,"eligible_for_refund":true}'
```

```bash
# A fresh Deepgram token for a block you already hold, for a socket that
# dropped mid-block. Mints, never debits.
curl -X POST http://127.0.0.1:54321/functions/v1/voice-block/token \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"block_id":"<from grant>"}'
```

The 30-second token TTL governs opening a connection, not the life of one
already open, so a block outlives its token by design. `/token` is what lets a
socket that drops 200 seconds in come back: re-granting instead would read as
a renewal (the `session_id` matches) and debit a whole block per dropped
socket. Unknown, someone else's, already released and expired blocks all
answer `404 block_not_found` — a block that is not yours must not be
distinguishable from one that does not exist.

`streamed_secs` and `detections` must be non-negative integers when present
(anything else is a 400). A refund needs `detections` to be present and zero:
an omitted count is no report at all, not a report of zero.

```bash
# The one-per-device free trial. `platform` is ios or android and decides
# which attestation field is read; anything else is 409 platform_unsupported.
curl -X POST http://127.0.0.1:54321/functions/v1/voice-block/trial \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"platform":"ios","device_token":"<DCDevice.current.generateToken()>"}'
curl -X POST http://127.0.0.1:54321/functions/v1/voice-block/trial \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"platform":"android","integrity_token":"<Play Integrity token>"}'

curl -X POST http://127.0.0.1:54321/functions/v1/voice-block/redeem \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"code":"SPRING24"}'
```

A repeat redemption reports the original and moves no credit, so it carries no
`balance`: the field is echoed only when it changed, as a release reports a
refund. `counta.voucher_redemptions.credited_at` is what decides that — a
redemption whose payout is not yet confirmed is re-issued with the same keyed
grant, one that is confirmed pays nothing. Without it, "a voucher pays out
once" rested on RevenueCat retaining the idempotency key, which it does only
for a bounded window.

Both answer 200 with a negative result rather than an error when the question
has already been answered — `granted: false, reason: "already_claimed"` and
`redeemed: false, reason: "already_redeemed"`. Every reinstall asks the first
one and a user who taps Redeem twice asks the second, and in both cases the
client does what it would have done anyway: show the balance.

The full response table is in the design doc's "Edge Function contract". Two
things it is worth knowing before reading a log:

- The trial's 503s are two different failures. `attestation_unavailable` means
  Apple or Google could not be reached, answered `UNEVALUATED`, or rejected
  our own credentials — the trial stays unclaimed and the client may retry
  (req 11.9). `provider_unavailable` means the RevenueCat ledger call failed
  after the device passed; the retry re-issues the same keyed grant.
- `invalid_attestation` (400) is the provider reading the payload and saying
  no. The same token will never pass, so a client that retries it is wasting
  the request.

Neither endpoint is reachable without a JWT, and neither trusts anything the
client says about its own eligibility (req 4.8).

## Environment the function reads

Injected by the runtime (do not set): `SUPABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY`.

| Variable | Default | Purpose |
|---|---|---|
| `DEEPGRAM_API_KEY` | required | Master key used only to call `/v1/auth/grant` |
| `DEEPGRAM_TOKEN_TTL_SECONDS` | 30 | TTL of the temporary token (1..3600) |
| `REVENUECAT_SECRET_KEY` | required | Developer API v2 key, `customer_information:purchases:read_write` |
| `REVENUECAT_PROJECT_ID` | required | RevenueCat project id |
| `REVENUECAT_CURRENCY_CODE` | `VOICE` | Virtual currency code for voice credits |
| `BLOCK_CREDITS` | 5 | Credits debited per block |
| `BLOCK_SECONDS` | 300 | Block duration |
| `REFUND_WINDOW_SECONDS` | 30 | Release within this window with zero detections is refunded |
| `RATE_LIMIT_MAX` | 6 | Max grants per user per window |
| `RATE_LIMIT_WINDOW_MINUTES` | 10 | Rate-limit window |
| `TOKEN_MINT_MAX` | 20 | Max `/token` mints per user per window, counted in the worker's memory |
| `TOKEN_MINT_WINDOW_MINUTES` | 5 | Window for the above |

The trial and voucher settings:

| Variable | Default | Purpose |
|---|---|---|
| `TRIAL_CREDITS` | 20 | Credits granted by the one-per-device trial |
| `APPLE_TEAM_ID` | unset: no iOS trial | Apple developer team that owns the DeviceCheck bits |
| `APPLE_DEVICECHECK_KEY_ID` | unset: no iOS trial | Key id of a DeviceCheck-enabled key |
| `APPLE_DEVICECHECK_PRIVATE_KEY` | unset: no iOS trial | `.p8` contents for that key; downloadable exactly once |
| `APPLE_DEVICECHECK_HOST` | `api.devicecheck.apple.com` | Use `api.development.devicecheck.apple.com` for development-signed builds; the two hosts hold **separate** bit stores |
| `DEVICECHECK_TRIAL_BIT` | 0 | Which of the team's two bits means "took the Counta trial". The bits are per team, not per app — check the allocation table in the design doc before changing it |
| `PLAY_INTEGRITY_PACKAGE_NAME` | unset: no Android trial | Android application id the verdict must name |
| `PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON` | unset: no Android trial | The whole service account JSON, one line, with the Play Integrity API enabled |
| `VOUCHER_ATTEMPT_MAX` | 10 | Failed redemptions allowed per user per window |
| `VOUCHER_ATTEMPT_WINDOW_MINUTES` | 60 | Window for the above |

**The three Apple variables and the two Google ones are all-or-nothing per
platform.** With none of a platform's credentials set — or with a value that
cannot be used, such as a `PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON` that does not
parse or carries no `client_email`/`private_key` — that platform has no
attestor and `/trial` answers `409 platform_unsupported` for it — which is the
same answer macOS and web get, and is deliberate: an operator who has not set
DeviceCheck up yet should lose the trial, not the block endpoints that pay for
the whole feature. Watch for `trial_platform_unsupported` with
`platform: "ios"` in the logs; on a phone that is a misconfiguration, not a
desktop build asking a question it should not have asked. A credential that was
set but is unusable also logs `attestor_unavailable` once at startup, which is
the difference between "we turned this off" and "somebody pasted the secret
wrong".

Vouchers need no credentials at all — the codes live in `counta.vouchers`.

The RevenueCat customer id is the Supabase user id; the client must identify
the RevenueCat SDK with the same id (task 10.3).

## Deploy to a project

Nothing here talks to a remote project until you run these.

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push                                  # applies supabase/migrations
supabase secrets set --env-file supabase/.env     # or individual NAME=VALUE pairs
supabase functions deploy voice-block             # verify_jwt=false comes from config.toml
```

There is deliberately no `supabase config push` here. It would push this
local `config.toml` over the shared project's auth settings. Do these two
steps by hand in the dashboard instead — once per project, not per deploy:

1. **Authentication -> Sign In / Providers -> Anonymous sign-ins: enable.**
   The app signs in anonymously (`supabaseSessionProvider`), so without this
   every request arrives without a user and the function answers 401.
2. **Project Settings -> API (Data API) -> Exposed schemas: add `counta`.**
   PostgREST serves only the schemas on that list. Without it the function's
   queries fail with `PGRST106` / "schema must be one of the following", which
   surfaces as a 500 rather than as anything about credits.

Then set the project URL and publishable key in the app `.env` and rebuild.
Also configure a hard spend limit on the Deepgram project (req 10.4); no code
here can bound cost once a client holds an open socket.

## Operator setup for the trial and vouchers

### The Apple DeviceCheck key

1. **Developer account -> Membership details** for the team id. It is the
   10-character string, and it is what the assertion's `iss` claim carries.
2. **Certificates, Identifiers & Profiles -> Keys -> +**, tick **DeviceCheck**,
   and continue. The `.p8` **downloads exactly once**; there is no second
   chance and a lost key has to be revoked and replaced.
3. Set `APPLE_TEAM_ID`, `APPLE_DEVICECHECK_KEY_ID` (the key's 10-character id)
   and `APPLE_DEVICECHECK_PRIVATE_KEY` (the whole `.p8` text, `BEGIN` and
   `END` lines included — a literal `\n` between the lines is fine, the
   function accepts both).
4. Point development-signed builds at `api.development.devicecheck.apple.com`.
   Its bit store is **separate** from production's, which is what makes
   testing possible: a device that claimed the trial in development has not
   claimed it in production, and a production build pointed at the development
   host reports every device as unclaimed.
5. **Check the bit allocation table in
   `specs/voice-phrase-counting/design.md` before shipping.** The two bits
   belong to the Apple team, not to an app. Every app the team ships reads and
   writes the same two bits for a given device, so a sibling app that picks a
   bit at random will silently deny someone else's trial. Counta owns `bit0`;
   record any other claim in that table in the commit that starts using it.

### The Play Integrity service account

1. In the **Play Console**, under the app's **Release -> App integrity**, link
   the Google Cloud project and enable the Play Integrity API for it.
2. In **Google Cloud -> IAM -> Service accounts**, create one and download a
   JSON key. It needs no IAM role beyond access to the linked project's Play
   Integrity API.
3. Set `PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON` to the **whole JSON document** on
   one line and `PLAY_INTEGRITY_PACKAGE_NAME` to the application id. The
   function reads `client_email`, `private_key` and `private_key_id` out of
   it, mints an access token with the JWT-bearer grant and calls
   `decodeIntegrityToken`. Splitting the JSON into separate variables is what
   lets them drift apart, so it stays one secret.

A verdict is accepted only when it names this package, was minted within the
last ten minutes, and reports `PLAY_RECOGNIZED`, `MEETS_DEVICE_INTEGRITY` and
`LICENSED`. Anything Google marks `UNEVALUATED` is a 503, not a refusal.

### Creating a campaign code

There is no admin UI and no self-serve generation; a campaign is a few rows of
SQL run with the service role (req 12.10).

```sql
insert into counta.vouchers (code, credits, max_redemptions, expires_at, note)
values ('SPRING24', 50, 500, '2026-12-31T23:59:59Z', 'spring newsletter');

-- Retire it. Never delete: the redemption ledger references the row, and a
-- disabled code answers exactly as an unknown one does.
update counta.vouchers set enabled = false where upper(code) = 'SPRING24';

-- How a campaign is doing.
select code, redeemed_count, max_redemptions, expires_at, enabled
  from counta.vouchers order by created_at desc;
```

`expires_at` is nullable and null means never. Codes are matched and kept
unique on `upper(code)`, so `SPRING24` and `spring24` cannot coexist as two
campaigns and a user may type either.

Raising `max_redemptions` is also the remedy when a redemption's ledger call
fails permanently: the slot stays consumed, which is deliberate — releasing
slots automatically would give a retry loop something to chew on.

```sql
-- Redemptions whose payout never landed. The user's next tap on the same code
-- re-issues the grant; a row that stays here is one to chase.
select id, voucher_id, user_id, credits, redeemed_at
  from counta.voucher_redemptions
 where credited_at is null and redeemed_at < now() - interval '1 hour';
```

## Notes on the schema

- Everything is in the `counta` schema, not `public`, because the project is
  shared. The cloud default that auto-exposes new tables to the Data API roles
  applies to `public` only, so the migration grants explicitly: usage on the
  schema for `anon`, `authenticated` and `service_role`; `select` for
  `authenticated` on the two tables that have an RLS select policy; full DML
  for `service_role`. `trial_grants` and the three voucher tables get no client
  grant and no policy at all — for the vouchers because the codes themselves
  are the secret, and any select policy would let an anonymous session
  enumerate every live campaign.
- The design's partial index `where expires_at > now()` is not valid Postgres
  (`now()` is not immutable). A partial **unique** index on
  `(user_id) where not reconciled` takes its place: it serves the in-flight
  lookup and enforces one live block per user (req 3.8) even when two requests
  race past the function's own check.
- `counta.voice_blocks` and `counta.trial_grants` have no client write policy;
  all writes go through the service-role client inside the function.
- `counta.trial_grants` is keyed on the Supabase user id, which makes a retried
  trial grant idempotent. It is not the device gate: on iOS the durable "this
  device already took the trial" answer is a bit held by Apple's DeviceCheck
  service, and on Android there is no such storage at all, so the row is the
  only record and the gate is weaker. The migration comment and the design's
  "Trial eligibility and vouchers" section say why, and why a device
  fingerprint is not the answer.
- `counta.redeem_voucher(code, user_id)` does the lookup, the cap claim and the
  redemption row in one transaction and returns
  `{outcome, voucher_id, redemption_id, credits, credited}`. `credited`
  reports `counta.voucher_redemptions.credited_at`, so the endpoint can tell a
  redemption whose payout landed from one whose ledger call died mid-flight
  without asking RevenueCat. The two writes must not
  come apart: a slot with no redemption behind it under-grants a campaign by
  one, while a redemption with no slot lets the cap be exceeded. It is
  `security invoker` and executable only by `service_role`.
- Two voucher rules are database constraints rather than handler logic, for the
  same reason the one-live-block index is: a unique index on
  `voucher_redemptions (voucher_id, user_id)` is the one-redemption-per-user
  rule, and `vouchers_within_cap` makes it impossible to record more
  redemptions than a campaign allows. Codes fold to upper case for lookup and
  uniqueness; `expires_at` is nullable and null means never.
- Campaigns are created by hand with the service role; see "Operator setup"
  above for the SQL.
- `counta.matcher_config` is created empty. An absent row means "use the compiled
  `MatcherConfig` defaults"; task 14 makes the app fetch it.

## Notes on auth and abuse

`config.toml` sets `verify_jwt = false` so the function owns its 401 contract
and keeps working when the project moves to asymmetric signing keys, which the
gateway's verification does not understand. The endpoint is therefore publicly
reachable, and `auth.ts` is what makes that cheap: tokens are verified in-process
against the project JWKS (fetched once per worker, refreshed only on an unseen
key id), and `auth.getUser` is consulted only for a token this cannot decide
locally — a legacy HS256 token, an unimplemented algorithm, or an unreachable
JWKS. Junk costs no round trip.

**Known gap:** there is no IP-level rate limit. `RATE_LIMIT_MAX` is per user id
and only applies after a token verifies, so an unauthenticated flood still
reaches the function and is bounded only by Supabase's platform limits. Nothing
here spends money on an unauthenticated request, but the invocations are
billable. Put a WAF or an API gateway limit in front of the function before it
is advertised publicly.

## The RevenueCat balance shape

Re-checked against the current Developer API v2 reference
(<https://www.revenuecat.com/docs/api-v2/customer/resources>) in September
2026. The parser is right:

```json
{
  "object": "list",
  "items": [
    { "object": "virtual_currency_balance", "currency_code": "VOICE",
      "balance": 0, "description": "string", "name": "string" }
  ],
  "next_page": "/v2/projects/.../virtual_currencies?starting_after=…",
  "url": "/v2/projects/.../virtual_currencies"
}
```

`items[].currency_code` and `items[].balance` are the documented field names,
`include_empty_balances` is a real query parameter, and
`POST .../virtual_currencies/transactions` does take
`{ "adjustments": { "<code>": <signed int> }, "reference": "…" }` — a map
keyed by currency code, not an array — and answers with the same balance list,
so a write reports the balance it produced without a second round trip.
`Idempotency-Key` is documented on that endpoint, max 255 characters, which is
what every keyed grant in this function relies on.

What the earlier reading missed is that the list is **paginated**. A currency
sitting on page two would have read as a zero balance, and a zero balance
fails every grant with a 402 that no amount of buying credit fixes.
`getBalance` now asks for `limit=100` and follows `next_page`.

This is still documentation, not a live response: nothing here has been run
against a real project, because that needs a secret key. The remaining
unknowns are cosmetic (the default page size, whether `balance` can be
fractional). Worth one manual `curl` with the real key before the first paid
traffic; the shape itself is no longer a guess.

There is also a sibling endpoint, `POST .../virtual_currencies/update_balance`,
which sets a balance without writing a transaction. Nothing here uses it on
purpose: every movement of credit in this function should leave an auditable
transaction behind.
