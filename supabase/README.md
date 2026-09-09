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
> - `supabase db push` is safe here **only because** the migration is additive
>   and confined to `counta`. It creates a schema and six tables and touches
>   nothing in `public`, `mcpl`, `mcp_oauth` or `auth` beyond foreign keys to
>   `auth.users`. Re-read the migration before pushing any change to it.

## Layout

```
supabase/
  config.toml                       local stack config; anonymous sign-in on
  migrations/*_voice_blocks.sql     counta schema: tables, indexes, RLS, grants
  functions/deno.json               pinned imports + `deno task test`
  functions/voice-block/
    index.ts                        entrypoint: env -> adapters -> handler
    handler.ts                      pure handler (request + deps -> Response)
    types.ts                        ports: BalanceProvider, TokenMinter, BlockStore
    auth.ts                         JWT verification (local JWKS, getUser fallback)
    store.ts                        Supabase-backed BlockStore (counta schema)
    providers/http.ts               shared fetch + failure classification
    providers/balance.ts            RevenueCatBalanceProvider
    providers/minter.ts             DeepgramTokenMinter
    testing/fakes.ts                test doubles; never imported by index.ts
    index_test.ts                   Deno tests, no network
    store_test.ts                   pins every query to the counta schema
  .env.example                      every secret/setting the function reads,
                                    plus the task 10 trial and voucher settings
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
`functions/voice-block/testing/fakes.ts`, are imported only by `index_test.ts`,
and are therefore absent from the deployed bundle — a provider that hands out
credits must never be one environment-variable typo away from production. Every
behaviour they used to exercise by hand is covered by `make supabase-test`;
serving the function locally needs real RevenueCat and Deepgram credentials.

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

`streamed_secs` and `detections` must be non-negative integers when present
(anything else is a 400). A refund needs `detections` to be present and zero:
an omitted count is no report at all, not a report of zero.

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

The trial and voucher endpoints are task 10; the function does not read the
settings below yet, and they are listed here so the operator can obtain the
credentials before that work starts rather than during it.

| Variable | Default | Purpose |
|---|---|---|
| `TRIAL_CREDITS` | 20 | Credits granted by the one-per-device trial |
| `APPLE_TEAM_ID` | required on iOS | Apple developer team that owns the DeviceCheck bits |
| `APPLE_DEVICECHECK_KEY_ID` | required on iOS | Key id of a DeviceCheck-enabled key |
| `APPLE_DEVICECHECK_PRIVATE_KEY` | required on iOS | `.p8` contents for that key; downloadable exactly once |
| `APPLE_DEVICECHECK_HOST` | `api.devicecheck.apple.com` | Use `api.development.devicecheck.apple.com` for development-signed builds; the two hosts hold **separate** bit stores |
| `DEVICECHECK_TRIAL_BIT` | 0 | Which of the team's two bits means "took the Counta trial". The bits are per team, not per app — check the allocation table in the design doc before changing it |
| `PLAY_INTEGRITY_PACKAGE_NAME` | required on Android | Android application id the verdict must name |
| `PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON` | required on Android | Google Cloud service account JSON with the Play Integrity API enabled |
| `VOUCHER_ATTEMPT_MAX` | 10 | Failed redemptions allowed per user per window |
| `VOUCHER_ATTEMPT_WINDOW_MINUTES` | 60 | Window for the above |

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
- Two voucher rules are database constraints rather than handler logic, for the
  same reason the one-live-block index is: a unique index on
  `voucher_redemptions (voucher_id, user_id)` is the one-redemption-per-user
  rule, and `vouchers_within_cap` makes it impossible to record more
  redemptions than a campaign allows. Codes fold to upper case for lookup and
  uniqueness; `expires_at` is nullable and null means never.
- Create a campaign by hand with the service role, e.g.
  `insert into counta.vouchers (code, credits, max_redemptions, expires_at)
   values ('SPRING24', 50, 500, '2026-12-31T23:59:59Z');`
  Retire one with `update counta.vouchers set enabled = false where ...`
  rather than deleting it: the redemption ledger references the row.
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

## Verifying the RevenueCat balance shape

`RevenueCatBalanceProvider.balanceFrom` reads `items[].currency_code` and
`items[].balance` from the virtual-currencies response. That shape was taken
from the Developer API v2 documentation and has **not** been checked against a
live response. Confirm it against a real project — a mismatch reads as a zero
balance, which fails every grant with 402 — before this provider serves real
traffic.
