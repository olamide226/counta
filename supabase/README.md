# Supabase backend for voice counting

One Edge Function (`voice-block`) and three tables (`voice_blocks`,
`trial_grants`, `matcher_config`). See `specs/voice-phrase-counting/design.md`
for the contract and the reasoning behind blocks.

## Layout

```
supabase/
  config.toml                       local stack config; anonymous sign-in on
  migrations/*_voice_blocks.sql     tables, indexes, RLS, matcher_config seed
  functions/deno.json               pinned imports + `deno task test`
  functions/voice-block/
    index.ts                        entrypoint: env -> adapters -> handler
    handler.ts                      pure handler (request + deps -> Response)
    types.ts                        ports: BalanceProvider, TokenMinter, BlockStore
    auth.ts                         JWT verification (local JWKS, getUser fallback)
    store.ts                        Supabase-backed BlockStore
    providers/http.ts               shared fetch + failure classification
    providers/balance.ts            RevenueCatBalanceProvider
    providers/minter.ts             DeepgramTokenMinter
    testing/fakes.ts                test doubles; never imported by index.ts
    index_test.ts                   Deno tests, no network
  .env.example                      every secret/setting the function reads
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

```bash
```

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
supabase config push                              # enables anonymous sign-in on the project
```

Then set the project URL and publishable key in the app `.env` and rebuild.
Also configure a hard spend limit on the Deepgram project (req 10.4); no code
here can bound cost once a client holds an open socket.

## Notes on the schema

- The design's partial index `where expires_at > now()` is not valid Postgres
  (`now()` is not immutable). A partial **unique** index on
  `(user_id) where not reconciled` takes its place: it serves the in-flight
  lookup and enforces one live block per user (req 3.8) even when two requests
  race past the function's own check.
- `voice_blocks` and `trial_grants` have no client write policy; all writes go
  through the service-role client inside the function.
- `matcher_config` is created empty. An absent row means "use the compiled
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
