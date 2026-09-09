-- Voice phrase counting: block ledger, trial grants, remote matcher config.
-- See specs/voice-phrase-counting/design.md, "Supabase schema".
--
-- Everything lives in a dedicated `counta` schema. The target project is
-- shared staging: it already hosts other products, each in its own schema
-- (`mcpl`, `mcp_oauth`), and `public` belongs to an unrelated website. This
-- migration is additive and touches nothing outside `counta` — the only
-- reference beyond it is the foreign key to `auth.users`.
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

create table if not exists counta.trial_grants (
  rc_app_user_id text primary key,
  credits        int not null,
  granted_at     timestamptz not null default now()
);

alter table counta.trial_grants enable row level security;
-- No client policies at all: the one-time trial grant is written by the Edge
-- Function with the service role, and the primary key makes it idempotent.
-- `authenticated` gets no grant either, so the table is invisible to clients.
grant select, insert, update, delete on counta.trial_grants to service_role;

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
