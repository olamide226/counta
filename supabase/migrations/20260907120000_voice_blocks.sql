-- Voice phrase counting: block ledger, device-gated trial grants, voucher
-- campaign codes, remote matcher config.
-- See specs/voice-phrase-counting/design.md, "Supabase schema".
--
-- Everything lives in a dedicated `counta` schema. The target project is
-- shared staging: it already hosts other products, each in its own schema
-- (`mcpl`, `mcp_oauth`), and `public` belongs to an unrelated website. This
-- migration is additive and touches nothing outside `counta` — the only
-- references beyond it are the foreign keys to `auth.users`.
--
-- Re-runnable: every object is guarded, so a migration that failed halfway can
-- be applied again without hand-editing.

create schema if not exists counta;

-- PostgREST connects as anon/authenticated/service_role and needs schema
-- usage before any table grant matters. The cloud default that auto-exposes
-- new tables applies to `public` only, so every grant here is explicit.
grant usage on schema counta to anon, authenticated, service_role;

create table if not exists counta.voice_blocks (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users on delete cascade,
  session_id     uuid not null,
  credits        int  not null,
  granted_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  reconciled     boolean not null default false,
  streamed_secs  int,
  detections     int
);

-- Rate-limit lookup: grants for one user inside a time window.
create index if not exists voice_blocks_user_granted_idx
  on counta.voice_blocks (user_id, granted_at desc);

-- One live block per user (req 3.8), enforced by the database rather than by
-- the Edge Function's read-then-write, which two concurrent requests can both
-- pass. The design sketches `where expires_at > now()`; Postgres rejects that
-- because now() is not IMMUTABLE, but `not reconciled` is immutable and is the
-- predicate that actually matters: the function reconciles a block when it is
-- released, superseded by a renewal, or found expired, so the unreconciled set
-- is exactly the set that must stay unique. It doubles as the in-flight
-- lookup index, which is why there is no separate one.
create unique index if not exists voice_blocks_user_live_uniq
  on counta.voice_blocks (user_id) where not reconciled;

alter table counta.voice_blocks enable row level security;

drop policy if exists "own blocks readable" on counta.voice_blocks;
create policy "own blocks readable" on counta.voice_blocks
  for select using ((select auth.uid()) = user_id);
-- No client insert or update policy: writes come from the Edge Function using
-- the service role key only. The grants below match — `authenticated` gets
-- select and nothing else, so there is no write path to revoke a policy for.
grant select on counta.voice_blocks to authenticated;
grant select, insert, update, delete on counta.voice_blocks to service_role;

-- The 20-credit trial (req 4.3), keyed on the Supabase user and gated on a
-- device attestation the app cannot forge (req 11.1).
--
-- This table used to be keyed on the RevenueCat app user id. That id, like the
-- anonymous Supabase user, is minted fresh on every install, so the trial was
-- one delete-and-reinstall loop away from unlimited. What binds it now differs
-- by platform, and the difference is real rather than cosmetic:
--
--   iOS      Apple DeviceCheck. The "this device already claimed the trial"
--            answer lives in Apple's per-device bits, on Apple's servers, and
--            survives reinstall and device reset. Apple hands out no device
--            identifier, so there is nothing device-shaped to store here: the
--            row below is the audit trail and the per-user idempotency key,
--            not the gate.
--   Android  Play Integrity. It attests that the binary and the device are
--            genuine — which stops emulators and script farms — but offers no
--            persistent per-device storage, so on Android this row IS the
--            record and a human with a real phone can still reinstall past it
--            (req 11.6). That is the accepted weaker gate; a device
--            fingerprint would close it and is prohibited by both stores and
--            by req 11.7.
--
-- The primary key on user_id is what makes a retried grant idempotent (req
-- 11.8) — the same trick the old key played, minus the farmable identity.
create table if not exists counta.trial_grants (
  user_id     uuid primary key references auth.users on delete cascade,
  platform    text not null check (platform in ('ios', 'android')),
  gate        text not null check (gate in ('devicecheck', 'play_integrity')),
  credits     int  not null check (credits > 0),
  granted_at  timestamptz not null default now()
);

alter table counta.trial_grants enable row level security;
-- No client policies at all: the trial grant is written by the Edge Function
-- with the service role. `authenticated` gets no grant either, so the table is
-- invisible to clients — a client that could read it would learn whether it is
-- worth reinstalling, and a client that could write it would grant itself the
-- trial, which is exactly what req 4.8 forbids.
grant select, insert, update, delete on counta.trial_grants to service_role;

-- Voucher campaign codes (req 12). One code, many users, capped; a given user
-- redeems a given code at most once.
--
-- `redeemed_count` is a counter on the voucher rather than a count(*) over
-- redemptions because the cap has to survive concurrency: two requests that
-- both count 99 of 100 would both insert. The Edge Function claims a slot with
-- `update ... set redeemed_count = redeemed_count + 1
--  where id = $1 and redeemed_count < max_redemptions returning *`,
-- which takes the row lock, and `vouchers_within_cap` makes over-redemption
-- impossible even for a writer that forgets the predicate. Same reasoning as
-- the one-live-block unique index above: an invariant about money belongs in
-- the database.
--
-- `expires_at` is nullable and null means "never expires". Campaign codes
-- normally want an end date and a nullable column costs nothing, so it is here
-- ahead of a stated requirement (req 12.9).
--
-- Retirement is `enabled = false`, not delete: the redemption ledger below
-- references this row.
create table if not exists counta.vouchers (
  id               uuid primary key default gen_random_uuid(),
  code             text not null,
  credits          int  not null check (credits > 0),
  max_redemptions  int  not null check (max_redemptions > 0),
  redeemed_count   int  not null default 0 check (redeemed_count >= 0),
  expires_at       timestamptz,
  enabled          boolean not null default true,
  note             text,
  created_at       timestamptz not null default now(),
  constraint vouchers_within_cap check (redeemed_count <= max_redemptions)
);

-- Codes are typed by humans off a card or an email, so lookup and uniqueness
-- are case-insensitive. Unique on the folded form, not on `code`, so that
-- `SPRING24` and `spring24` cannot coexist as two different campaigns.
create unique index if not exists vouchers_code_uniq
  on counta.vouchers (upper(code));

alter table counta.vouchers enable row level security;
-- No policy and no client grant: the codes themselves are the secret. A select
-- policy for `authenticated`, however narrow, would let any anonymous session
-- list every live campaign code. Redemption goes through the Edge Function,
-- which reads this table with the service role (req 12.10).
grant select, insert, update, delete on counta.vouchers to service_role;

create table if not exists counta.voucher_redemptions (
  id          uuid primary key default gen_random_uuid(),
  -- restrict, not cascade: deleting a redeemed campaign would silently drop
  -- the record of credits already handed out. Disable the voucher instead.
  voucher_id  uuid not null references counta.vouchers on delete restrict,
  user_id     uuid not null references auth.users on delete cascade,
  credits     int  not null check (credits > 0),
  redeemed_at timestamptz not null default now()
);

-- One redemption per user per code (req 12.4), in the database rather than in
-- the handler for the same reason as the one-live-block index: a read-then-
-- write check is passable by two concurrent requests, and the thing being
-- protected is a credit grant. It doubles as the "have I already redeemed
-- this?" lookup, which is why there is no separate index on (user_id).
create unique index if not exists voucher_redemptions_user_voucher_uniq
  on counta.voucher_redemptions (voucher_id, user_id);

alter table counta.voucher_redemptions enable row level security;
-- No client grant: nothing in the app shows a redemption history, and the
-- balance the user actually cares about comes from RevenueCat. Add a select
-- policy on (select auth.uid()) = user_id if a history screen ever needs one.
grant select, insert, update, delete on counta.voucher_redemptions to service_role;

-- Failed redemption attempts, kept only to rate-limit guessing (req 12.8).
-- They cannot live in voucher_redemptions: a row there means "credits granted"
-- and is unique per user and code. Counting rows in a window is how the block
-- rate limit already works.
--
-- The submitted code is deliberately not stored, not even hashed: a table of
-- hashed guesses is an offline dictionary target and buys nothing the
-- timestamp does not.
create table if not exists counta.voucher_attempts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  attempted_at timestamptz not null default now()
);

create index if not exists voucher_attempts_user_time_idx
  on counta.voucher_attempts (user_id, attempted_at desc);

alter table counta.voucher_attempts enable row level security;
-- No client grant: a client that could delete its own attempts would lift its
-- own rate limit.
grant select, insert, update, delete on counta.voucher_attempts to service_role;

create table if not exists counta.matcher_config (
  id          int primary key default 1,
  config      jsonb not null,
  updated_at  timestamptz not null default now(),
  constraint singleton check (id = 1)
);

alter table counta.matcher_config enable row level security;

drop policy if exists "config readable by all authed" on counta.matcher_config;
create policy "config readable by all authed" on counta.matcher_config
  for select using ((select auth.role()) = 'authenticated');
grant select on counta.matcher_config to authenticated;
grant select, insert, update, delete on counta.matcher_config to service_role;

-- Deliberately unseeded. An absent row already means "use the compiled
-- MatcherConfig defaults" (lib/domain/counting/phrase_matcher.dart), and the
-- reader is task 14; a hand-copied duplicate of those defaults here would only
-- be a second source of truth to drift.
