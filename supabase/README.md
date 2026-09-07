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
    store.ts                        Supabase-backed BlockStore + JWT authenticator
    providers/balance.ts            RevenueCatBalanceProvider, FakeBalanceProvider
    providers/minter.ts             DeepgramTokenMinter, FakeTokenMinter
    index_test.ts                   Deno tests, no network
  .env.example                      every secret/setting the function reads
```

## Run locally

Requires the Supabase CLI, Docker and Deno.

```bash
make supabase-test        # deno tests, nothing else needed
make supabase-start       # docker stack; applies supabase/migrations
cp supabase/.env.example supabase/.env   # fill in, or use the fake providers
make supabase-serve       # serves functions with supabase/.env
```

For a first run without RevenueCat or a Deepgram key, set in `supabase/.env`:

```
BALANCE_PROVIDER=fake
TOKEN_MINTER=fake
```

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

## Environment the function reads

Injected by the runtime (do not set): `SUPABASE_URL`, `SUPABASE_ANON_KEY` or
`SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SERVICE_ROLE_KEY`.

| Variable | Default | Purpose |
|---|---|---|
| `DEEPGRAM_API_KEY` | required unless `TOKEN_MINTER=fake` | Master key used only to call `/v1/auth/grant` |
| `DEEPGRAM_TOKEN_TTL_SECONDS` | 30 | TTL of the temporary token (1..3600) |
| `REVENUECAT_SECRET_KEY` | required unless `BALANCE_PROVIDER=fake` | Developer API v2 key, `customer_information:purchases:read_write` |
| `REVENUECAT_PROJECT_ID` | required unless fake | RevenueCat project id |
| `REVENUECAT_CURRENCY_CODE` | `VOICE` | Virtual currency code for voice credits |
| `BALANCE_PROVIDER` | `revenuecat` | `revenuecat` or `fake` (in-memory) |
| `TOKEN_MINTER` | `deepgram` | `deepgram` or `fake` |
| `FAKE_BALANCE_INITIAL` | 20 | Starting balance for the fake provider |
| `BLOCK_CREDITS` | 5 | Credits debited per block |
| `BLOCK_SECONDS` | 300 | Block duration |
| `REFUND_WINDOW_SECONDS` | 30 | Release within this window with zero detections is refunded |
| `RENEWAL_OVERLAP_SECONDS` | 30 | A block with at most this much life left does not block a renewal with 409 |
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
  (`now()` is not immutable); a composite `(user_id, expires_at desc)` index
  serves the in-flight lookup instead.
- `voice_blocks` and `trial_grants` have no client write policy; all writes go
  through the service-role client inside the function.
- `matcher_config` is seeded with the compiled `MatcherConfig` defaults. Task 14
  makes the app fetch it.
